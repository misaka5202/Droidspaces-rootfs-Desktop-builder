#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "用法：$0 --assets DIR [--from-tsv FILE] --language zh|en --release-url URL --output FILE" >&2
  echo "  --from-tsv: 用已有的 sha256\tsize\tname 清单代替本地文件（发布恢复用）" >&2
  exit 2
}

ASSETS_DIR=''
FROM_TSV=''
LANGUAGE=''
RELEASE_URL=''
OUTPUT=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --assets) ASSETS_DIR="$2"; shift 2 ;;
    --language) LANGUAGE="$2"; shift 2 ;;
    --release-url) RELEASE_URL="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --from-tsv) FROM_TSV="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$RELEASE_URL" && -n "$OUTPUT" ]] || usage
if [[ -n "$FROM_TSV" ]]; then
  [[ -r "$FROM_TSV" ]] || { echo "读不到 $FROM_TSV" >&2; exit 2; }
else
  [[ -d "$ASSETS_DIR" ]] || usage
fi
[[ "$LANGUAGE" == zh || "$LANGUAGE" == en ]] || usage

declare -A distro_name=(
  [Debian-13]='Debian 13' [Ubuntu-26]='Ubuntu 26.04'
  [Fedora-43]='Fedora 43' [Fedora-44]='Fedora 44' [Arch]='Arch Linux'
)
declare -A distro_id=(
  [Debian-13]='Debian' [Ubuntu-26]='Ubuntu'
  [Fedora-43]='Fedora' [Fedora-44]='Fedora' [Arch]='Arch'
)
declare -A desktop_name=(
  [kde]='KDE Plasma' [kde-mobile]='KDE Plasma Mobile' [gnome]='GNOME'
  [anland-next]='Anland Next' [niri]='Niri' [hyprland]='Hyprland'
  [mango]='Mango' [denial]='Denial'
)
declare -A desktop_label=(
  [kde]='KDE' [kde-mobile]='KDE mobile' [gnome]='GNOME'
  [anland-next]='Anland Next' [niri]='Niri' [hyprland]='Hyprland'
  [mango]='Mango' [denial]='Denial'
)
declare -A distro_detail_zh=(
  [Debian-13]='基于 Debian 13 Trixie ARM64，预装常用容器工具、网络与 SSH 支持'
  [Ubuntu-26]='基于 Ubuntu 26.04 ARM64，预装常用容器工具、网络与 SSH 支持'
  [Fedora-43]='基于 Fedora 43 ARM64，包含 DNF 管理工具、网络与 SSH 支持'
  [Fedora-44]='基于 Fedora 44 ARM64，包含 DNF 管理工具、网络与 SSH 支持'
  [Arch]='基于 Arch Linux ARM 滚动发行版，包含 Pacman、网络与 SSH 支持'
)
declare -A distro_detail_en=(
  [Debian-13]='Based on Debian 13 Trixie for ARM64, with common container utilities, networking, and SSH support'
  [Ubuntu-26]='Based on Ubuntu 26.04 for ARM64, with common container utilities, networking, and SSH support'
  [Fedora-43]='Based on Fedora 43 for ARM64, with DNF tools, networking, and SSH support'
  [Fedora-44]='Based on Fedora 44 for ARM64, with DNF tools, networking, and SSH support'
  [Arch]='Based on rolling Arch Linux ARM, with Pacman, networking, and SSH support'
)
declare -A desktop_detail_zh=(
  [kde]='集成 Plasma 桌面、Anland 专用 KWin/Xwayland、Dolphin 文件管理器、Konsole 终端和系统设置'
  [kde-mobile]='集成面向触屏的 Plasma Mobile、Maliit 屏幕键盘、Angelfish 浏览器和 Anland Wayland 会话'
  [gnome]='集成 GNOME Shell、Mutter、设置中心、文件管理器、终端、密钥环和常用桌面应用'
  [anland-next]='提供 Anland Next 会话、rootless Xwayland 与 mini-wm，适合在轻量图形环境中运行桌面应用'
  [niri]='提供 Niri 平铺合成器、Wayland 门户、终端、状态栏、音频服务和常用字体，不预装完整桌面套件'
  [hyprland]='提供 Hyprland 合成器、Wayland 门户、Kitty 终端、文件管理器、音频服务和常用字体'
  [mango]='提供 Mango 合成器、Wayland 门户、Rofi 菜单、终端、音频服务和常用字体，不预装完整桌面套件'
  [denial]='提供 Denial 合成器、Wayland 门户、Alacritty 终端、Fuzzel 启动器和 PipeWire 音频基础环境'
)
declare -A desktop_detail_en=(
  [kde]='Includes the Plasma desktop, Anland-patched KWin/Xwayland, Dolphin file manager, Konsole terminal, and system settings'
  [kde-mobile]='Includes touch-focused Plasma Mobile, the Maliit on-screen keyboard, Angelfish browser, and an Anland Wayland session'
  [gnome]='Includes GNOME Shell, Mutter, Settings, Files, Terminal, keyring integration, and common desktop applications'
  [anland-next]='Provides the Anland Next session, rootless Xwayland, and mini-wm for running desktop applications in a lightweight graphical environment'
  [niri]='Provides the Niri tiling compositor, Wayland portals, terminal, status bar, audio services, and common fonts without a full desktop suite'
  [hyprland]='Provides the Hyprland compositor, Wayland portals, Kitty terminal, file manager, audio services, and common fonts'
  [mango]='Provides the Mango compositor, Wayland portals, Rofi menu, terminal, audio services, and common fonts without a full desktop suite'
  [denial]='Provides the Denial compositor, Wayland portals, Alacritty terminal, Fuzzel launcher, and a PipeWire audio base'
)

RELEASE_URL="${RELEASE_URL%/}"
entries_file="$(mktemp)"
entry_tmp="$(mktemp)"
trap 'rm -f "$entries_file" "$entry_tmp"' EXIT
count=0
shopt -s nullglob
if [[ -n "$FROM_TSV" ]]; then
  # 每行：sha256<TAB>size<TAB>文件名
  file_list=$(awk -F '	' 'NF==3 {print $3}' "$FROM_TSV")
else
  file_list=$(cd "$ASSETS_DIR" && ls -1 *.tar.xz 2>/dev/null)
fi
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  [[ "$file" == *-"$LANGUAGE".tar.xz ]] || continue
  stem="${file%.tar.xz}"
  rest="${stem#*-}"
  distro="${file%%-*}"
  if [[ "$file" == Debian-13-* ]]; then distro=Debian-13; rest="${stem#Debian-13-}"; fi
  if [[ "$file" == Ubuntu-26-* ]]; then distro=Ubuntu-26; rest="${stem#Ubuntu-26-}"; fi
  if [[ "$file" == Fedora-43-* ]]; then distro=Fedora-43; rest="${stem#Fedora-43-}"; fi
  if [[ "$file" == Fedora-44-* ]]; then distro=Fedora-44; rest="${stem#Fedora-44-}"; fi
  if [[ "$file" == Arch-* ]]; then distro=Arch; rest="${stem#Arch-}"; fi
  desktop="${rest%%-Wayland-*}"
  [[ -n "${desktop_name[$desktop]:-}" ]] || continue
  # 文件名可选带 GPU 厂商段：
  #   <distro>-<desktop>-Wayland-Droidspaces-rootfs-<arch>-<ver>-<lang>
  #   <distro>-<desktop>-Wayland-<gpu>-Droidspaces-rootfs-<arch>-<ver>-<lang>
  after_wayland="${rest#${desktop}-Wayland-}"
  gpu=""
  case "$after_wayland" in
    qualcomm-Droidspaces-rootfs-*) gpu=qualcomm; middle="${after_wayland#qualcomm-Droidspaces-rootfs-}" ;;
    mediatek-Droidspaces-rootfs-*) gpu=mediatek; middle="${after_wayland#mediatek-Droidspaces-rootfs-}" ;;
    Droidspaces-rootfs-*)          middle="${after_wayland#Droidspaces-rootfs-}" ;;
    *) continue ;;
  esac
  arch="${middle%%-*}"
  version_lang="${middle#${arch}-}"
  version="${version_lang%-${LANGUAGE}}"
  [[ -n "$version" && -n "$arch" ]] || continue
  # 名称里带上 GPU 厂商，两个版本在同一 Release 里能区分
  case "$gpu" in
    qualcomm) gpu_label_zh='（高通 Adreno）'; gpu_label_en=' (Qualcomm Adreno)' ;;
    mediatek) gpu_label_zh='（MTK vkms）';   gpu_label_en=' (MediaTek vkms)' ;;
    *)        gpu_label_zh='';               gpu_label_en='' ;;
  esac
  case "$gpu" in
    qualcomm) gpu_note_zh='启用高通 Adreno 硬件加速（Mesa Turnip/Freedreno + kgsl）。'
              gpu_note_en='Qualcomm Adreno hardware acceleration is enabled (Mesa Turnip/Freedreno over kgsl).' ;;
    mediatek) gpu_note_zh='使用 vkms 虚拟 DRM 节点 + llvmpipe 软件渲染，宿主机需先加载 droidspaces-lkm 的 vkms 模块。'
              gpu_note_en='Renders through the vkms virtual DRM node and llvmpipe; the host needs the vkms module from droidspaces-lkm loaded first.' ;;
    *)        gpu_note_zh='启用高通 Adreno/Mesa 支持。'
              gpu_note_en='Qualcomm Adreno/Mesa support is enabled.' ;;
  esac
  if [[ -n "$FROM_TSV" ]]; then
    meta=$(awk -F '	' -v f="$file" '$3 == f {print $1 " " $2; exit}' "$FROM_TSV")
    sha256="${meta%% *}"
    size_bytes="${meta##* }"
  else
    sha256="$(sha256sum "$ASSETS_DIR/$file" | awk '{print $1}')"
    size_bytes="$(wc -c < "$ASSETS_DIR/$file")"
  fi
  [[ -n "$sha256" && -n "$size_bytes" ]] || continue
  if [[ "$LANGUAGE" == zh ]]; then
    name="${distro_name[$distro]} - ${desktop_label[$desktop]}（Anland Wayland）${gpu_label_zh}"
    description="${distro_detail_zh[$distro]}；${desktop_detail_zh[$desktop]}。镜像已配置 Droidspaces 桌面自启动。${gpu_note_zh}"
  else
    name="${distro_name[$distro]} - ${desktop_name[$desktop]} (Anland Wayland)${gpu_label_en}"
    description="${distro_detail_en[$distro]}; ${desktop_detail_en[$desktop]}. The image enables Droidspaces desktop autostart.${gpu_note_en}"
  fi
  jq -nc \
    --arg author 'Gold bug' \
    --arg name "$name" --arg distro "${distro_id[$distro]}" \
    --arg description "$description" --arg architecture "$arch" \
    --arg language "$LANGUAGE" --arg file "$stem" \
    --arg download_url "$RELEASE_URL/$file" --arg sha256 "$sha256" \
    --arg version "$version" --arg build_date "${version#v}" \
    --argjson size_bytes "$size_bytes" \
    '{author:$author,name:$name,distro:$distro,description:$description,architecture:$architecture,language:$language,file:$file,download_url:$download_url,sha256:$sha256,size_bytes:$size_bytes,version:$version,build_date:($build_date|split("-")[0])}' > "$entry_tmp"
  cat "$entry_tmp" >> "$entries_file"
  count=$((count + 1))
done < <(printf '%s
' "$file_list")
# 部分组合在上游 Anland 包依赖上不可满足（如 Debian 13 的 hyprland），
# 不能因为个别失败就让整个滚动 Release 生不出来。数量不符只警告。
case "$count" in
  40|80) ;;
  *) echo "警告：期望 40（单 GPU）或 80（双 GPU）个 $LANGUAGE 资产，实际找到 $count；仍继续生成清单。" >&2 ;;
esac
(( count > 0 )) || { echo "没有任何 $LANGUAGE 资产" >&2; exit 1; }
mkdir -p "${OUTPUT%/*}"
jq -s 'sort_by(.distro, .name, .architecture)' "$entries_file" > "$OUTPUT"
