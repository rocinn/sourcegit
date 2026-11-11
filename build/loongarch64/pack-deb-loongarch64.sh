#!/usr/bin/env bash
# =============================================================================
# 把 out/linux-loongarch64 的 publish 产物打成 Debian 包（Architecture: loong64）
#
# 前提：已执行 build-loongarch64.sh，产物在 out/linux-loongarch64/
#
# 用法： bash pack-deb-loongarch64.sh [版本号] [仓库根目录]
#   版本号默认取仓库根目录的 VERSION 文件（当前 2026.24）
#
# 产出： out/sourcegit_<版本>-1_loong64.deb
#
# 本文件是 Loongnix 25（LoongArch ABI 2.0）适配版，与 ABI1 版的差异：
#   * Depends 改为本机可满足的包名：libicu76 / libssl3t64 / libglib2.0-0t64 等
#     （ABI1 机器是 libicu67 / libssl1.1 / libglib2.0-0）
#   * 版本号默认从 VERSION 文件读取，不再写死
#   * 启动包装脚本不再无条件禁用 GTK：有 xdg-desktop-portal 时保留原生文件对话框
#
# 包内布局：
#   /opt/sourcegit/                      publish 产物（SourceGit 可执行文件等）
#   /opt/sourcegit/sourcegit-launch.sh   启动包装脚本（选择器/self-check 逻辑）
#   /usr/bin/sourcegit                   → /opt/sourcegit/sourcegit-launch.sh
#   /usr/share/applications/sourcegit.desktop   Exec=/usr/bin/sourcegit %u
#   /usr/share/icons/sourcegit.png
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${2:-$(cd "$DIR/../.." && pwd)}"
VER="${1:-$(cat "$REPO/VERSION" 2>/dev/null || echo 2026.24)}"
VER="${VER//$'\n'/}"

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
rm -rf "$STAGE/opt/sourcegit/no-gtk"   # 运行时按需 created，不随包分发

# ---------------------------------------------------------------------------
# 2. 启动包装脚本（改动请同步 build/loongarch64/sourcegit-launch.sh）
# ---------------------------------------------------------------------------
cat > "$STAGE/opt/sourcegit/sourcegit-launch.sh" <<'EOS'
#!/bin/bash
# ---------------------------------------------------------------------------
# SourceGit (loongarch64 / LoongArch ABI 2.0, Debian 安装版) 启动包装脚本
#
# 文件选择器：
#   本机 Avalonia 11.3 走 xdg-desktop-portal（DBus）打开文件/文件夹对话框，
#   不会加载 GTK，因此默认保留桌面原生对话框。
#   仅当没有 portal 会话总线、或显式设置 SOURCEGIT_DISABLE_GTK=1 时，才禁用
#   GTK 走托管选择器 —— 以规避 libSkiaSharp.so 内嵌 FreeType 2.13.1 抢占
#   app-compat 中 FreeType 2.11 符号导致的「打开文件夹」崩溃
#   （详见 CRASH-ANALYSIS-freetype-gtk.md）。
#
# Git 版本：
#   本机系统 Git 2.47.2 已满足 >= 2.31（%(worktreepath) 原子），只做自检提示。
# ---------------------------------------------------------------------------
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/SourceGit"
[ -x "$APP" ] || { echo "SourceGit binary not found: $APP" >&2; exit 1; }

portal_available() {
    [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || return 1
    command -v busctl >/dev/null 2>&1 || return 1
    busctl --user status org.freedesktop.portal.Desktop >/dev/null 2>&1
}

if [ "${SOURCEGIT_DISABLE_GTK:-0}" = "1" ] || ! portal_available; then
    STUB="$DIR/no-gtk"
    mkdir -p "$STUB"
    printf 'libgtk-3.so.0 is intentionally disabled - see CRASH-ANALYSIS-freetype-gtk.md\n' \
        > "$STUB/libgtk-3.so.0"
    export LD_LIBRARY_PATH="$STUB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

git_ver="$(git --version 2>/dev/null | awk '{print $3}')"
if [ -n "$git_ver" ]; then
    g_major="${git_ver%%.*}"
    g_rest="${git_ver#*.}"
    g_minor="${g_rest%%.*}"
    if [ "$g_major" -eq 2 ] 2>/dev/null && [ "$g_minor" -lt 31 ] 2>/dev/null; then
        echo "警告：当前 git 为 $git_ver（$(command -v git)），低于 SourceGit 分支列表所需的 2.31，" >&2
        echo "       分支树可能显示为空。请安装新版 git 并在偏好设置的「Git 安装路径」里指定。" >&2
    fi
fi

exec "$APP" "$@"
EOS
chmod 755 "$STAGE/opt/sourcegit/sourcegit-launch.sh"

# ---------------------------------------------------------------------------
# 3. /usr/bin/sourcegit → 包装脚本（命令行与桌面项都走它）
# ---------------------------------------------------------------------------
ln -s /opt/sourcegit/sourcegit-launch.sh "$STAGE/usr/bin/sourcegit"

# ---------------------------------------------------------------------------
# 4. 桌面项：Exec 必须指向真实存在的路径
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

# 依赖按 Loongnix 25（Debian 13/trixie 系）的包名书写，同时保留旧名作为备选：
#   libicu76 | libicu72 | libicu67   ICU（.NET 必需）
#   libssl3t64 | libssl3 | libssl1.1 OpenSSL（System.Security.Cryptography.Native）
#   libglib2.0-0t64 | libglib2.0-0   GLib
cat > "$STAGE/DEBIAN/control" <<EOF
Package: sourcegit
Version: $VER
Priority: optional
Depends: libx11-6, libice6, libsm6, libxcursor1, libxrandr2, libxi6, libxext6, libxrender1, libfontconfig1, libfreetype6, libgl1, libicu76 | libicu72 | libicu67, libssl3t64 | libssl3 | libssl1.1, libglib2.0-0t64 | libglib2.0-0, zlib1g, xdg-utils
Architecture: loong64
Installed-Size: $INSTALLED_SIZE
Maintainer: longshuang@msn.cn
X-Target-Distro: Loongnix 25 / LoongArch ABI 2.0
X-Runtime-Note: runs the ABI1-built .NET runtime through the /lib64/ld.so.1 app-compat loader
Description: Open-source & Free Git GUI Client
 Built for loongarch64 (Loongson) with .NET 10 (JIT, self-contained).
 Runs on Loongnix 25 / LoongArch ABI 2.0 via the system's app-compat loader.
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
