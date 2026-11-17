#!/bin/sh
# patch-egl-dmabuf.sh —— 让 libhybris 的 EGL Wayland 平台在没有 android_wlegl 时
# 走 zwp_linux_dmabuf_v1（anland 6.x 只提供后者）
#
# 为什么补丁这么小：
#   libhybris 这份 fork 里 dmabuf 的 buffer 实现**已经写好了**：
#     - platforms/wayland/wayland_window_common.cpp 有 DrmWaylandBuffer
#     - addBuffer() 里已有 if(!m_android_wlegl) 走 DrmWaylandBuffer 的分支
#     - wayland_window.h 已有 wl_dmabuf 成员（在 WANT_LINDROID_DRM 下，private）
#   缺的只是三件事：
#     1. eglplatform_wayland.cpp 里绑定 zwp_linux_dmabuf_v1
#     2. 把它填进窗口的 wl_dmabuf 成员
#     3. callback_done 里那个硬 abort
#
# 为什么用 setter 而不是给构造函数加参数：
#   WaylandNativeWindow 的构造函数定义在 platforms/wayland/wayland_window_common.cpp，
#   那个文件 Vulkan 平台也在编。改签名会连带破坏 Vulkan 侧。
#   加一个 public setter 只动 EGL 的头文件，互不影响。
#
# 为什么不改 Makefile：协议 .c 加进 automake 生成的续行列表会破坏结构
# （recipe commences before first target）。改成在 .cpp 里直接 include 协议实现。

set -eu

HY=${HY:-/opt/hy}
SRC="$HY/dhy/hybris"
EGL="$SRC/egl/platforms/wayland"
VK="$SRC/vulkan/platforms/wayland"

say() { echo "==> $*"; }
ok()  { echo "  [OK] $*"; }
warn(){ echo "  [!!] $*"; }

[ -d "$EGL" ] || { echo "找不到 $EGL" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. 恢复到原始状态（幂等：重复跑不会叠加改动）
# ---------------------------------------------------------------------------
say "恢复到原始文件"
for base in eglplatform_wayland.cpp wayland_window.h wayland_window.cpp Makefile; do
    first=$(ls -1 "$EGL/$base".bak.* 2>/dev/null | head -1 || true)
    if [ -n "$first" ]; then
        cp -f "$first" "$EGL/$base"
        ok "$base <- $(basename "$first")"
    fi
done

# ---------------------------------------------------------------------------
# 1. 搬 dmabuf 协议
# ---------------------------------------------------------------------------
say "搬 dmabuf 协议文件"
for f in linux-dmabuf-unstable-v1-client-protocol.h linux-dmabuf-unstable-v1-protocol.c; do
    [ -f "$VK/$f" ] || { echo "缺少 $VK/$f" >&2; exit 1; }
    cp -f "$VK/$f" "$EGL/$f"
    ok "$f"
done

# ---------------------------------------------------------------------------
# 2. wayland_window.h：加一个 public setter
# ---------------------------------------------------------------------------
say "wayland_window.h 加 setWlDmabuf"

H="$EGL/wayland_window.h"
cp -f "$H" "$H.bak.patch"

python3 - "$H" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding='utf-8', errors='surrogateescape').read()

if 'setWlDmabuf' in s:
    print("  setter 已存在")
else:
    anchor = '    void releaseBuffer(struct wl_buffer *buffer);'
    setter = (anchor + '\n'
              '#ifdef WANT_LINDROID_DRM\n'
              '    void setWlDmabuf(struct zwp_linux_dmabuf_v1 *d) { wl_dmabuf = d; }\n'
              '#endif')
    if anchor in s:
        s = s.replace(anchor, setter, 1)
        open(path, 'w', encoding='utf-8', errors='surrogateescape').write(s)
        print("  setter 已加在 releaseBuffer 之后")
    else:
        print("  找不到锚点 releaseBuffer")
PY

# ---------------------------------------------------------------------------
# 3. eglplatform_wayland.cpp
# ---------------------------------------------------------------------------
say "补丁 eglplatform_wayland.cpp"

CF="$EGL/eglplatform_wayland.cpp"
cp -f "$CF" "$CF.bak.patch"

python3 - "$CF" <<'PY'
import sys, re

path = sys.argv[1]
s = open(path, encoding='utf-8', errors='surrogateescape').read()
changed = []

# 3a. 协议实现直接 include（替代改 Makefile）
if 'linux-dmabuf-unstable-v1-protocol.c' not in s:
    inc = ('#include "linux-dmabuf-unstable-v1-client-protocol.h"\n'
           '#include "linux-dmabuf-unstable-v1-protocol.c"')
    m = re.search(r'^#include\s+"[^"]*wayland_window\.h"\s*$', s, re.M)
    if not m:
        m = re.search(r'^#include .*$', s, re.M)
    s = s[:m.end()] + '\n' + inc + s[m.end():]
    changed.append('include')

# 3b. WaylandDisplay 加成员
if 'zwp_linux_dmabuf_v1 *wl_dmabuf' not in s:
    s = s.replace('android_wlegl *wlegl;',
                  'android_wlegl *wlegl;\n\tzwp_linux_dmabuf_v1 *wl_dmabuf;', 1)
    changed.append('Display.wl_dmabuf')

# 3c. registry 绑定
if 'zwp_linux_dmabuf_v1_interface' not in s:
    old = 'if (strcmp(interface, "android_wlegl") == 0) {'
    new = ('if (strcmp(interface, "zwp_linux_dmabuf_v1") == 0) {\n'
           '\t\tdpy->wl_dmabuf = static_cast<struct zwp_linux_dmabuf_v1 *>(\n'
           '\t\t\twl_registry_bind(registry, name, &zwp_linux_dmabuf_v1_interface,\n'
           '\t\t\t                  std::min(3u, version)));\n'
           '\t}\n'
           '\t' + old)
    if old in s:
        s = s.replace(old, new, 1)
        changed.append('bind')

# 3d. callback_done 不再硬失败
old_abort = '''        if (!dpy->wlegl) {
            fprintf(stderr, "Fatal: the server doesn't advertise the android_wlegl global!");
            abort();
        }'''
new_abort = '''        if (!dpy->wlegl && !dpy->wl_dmabuf) {
            fprintf(stderr, "Fatal: server advertises neither android_wlegl nor zwp_linux_dmabuf_v1!");
            abort();
        }
        if (!dpy->wlegl)
            fprintf(stderr, "hybris: no android_wlegl, using zwp_linux_dmabuf_v1\\n");'''
if old_abort in s:
    s = s.replace(old_abort, new_abort, 1)
    changed.append('callback_done')

# 3e. 构造后调 setter（构造函数签名不变）
m = re.search(r'(\s*)WaylandNativeWindow \*window = new WaylandNativeWindow\([^;]*;', s)
if m and 'setWlDmabuf' not in s:
    block = m.group(0)
    s = s.replace(block, block + '\n#ifdef WANT_LINDROID_DRM\n    window->setWlDmabuf(wdpy->wl_dmabuf);\n#endif', 1)
    changed.append('setter call')

# 3f. GetDisplay 初始化
if 'wdpy->wl_dmabuf = NULL;' not in s:
    s = s.replace('wdpy->wlegl = NULL;', 'wdpy->wlegl = NULL;\n\twdpy->wl_dmabuf = NULL;', 1)
    changed.append('init NULL')

open(path, 'w', encoding='utf-8', errors='surrogateescape').write(s)
print("  改动: " + (", ".join(changed) if changed else "(无)"))
PY

# ---------------------------------------------------------------------------
# 4. 编译
# ---------------------------------------------------------------------------
say "编译 eglplatform_wayland"
cd "$EGL"
rm -f .libs/eglplatform_wayland.so

if make -j"$(nproc)" > /tmp/eglbuild.log 2>&1; then
    ok "编译成功"
    tail -3 /tmp/eglbuild.log | sed 's/^/    /'
    if [ -f .libs/eglplatform_wayland.so ]; then
        cp -f .libs/eglplatform_wayland.so "$HY/inst/lib/"
        ok "已装到 $HY/inst/lib/"
    fi
else
    warn "编译失败，最后 24 行："
    tail -24 /tmp/eglbuild.log | sed 's/^/    /'
    exit 1
fi

echo
say "完成"
echo "  验证："
echo "    droidspaces --name=Debian run -- sh -c '. /opt/hy/mali-gpu.env && HYBRIS_EGLPLATFORM=wayland /opt/hy/gl_verify'"