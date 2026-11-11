#!/usr/bin/env bash
# =============================================================================
# 把 out/linux-loongarch64 的 publish 产物打成 Debian 包（Architecture: loong64）
#
# 前提：已执行 build-loongarch64.sh，产物在 out/linux-loongarch64/
#
# 用法： bash pack-deb-loongarch64.sh [版本号] [仓库根目录]
#   版本号默认 2026.24
#
# 产出： out/sourcegit_<版本>-1_loong64.deb
#
# 包内布局：
#   /opt/sourcegit/                      publish 产物（SourceGit 可执行文件等）
#   /opt/sourcegit/sourcegit-launch.sh   启动包装脚本（禁 GTK + PATH 加固 + git 版本自检）
#   /usr/bin/sourcegit                   → /opt/sourcegit/sourcegit-launch.sh
#   /usr/share/applications/sourcegit.desktop   Exec=/usr/bin/sourcegit %u
#   /usr/share/icons/sourcegit.png
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${2:-$(cd "$DIR/../.." && pwd)}"
VER="${1:-2026.24}"

PUBLISH="$REPO/out/linux-loongarch64"
ICON="$REPO/build/resources/_common/icons/sourcegit.png"
OUT="$REPO/out/sourcegit_${VER}-1_loong64.deb"

if [ ! -x "$PUBLISH/SourceGit" ]; then
    echo "找不到 publish 产物：$PUBLISH/SourceGit" >&2
    echo "请先执行： bash build/loongarch64/build-loongarch64.sh" >&2
    exit 1
fi

if [ ! -f "$ICON" ]; then
    echo "找不到图标：$ICON" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# ---------------------------------------------------------------------------
# 1. 载荷：/opt/sourcegit
# ---------------------------------------------------------------------------
install -d "$STAGE/DEBIAN" "$STAGE/opt/sourcegit" "$STAGE/usr/bin" \
           "$STAGE/usr/share/applications" "$STAGE/usr/share/icons"
cp -a "$PUBLISH/." "$STAGE/opt/sourcegit/"
chmod 755 "$STAGE/opt/sourcegit/SourceGit"

# ---------------------------------------------------------------------------
# 2. 启动包装脚本：禁 GTK + PATH 加固 + Git 版本自检
#    （与 build/loongarch64/sourcegit-launch.sh 同一思路，改动请同步两边）
# ---------------------------------------------------------------------------
cat > "$STAGE/opt/sourcegit/sourcegit-launch.sh" <<'EOS'
#!/bin/bash
# ---------------------------------------------------------------------------
# SourceGit (loongarch64, Debian 安装版) 启动包装脚本
#
# 1) 禁用 GTK：制造一个无法加载的 libgtk-3.so.0，让 Avalonia 走托管文件选择器，
#    规避 libSkiaSharp.so 内嵌 FreeType 抢占系统 FreeType 导致的
#    「打开文件夹」崩溃（详见 CRASH-ANALYSIS-freetype-gtk.md）。
# 2) PATH 前置 ~/.local/bin：优先使用自装的新版 Git。
# 3) Git 版本自检：%(worktreepath) 原子需要 Git >= 2.31，过旧会静默返回空分支列表。
# ---------------------------------------------------------------------------
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STUB="$DIR/no-gtk"
mkdir -p "$STUB"
printf 'libgtk-3.so.0 is intentionally disabled - see CRASH-ANALYSIS-freetype-gtk.md\n' \
    > "$STUB/libgtk-3.so.0"
export LD_LIBRARY_PATH="$STUB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

export PATH="$HOME/.local/bin:$PATH"

git_ver="$(git --version 2>/dev/null | awk '{print $3}')"
if [ -n "$git_ver" ]; then
    g_major="${git_ver%%.*}"
    g_rest="${git_ver#*.}"
    g_minor="${g_rest%%.*}"
    if [ "$g_major" -eq 2 ] 2>/dev/null && [ "$g_minor" -lt 31 ] 2>/dev/null; then
        echo "警告：当前 git 为 $git_ver（$(command -v git)），低于 SourceGit 分支列表所需的 2.31，" >&2
        echo "       分支树可能显示为空。请安装新版 git（如 ~/.local/bin/git），" >&2
        echo "       并在偏好设置的「Git 安装路径」里指定它。" >&2
    fi
fi

exec "$DIR/SourceGit" "$@"
EOS
chmod 755 "$STAGE/opt/sourcegit/sourcegit-launch.sh"

# ---------------------------------------------------------------------------
# 3. /usr/bin/sourcegit → 包装脚本（命令行与桌面项都走它）
# ---------------------------------------------------------------------------
ln -s /opt/sourcegit/sourcegit-launch.sh "$STAGE/usr/bin/sourcegit"

# ---------------------------------------------------------------------------
# 4. 桌面项：Exec 必须指向真实存在的路径（2026-11-10 手工打的旧包写的是
#    /opt/sourcegit/sourcegit，而实际二进制名是 SourceGit 大写 S，点了起不来）
# ---------------------------------------------------------------------------
cat > "$STAGE/usr/share/applications/sourcegit.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=SourceGit
Name[zh_CN]=SourceGit
Comment=Open-source & Free Git GUI Client
Comment[zh_CN]=开源免费的 Git 图形客户端
Exec=/usr/bin/sourcegit %u
TryExec=/usr/bin/sourcegit
Icon=/usr/share/icons/sourcegit.png
Terminal=false
StartupNotify=true
StartupWMClass=SourceGit
Categories=Development;RevisionControl;
MimeType=inode/directory;
EOF

cp "$ICON" "$STAGE/usr/share/icons/sourcegit.png"

# ---------------------------------------------------------------------------
# 5. control + postinst
# ---------------------------------------------------------------------------
INSTALLED_SIZE="$(du -ks "$STAGE/opt/sourcegit" | cut -f1)"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: sourcegit
Version: $VER
Priority: optional
Depends: libx11-6, libice6, libsm6, libxcursor1, libxrandr2, libfontconfig1, libfreetype6, libicu67 | libicu63 | libicu, libssl1.1 | libssl3, libglib2.0-0, zlib1g, xdg-utils
Architecture: loong64
Installed-Size: $INSTALLED_SIZE
Maintainer: longshuang@msn.cn
Description: Open-source & Free Git GUI Client
 Built for loongarch64 (Loongson) with .NET 10 (JIT, self-contained).
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOS'
#!/bin/sh
set -e
case "$1" in
    configure)
        update-desktop-database /usr/share/applications 2>/dev/null || true
        gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
        ;;
    abort-upgrade|abort-remove|abort-deconfigure)
        ;;
    *)
        echo "postinst called with unknown argument \`$1'" >&2
        exit 1
        ;;
esac
exit 0
EOS
chmod 755 "$STAGE/DEBIAN/postinst"

# ---------------------------------------------------------------------------
# 6. 打包
# ---------------------------------------------------------------------------
dpkg-deb --build --root-owner-group "$STAGE" "$OUT" >/dev/null

echo "完成： $OUT"
dpkg-deb --info "$OUT" | sed -n '2,12p'
echo
echo "包内关键文件："
dpkg-deb --contents "$OUT" | grep -E "sourcegit-launch|/usr/bin/sourcegit|applications/sourcegit.desktop|opt/sourcegit/SourceGit$"
