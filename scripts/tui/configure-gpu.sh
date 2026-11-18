#!/usr/bin/env bash
# 按 GPU 厂商配置显示栈。
#
# 用法：configure-gpu.sh <vendor> <backend> <enable_mesa>
#   vendor        qualcomm | mediatek
#   backend       anland-wayland
#   enable_mesa   true | false
#
# 为什么需要分厂商：
#
#   高通 Adreno —— Android 内核通过 /dev/kgsl-3d0 暴露图形设备，DRM 节点
#   (/dev/dri/renderD*) 由 kgsl 驱动提供。Mesa 的 Freedreno/Turnip 走 kgsl
#   ioctl，必须显式指定加载器后端：
#       MESA_LOADER_DRIVER_OVERRIDE=kgsl
#       GALLIUM_DRIVER=kgsl
#       FD_FORCE_KGSL=1
#   驱动来自 mesa-for-android-container（Adreno 专用构建）。
#
#   MTK Mali —— /dev/mali0 是 ARM 私有 ioctl 接口，Linux 侧没有 DRM 驱动，
#   所以 Mesa 的 DRI 路径（kgsl / panfrost）都不可用。
#
#   硬件加速靠 libhybris：把厂商的 libGLES_mali.so 载进容器，由它直接对
#   /dev/mali0 发起 ioctl。这套方案需要宿主侧的 mali_nsfix —— mali_kbase 的
#   find_get_pid 在 PID 命名空间内解析失败，容器进程建不了 GPU context
#   （dmesg: "Failed to get pid pointer"，用户态表现为 eglInitialize 0x3001）。
#
#   因此 MEDIATEK 分支：
#     1) 装标准 Mesa 软件驱动，作为 hybris 不可用时的回退
#     2) 设置 libhybris 环境变量（构建期已由 setup-mali-hybris 装好 /opt/hy）
#     3) 不设 MESA_LOADER_DRIVER_OVERRIDE / LIBGL_ALWAYS_SOFTWARE —— 那会让
#        Mesa 强制走软件路径，把 hybris 盖掉
#     4) **不能**设任何 kgsl 变量，理由同高通那侧
#
#   注意这是「Anland Next（6.x）」那条路径的配置。自带标准 Wayland 合成器的
#   桌面镜像（KDE/GNOME/Hyprland/Niri/Mango/Denial）走的是
#   ANLAND_DRM_DEVICE=/dev/dri/renderD128，Mali 上没有 DRM render node，宿主
#   必须加载 droidspaces-lkm 的 vkms；那种镜像里 hybris 环境不参与渲染。
set -euo pipefail

VENDOR="${1:-qualcomm}"
BACKEND="${2:-}"
ENABLE_MESA="${3:-false}"

ENVIRONMENT_FILE="${ROOTFS_DIR:-}/etc/environment"

# 从目标 rootfs 识别发行版
distro_id=""
distro_version=""
if [ -f "${ROOTFS_DIR:-}/etc/os-release" ]; then
    # shellcheck disable=SC1091
    . "${ROOTFS_DIR:-}/etc/os-release"
    distro_id="${ID:-}"
    distro_version="${VERSION_ID:-}"
fi

log() {
    # 注意别写成 printf '--> ...'：格式串以 -- 开头会被 printf 当成选项
    printf '%s\n' "--> configure-gpu[$VENDOR] $1"
}

append_env() {
    local assignment="$1"
    local key="${assignment%%=*}"
    mkdir -p "$(dirname "$ENVIRONMENT_FILE")"
    touch "$ENVIRONMENT_FILE"
    if grep -q "^${key}=" "$ENVIRONMENT_FILE" 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$assignment" >> "$ENVIRONMENT_FILE"
}

# 删掉任何已有的 kgsl 变量，避免上面某个 profile 留下的残留
strip_kgsl_env() {
    [ -f "$ENVIRONMENT_FILE" ] || return 0
    sed -i -E '/^(MESA_LOADER_DRIVER_OVERRIDE|GALLIUM_DRIVER|FD_FORCE_KGSL|TU_DEBUG)=/d' \
        "$ENVIRONMENT_FILE"
}

configure_qualcomm() {
    if [ "$ENABLE_MESA" != "true" ]; then
        log "高通：未开启 Mesa 安装，跳过"
        return 0
    fi

    # 只输出 Anland Wayland：统一使用 kgsl 三件套。
    append_env "MESA_LOADER_DRIVER_OVERRIDE=kgsl"
    append_env "GALLIUM_DRIVER=kgsl"
    append_env "FD_FORCE_KGSL=1"
    log "高通 Wayland：已设置 kgsl 加载器后端（三件套）"
}

configure_mediatek() {
    strip_kgsl_env
    log "MTK：已移除 kgsl 变量（Mali 无 Linux DRM 驱动）"

    # 软件渲染需要标准 Mesa 的 DRI 驱动（llvmpipe / swrast）
    case "$distro_id" in
        debian|ubuntu)
            if [ "$ENABLE_MESA" = "true" ]; then
                # 用户选了「Mesa 支持」，在 MTK 上对应的就是软件驱动
                log "安装软件渲染 Mesa 驱动"
                apt-get update -qq || true
                DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                    libgl1-mesa-dri libglx-mesa0 libgles2 mesa-vulkan-drivers \
                    || log "警告：Mesa 软件驱动安装失败，桌面可能无法启动"
            fi
            ;;
        fedora|rhel|centos)
            if [ "$ENABLE_MESA" = "true" ]; then
                log "安装软件渲染 Mesa 驱动"
                dnf install -y --setopt=install_weak_deps=False \
                    mesa-dri-drivers mesa-vulkan-drivers \
                    || log "警告：Mesa 软件驱动安装失败，桌面可能无法启动"
            fi
            ;;
        arch|archarm|archlinux)
            if [ "$ENABLE_MESA" = "true" ]; then
                log "安装软件渲染 Mesa 驱动"
                # Arch 的包名和 Debian 系不同：软件 Vulkan 驱动是
                # vulkan-swrast（lavapipe），没有 mesa-vulkan-drivers 这个包。
                # 分开装，一个名字不对不至于让整条命令都失败。
                pacman -S --needed --noconfirm mesa \
                    || log "警告：mesa 安装失败"
                pacman -S --needed --noconfirm vulkan-swrast \
                    || log "警告：vulkan-swrast 安装失败（Vulkan 可能不可用）"
                # llvmpipe/swrast 的 DRI 驱动在 mesa 包里，确认文件真的落盘
                if [ -e "${ROOTFS_DIR:-}/usr/lib/dri/swrast_dri.so" ] \
                   || [ -e "${ROOTFS_DIR:-}/usr/lib/dri/llvmpipe_dri.so" ]; then
                    log "软件 DRI 驱动已就位"
                else
                    log "警告：未找到 swrast/llvmpipe DRI 驱动"
                fi
            fi
            ;;
        *)
            log "未知发行版 ${distro_id:-?}，跳过 Mesa 软件驱动安装"
            ;;
    esac

    # 硬件加速：libhybris + 厂商 Mali。
    #
    # 构建期 setup-mali-hybris.sh 会把 libhybris 装到 /opt/hy/inst，
    # 并把 gralloc shim 放到 /opt/hy/android。这里只写环境变量。
    if [ -e "${ROOTFS_DIR:-}/opt/hy/inst/lib/libEGL.so" ]; then
        append_env "LD_LIBRARY_PATH=/opt/hy/inst/lib"
        append_env "HYBRIS_PATCH_TLS=1"
        append_env "HYBRIS_EGLPLATFORM=null"
        append_env "LIBEGL=/vendor/lib64/egl/libGLES_mali.so"
        append_env "LIBGLESV2=/vendor/lib64/egl/libGLES_mali.so"
        append_env "HYBRIS_LD_LIBRARY_PATH=/opt/hy/android:/vendor/lib64/egl:/vendor/lib64/hw:/vendor/lib64:/system/lib64:/system_ext/lib64:/apex/com.android.vndk.v34/lib64"
        # 不要设 MESA_LOADER_DRIVER_OVERRIDE / LIBGL_ALWAYS_SOFTWARE：
        # 那会把 Mesa 钉在软件路径上，libhybris 就没有意义了。
        #
        # 不要设 VK_ICD_FILENAMES：Vulkan 加载器本来就会扫描
        # /usr/share/vulkan/icd.d/，硬编码文件名（lvp_icd.aarch64.json vs
        # lvp_icd.json 各发行版不一）只会在写错时让 Vulkan 彻底不可用。
        log "MTK：渲染路径 = libhybris + 厂商 Mali（需宿主 mali_nsfix）"
    else
        # 回退：构建期没装成 libhybris，退回 Mesa 软件路径。
        if [ "$ENABLE_MESA" = "true" ]; then
            append_env "LIBGL_ALWAYS_SOFTWARE=1"
            append_env "GALLIUM_DRIVER=llvmpipe"
        fi
        log "MTK：未找到 libhybris，回退到 Mesa 软件渲染"
    fi
}

case "$VENDOR" in
    qualcomm)
        configure_qualcomm
        ;;
    mediatek)
        configure_mediatek
        ;;
    *)
        echo "configure-gpu: 未知 GPU 厂商 '$VENDOR'（支持 qualcomm | mediatek）" >&2
        exit 1
        ;;
esac

log "完成"
