#!/bin/sh
# setup-mali-hybris.sh —— 让容器里的 Linux 应用使用手机自己的 Mali GPU
#
# 这是 llvmpipe 之外的第二种 MTK 实现：不靠 CPU 软件渲染，而是用 libhybris
# 把厂商的 libGLES_mali.so 载进容器，走真实 GPU。
#
# 两种运行方式，脚本自己判断：
#
#   宿主模式（在 Android shell 里跑，有 droidspaces）
#     配置容器的 bind mount、重启容器、其余步骤转发进容器。
#     命令：su -c 'sh setup-mali-hybris.sh --container=Debian'
#
#   容器模式（在容器里跑，镜像内 /usr/local/sbin/ 下）
#     跳过挂载配置（那需要宿主权限），只编译 libhybris、写环境、验证。
#     命令：sh /usr/local/sbin/setup-mali-hybris.sh
#
# 构建期模式（rootfs Dockerfile 调用，环境变量 DSHY_BUILD=1）
#     不检查宿主（没有 /dev/mali0、没有 droidspaces），只装依赖、克隆源码、
#     编译、装 shim、写环境。构建机是 x86，用 qemu 跑 arm64，编译较慢但可行。
#
# 前置：
#   1. mali_nsfix 已加载（droidspaces-lkm 提供）。没有它时驱动在容器进程创建
#      GPU context 时失败，dmesg 出现 "Failed to get pid pointer"。
#      注意：那是运行时前提，构建期检查不了。
#   2. 宿主模式下容器已存在；容器模式下挂载已由宿主侧配好。
#
# 已在 OPPO PHZ110 / MT6989 / Android 17 / VNDK v34 / Droidspaces 7.2.0 验证。

set -eu

CONTAINER="Debian"
DRY_RUN=0
SHIM_SO=""
DS="/data/local/Droidspaces/bin/droidspaces"
HY_ROOT="/opt/hy"
BUILD_MODE="${DSHY_BUILD:-0}"

# shim 源码位置：仓库里是 ../hybris/，装进镜像后在
# /usr/local/share/mali-hybris/。两处都找。
find_shim_c() {
    for c in \
        "$(dirname "$0")/../hybris/ui_compat_ahb.c" \
        "$(dirname "$0")/../share/mali-hybris/ui_compat_ahb.c" \
        /usr/local/share/mali-hybris/ui_compat_ahb.c \
        /usr/share/mali-hybris/ui_compat_ahb.c
    do
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
SHIM_C="$(find_shim_c || true)"

# 预编译 shim 位置（构建期用；仓库 scripts/hybris/ 与镜像内 /usr/local/share）
find_shim_so() {
    for c in \
        "$(dirname "$0")/../hybris/libui_compat_layer.so" \
        "$(dirname "$0")/../share/mali-hybris/libui_compat_layer.so" \
        /usr/local/share/mali-hybris/libui_compat_layer.so \
        /usr/share/mali-hybris/libui_compat_layer.so
    do
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
SHIM_PREBUILT="$(find_shim_so || true)"

for arg in "$@"; do
    case "$arg" in
        --container=*) CONTAINER="${arg#--container=}" ;;
        --dry-run)     DRY_RUN=1 ;;
        --shim=*)      SHIM_SO="${arg#--shim=}" ;;
        -h|--help)
            sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "未知参数: $arg" >&2; exit 2 ;;
    esac
done

say()  { echo "==> $*"; }
ok()   { echo "  [OK] $*"; }
warn() { echo "  [!!] $*"; }

# 宿主模式下所有容器内操作都要经过 droidspaces run；其余模式直接执行。
if [ "$BUILD_MODE" = "1" ]; then
    MODE="build"
elif [ -x "$DS" ]; then
    MODE="host"
else
    MODE="container"
fi

in_target() {
    case "$MODE" in
        host) "$DS" --name="$CONTAINER" run -- sh -c "$1" ;;
        *)    sh -c "$1" ;;
    esac
}

need_root() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root" >&2; exit 1; }
}

# ---------------------------------------------------------------------------
# 0. 前置检查
# ---------------------------------------------------------------------------
preflight() {
    say "前置检查（$MODE 模式）"

    if [ "$MODE" = "build" ]; then
        # 构建基础镜像（debian:trixie / ubuntu / fedora / arch）默认不带编译器，
        # 而 build_libhybris 会自己 apt/dnf/pacman 装齐编译依赖。
        #
        # 这里**不能**因为缺 gcc 就 exit：Dockerfile 的 RUN 没有 set -e，
        # 脚本退出后 RUN 会继续往下执行 configure-gpu，它探测不到 /opt/hy
        # 就静默回退到 llvmpipe —— 构建"成功"但产物是软件渲染，比直接编译
        # 失败难发现得多。
        command -v gcc >/dev/null 2>&1 || warn "构建镜像暂无 gcc，将由 build_libhybris 安装"
        command -v make >/dev/null 2>&1 || warn "构建镜像暂无 make，将由 build_libhybris 安装"
        ok "build 模式（依赖由 build_libhybris 安装）"
        return 0
    fi

    if [ "$MODE" = "host" ]; then
        ok "droidspaces: $DS"
        [ -e /dev/mali0 ] || { echo "/dev/mali0 不存在，这台设备不是 Mali GPU 或驱动未加载" >&2; exit 1; }
        ok "/dev/mali0 存在"
        if lsmod 2>/dev/null | grep -q '^mali_nsfix'; then
            ok "mali_nsfix 已加载"
        else
            warn "mali_nsfix 未加载 —— 容器进程创建不了 GPU context"
            warn "  加载: insmod /path/to/mali_nsfix.ko"
        fi
        if [ -e /dev/__properties__ ]; then
            ok "属性区: /dev/__properties__"
        else
            echo "找不到 /dev/__properties__" >&2
            exit 1
        fi
    else
        [ -e /dev/mali0 ] && ok "/dev/mali0 已挂入" || warn "/dev/mali0 未挂入（宿主侧还没配挂载？）"
        [ -d /dev/__properties__ ] && ok "属性区已挂入" || warn "/dev/__properties__ 未挂入"
        [ -d /vendor/lib64/egl ] && ok "/vendor 已挂入" || warn "/vendor 未挂入"
    fi

    if [ -e /vendor/lib64/egl/libGLES_mali.so ]; then
        ok "Mali EGL 实现: /vendor/lib64/egl/libGLES_mali.so"
    elif [ "$MODE" != "build" ]; then
        echo "找不到 /vendor/lib64/egl/libGLES_mali.so" >&2
        exit 1
    fi

    VNDK="$(ls /apex 2>/dev/null | grep -o 'com\.android\.vndk\.v[0-9]*' | head -1 || true)"
    if [ -n "$VNDK" ]; then
        ok "VNDK: $VNDK"
    else
        warn "未探测到 VNDK apex，按 v34 假设"
        VNDK="com.android.vndk.v34"
    fi
}

# ---------------------------------------------------------------------------
# 1. 容器挂载（仅宿主模式）
# ---------------------------------------------------------------------------
setup_mounts() {
    if [ "$MODE" != "host" ]; then
        return 0
    fi

    say "配置容器 [$CONTAINER] 的挂载"

    CFG="/data/local/Droidspaces/Containers/$CONTAINER/container.config"
    [ -f "$CFG" ] || { echo "找不到 $CFG" >&2; exit 1; }

    WANT="/dev/__properties__:/dev/__properties__:ro"
    WANT="$WANT,/vendor:/vendor:ro"
    WANT="$WANT,/system:/system:ro"
    WANT="$WANT,/system_ext:/system_ext:ro"
    WANT="$WANT,/apex:/apex:ro"

    CUR="$(grep '^bind_mounts=' "$CFG" 2>/dev/null | sed 's/^bind_mounts=//' || true)"

    KEEP="$(printf '%s' "$CUR" | tr ',' '\n' | grep -vE '^/(vendor|system|system_ext|apex|dev/__properties__)' | grep -v '^$' || true)"
    NEW="$WANT"
    if [ -n "$KEEP" ]; then
        NEW="$(printf '%s\n%s' "$KEEP" "$WANT" | tr '\n' ',' | sed 's/,$//')"
    fi

    if [ "$CUR" = "$NEW" ]; then
        ok "挂载已是最新，无需改动"
        return 0
    fi

    say "  新挂载: $NEW"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  [dry-run] 写入 $CFG"
    else
        cp -f "$CFG" "$CFG.bak.$(date +%s)"
        if grep -q '^bind_mounts=' "$CFG"; then
            sed -i "s|^bind_mounts=.*|bind_mounts=$NEW|" "$CFG"
        else
            echo "bind_mounts=$NEW" >> "$CFG"
        fi
        ok "已写入（原文件已备份）"
    fi
}

# ---------------------------------------------------------------------------
# 2. 构建 libhybris
# ---------------------------------------------------------------------------
build_libhybris() {
    say "构建 libhybris"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  [dry-run] 在容器内编译 libhybris 到 $HY_ROOT/inst"
        return 0
    fi

    if in_target "test -e $HY_ROOT/inst/lib/libEGL.so" 2>/dev/null; then
        ok "libhybris 已就绪: $HY_ROOT/inst/lib"
        return 0
    fi

    in_target "
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -q autoconf automake autopoint libtool pkg-config build-essential git \
            libwayland-dev libwayland-egl-backend-dev wayland-protocols libegl-dev libgles-dev \
            libdrm-dev libvulkan-dev libgbm-dev >/dev/null 2>&1 || true
        mkdir -p $HY_ROOT && cd $HY_ROOT
        [ -d android-headers ] || git clone --depth 1 -b herrie/halium-14.0 https://github.com/Halium/android-headers >/dev/null 2>&1
        [ -d dhy ] || git clone --depth 1 -b feature/mali-desktop https://github.com/ravindu644/libhybris dhy >/dev/null 2>&1
        cd $HY_ROOT/dhy/hybris || exit 1
        ./autogen.sh >/dev/null 2>&1
        ./configure --prefix=$HY_ROOT/inst --enable-arch=arm64 --enable-wayland --enable-lindroid-drm \
            --enable-mali-quirks --enable-debug --enable-property-cache=no \
            --with-android-headers=$HY_ROOT/android-headers \
            --with-default-hybris-ld-library-path=/vendor/lib64/egl:/vendor/lib64:/system/lib64:/apex/$VNDK/lib64 >/dev/null 2>&1
        make -j\"\$(nproc)\" CFLAGS='-O1 -g -DDEBUG' CXXFLAGS='-O1 -g -DDEBUG' >/dev/null 2>&1 || true
        make -k install >/dev/null 2>&1 || true
        for f in $HY_ROOT/dhy/hybris/egl/platforms/*/.libs/eglplatform_*.so; do
            [ -e \"\$f\" ] && cp -f \"\$f\" $HY_ROOT/inst/lib/
        done
        for f in $HY_ROOT/dhy/hybris/vulkan/platforms/*/.libs/vulkanplatform_*.so; do
            [ -e \"\$f\" ] && cp -f \"\$f\" $HY_ROOT/inst/lib/
        done
        test -e $HY_ROOT/inst/lib/libEGL.so
    " || { warn "libhybris 构建失败，检查容器内 $HY_ROOT/dhy/hybris 的 make 输出"; return 1; }

    ok "libhybris 已就绪: $HY_ROOT/inst/lib"
}

# ---------------------------------------------------------------------------
# 3. gralloc shim
# ---------------------------------------------------------------------------
install_shim() {
    say "安装 gralloc shim"

    # 预编译产物优先：构建期没有 NDK，容器里也没有 bionic 头。
    if [ -n "$SHIM_PREBUILT" ] && [ -f "$SHIM_PREBUILT" ]; then
        SHIM_SO="$SHIM_PREBUILT"
        ok "使用预编译 shim: $SHIM_SO"
    elif [ -n "$SHIM_SO" ] && [ -f "$SHIM_SO" ]; then
        :
    elif [ -n "${ANDROID_NDK_HOME:-}" ] && [ -n "$SHIM_C" ]; then
        CC="$(ls "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android*-clang 2>/dev/null | head -1 || true)"
        if [ -z "$CC" ]; then
            warn "NDK 里找不到 aarch64 clang，跳过"
            return 0
        fi
        SHIM_SO="$(mktemp -d)/libui_compat_layer.so"
        if "$CC" -shared -fPIC -O2 -o "$SHIM_SO" "$SHIM_C" -lnativewindow -llog 2>/dev/null; then
            ok "已用 NDK 编译 shim"
        else
            warn "shim 编译失败，跳过"
            return 0
        fi
    else
        warn "没有可用的 shim（缺预编译产物，也没有 NDK），跳过"
        warn "  没有它时 libhybris 分配窗口缓冲会失败，Wayland 上屏不可用"
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  [dry-run] 安装 $SHIM_SO 到 $HY_ROOT/android/"
        return 0
    fi

    in_target "mkdir -p $HY_ROOT/android" 2>/dev/null || true

    if [ "$MODE" = "host" ]; then
        ROOTFS="/mnt/Droidspaces/$CONTAINER"
        if [ -d "$ROOTFS$HY_ROOT/android" ]; then
            cp -f "$SHIM_SO" "$ROOTFS$HY_ROOT/android/libui_compat_layer.so"
            chmod 644 "$ROOTFS$HY_ROOT/android/libui_compat_layer.so"
            ok "$HY_ROOT/android/libui_compat_layer.so"
        else
            warn "rootfs 未挂载在 $ROOTFS，容器运行时再拷"
        fi
    else
        cp -f "$SHIM_SO" "$HY_ROOT/android/libui_compat_layer.so"
        chmod 644 "$HY_ROOT/android/libui_compat_layer.so"
        ok "$HY_ROOT/android/libui_compat_layer.so"
    fi
}

# ---------------------------------------------------------------------------
# 4. 环境文件
# ---------------------------------------------------------------------------
write_env() {
    say "写入环境文件"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  [dry-run] 写 $HY_ROOT/mali-gpu.env"
        return 0
    fi

    in_target "mkdir -p $HY_ROOT && cat > $HY_ROOT/mali-gpu.env <<'ENVEOF'
# 由 setup-mali-hybris.sh 生成
export XDG_RUNTIME_DIR=/run/user/1000
export LD_LIBRARY_PATH=$HY_ROOT/inst/lib
export HYBRIS_PATCH_TLS=1
export HYBRIS_EGLPLATFORM=null
export LIBEGL=/vendor/lib64/egl/libGLES_mali.so
export LIBGLESV2=/vendor/lib64/egl/libGLES_mali.so
export HYBRIS_LD_LIBRARY_PATH=$HY_ROOT/android:/vendor/lib64/egl:/vendor/lib64/hw:/vendor/lib64:/system/lib64:/system_ext/lib64:/apex/$VNDK/lib64
ENVEOF
" 2>/dev/null || { warn "写环境文件失败"; return 1; }

    ok "$HY_ROOT/mali-gpu.env"
}

# ---------------------------------------------------------------------------
# 5. 验证
# ---------------------------------------------------------------------------
verify() {
    say "验证"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  [dry-run] 跳过"
        return 0
    fi

    in_target "cat > $HY_ROOT/_gl_verify.c <<'CEOF'
#include <stdio.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
int main(void)
{
	EGLDisplay d; EGLConfig c; EGLContext x; EGLSurface s; EGLint n = 0;
	EGLint a[]  = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
	                EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE };
	EGLint ca[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
	EGLint pb[] = { EGL_WIDTH, 256, EGL_HEIGHT, 256, EGL_NONE };
	unsigned char px[4] = {0};
	setvbuf(stdout, NULL, _IONBF, 0);
	d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	if (d == EGL_NO_DISPLAY || !eglInitialize(d, 0, 0)) { puts(\"egl init failed\"); return 1; }
	if (!eglChooseConfig(d, a, &c, 1, &n) || !n) { puts(\"no config\"); return 1; }
	x = eglCreateContext(d, c, EGL_NO_CONTEXT, ca);
	s = eglCreatePbufferSurface(d, c, pb);
	if (x == EGL_NO_CONTEXT || s == EGL_NO_SURFACE || !eglMakeCurrent(d, s, s, x)) {
		puts(\"makecurrent failed\"); return 1;
	}
	printf(\"GL_RENDERER: %s\\n\", (const char *)glGetString(GL_RENDERER));
	printf(\"GL_VERSION:  %s\\n\", (const char *)glGetString(GL_VERSION));
	glClearColor(1, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT);
	glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
	printf(\"pixel: %02x %02x %02x %02x\\n\", px[0], px[1], px[2], px[3]);
	return 0;
}
CEOF
" 2>/dev/null || { warn "写探针失败"; return 0; }

    in_target "
        . $HY_ROOT/mali-gpu.env
        gcc -O1 -o /tmp/_gl_verify $HY_ROOT/_gl_verify.c \
            -I$HY_ROOT/inst/include -L$HY_ROOT/inst/lib -lEGL -lGLESv2 2>&1 | head -3
        /tmp/_gl_verify 2>&1 | grep -E 'GL_RENDERER|GL_VERSION|pixel|Fatal|failed' | sed 's/^/  /'
    " 2>&1 | head -6
}

# ---------------------------------------------------------------------------
need_root
preflight
setup_mounts
build_libhybris
install_shim
write_env

if [ "$MODE" = "host" ] && [ "$DRY_RUN" -eq 0 ]; then
    say "重启容器以应用挂载"
    "$DS" --name="$CONTAINER" restart >/dev/null 2>&1 || true
    sleep 15
fi

if [ "$MODE" != "build" ]; then
    verify
fi

echo
say "完成（$MODE 模式）"
echo "  用法："
if [ "$MODE" = "host" ]; then
    echo "    $DS --name=$CONTAINER run -- sh -c '. $HY_ROOT/mali-gpu.env && <你的命令>'"
else
    echo "    . $HY_ROOT/mali-gpu.env && <你的命令>"
fi
echo
echo "  已知限制："
echo "    - 无头渲染可用；上屏到 anland 6.x 窗口需要 android_wlegl，6.x 不提供"
echo "    - 需要加载 mali_nsfix，否则容器进程建不了 GPU context"