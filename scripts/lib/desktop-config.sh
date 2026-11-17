#!/usr/bin/env bash

# 本项目只构建 Anland Wayland：X11 后端、none（纯命令行）桌面以及不支持
# Anland Wayland 的发行版目标（Ubuntu 24.04 / 25.10）均已移除。

desktop_normalize() {
    case "${1:-}" in
        KDE|kde) printf '%s\n' kde ;;
        'KDE mobile'|kde-mobile) printf '%s\n' kde-mobile ;;
        GNOME|gnome) printf '%s\n' gnome ;;
        'Anland Next'|anland-next) printf '%s\n' anland-next ;;
        Niri|niri) printf '%s\n' niri ;;
        Hyprland|hyprland) printf '%s\n' hyprland ;;
        Mango|mango) printf '%s\n' mango ;;
        Denial|denial) printf '%s\n' denial ;;
        *) return 1 ;;
    esac
}

desktop_label() {
    case "${1:-}" in
        kde) printf '%s\n' KDE ;;
        kde-mobile) printf '%s\n' 'KDE mobile' ;;
        gnome) printf '%s\n' GNOME ;;
        anland-next) printf '%s\n' 'Anland Next' ;;
        niri) printf '%s\n' Niri ;;
        hyprland) printf '%s\n' Hyprland ;;
        mango) printf '%s\n' Mango ;;
        denial) printf '%s\n' Denial ;;
        *) return 1 ;;
    esac
}

display_backend_normalize() {
    case "${1:-}" in
        'Anland Wayland'|anland-wayland|'') printf '%s\n' anland-wayland ;;
        *) return 1 ;;
    esac
}

display_backend_label() {
    case "${1:-}" in
        anland-wayland) printf '%s\n' Wayland ;;
        *) return 1 ;;
    esac
}

target_is_known() {
    case "${1:-}" in
        Debian-13|Ubuntu-26|Fedora-43|Fedora-44|Arch) return 0 ;;
        *) return 1 ;;
    esac
}

desktop_target_supported() {
    local target="${1:-}"
    local desktop="${2:-}"

    target_is_known "$target" || return 1
    case "$desktop" in
        kde|kde-mobile|gnome|anland-next|niri|hyprland|mango|denial) return 0 ;;
        *) return 1 ;;
    esac
}

desktop_backend_supported() {
    local target="${1:-}"
    local desktop="${2:-}"
    local backend="${3:-}"

    [ "$backend" = anland-wayland ] || return 1
    desktop_target_supported "$target" "$desktop"
}

desktop_wayland_targets_json() {
    case "${1:-}" in
        kde|kde-mobile|gnome|anland-next|niri|hyprland|mango|denial)
            printf '%s\n' '["Debian-13","Ubuntu-26","Fedora-43","Fedora-44","Arch"]'
            ;;
        *) return 1 ;;
    esac
}

anland_archive_target() {
    case "${1:-}" in
        Debian-13) printf '%s\n' Debian13 ;;
        Ubuntu-26) printf '%s\n' ubuntu2604 ;;
        Fedora-43) printf '%s\n' Fedora43 ;;
        Fedora-44) printf '%s\n' Fedora44 ;;
        Arch) printf '%s\n' Arch ;;
        *) return 1 ;;
    esac
}
