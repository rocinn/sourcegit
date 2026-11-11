#!/bin/bash
# ---------------------------------------------------------------------------
# SourceGit (loongarch64, Loongnix 25 / LoongArch ABI 2.0) 启动包装脚本
#
# 本文件在 ABI1（Loongnix 20）版本基础上按本机（ABI2）行为做了两处调整：
#
# 1) 文件选择器 / GTK
#    ABI1 机器上必须禁用 GTK，否则点「打开文件夹」时 libSkiaSharp.so 内嵌的
#    FreeType 2.13.1 会抢占系统 FreeType 2.11 的 FT_* 符号（两者 ABI 不兼容），
#    pango 排版时把堆踩坏 → glibc abort。详见 CRASH-ANALYSIS-freetype-gtk.md。
#
#    本机（Loongnix 25 + KDE）上 Avalonia 11.3 走的是 xdg-desktop-portal
#    （DBus，KDE 的 Qt 文件对话框），**根本不 dlopen GTK**，所以默认不再禁用
#    GTK，保留桌面原生的文件对话框体验。
#    只有两种情况才退回「禁用 GTK」：没有 portal 会话总线（如某些精简桌面/
#    自启动环境）或显式设置 SOURCEGIT_DISABLE_GTK=1。
#
#    注意：.NET 运行时本身是 ABI1 构建，在本机由 /lib64/ld.so.1
#    （→ app-compat 里的 ld-2.28）加载，GTK/FreeType 等也是 app-compat 里的
#    ABI1 版本，所以「GTK + 旧 FreeType」的冲突条件依然存在，只是默认不触发。
#
# 2) Git 版本
#    ABI1 机器系统 Git 只有 2.20.1，缺 `%(worktreepath)` 原子（需 >= 2.31），
#    所以当时要自装 ~/.local/bin/git 并在 PATH 里前置。
#    本机系统 Git 为 2.47.2，已满足要求，不再改 PATH，只保留版本自检提示。
# ---------------------------------------------------------------------------
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 仓库内运行时，publish 产物在（已被 .gitignore 忽略的）out/ 下；
# 安装版（deb）里包装脚本与二进制同目录，OUT_DIR 指向自身目录。
if [ -x "$DIR/SourceGit" ]; then
    APP="$DIR/SourceGit"
    OUT_DIR="$DIR"
else
    OUT_DIR="$(cd "$DIR/../../out" 2>/dev/null && pwd || echo "$DIR/../../out")"
    APP="$OUT_DIR/linux-loongarch64/SourceGit"
fi

[ -x "$APP" ] || { echo "SourceGit binary not found: $APP" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 文件选择器：有 xdg-desktop-portal 就不动 GTK；否则禁用 GTK 走托管选择器
# ---------------------------------------------------------------------------
portal_available() {
    [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || return 1
    command -v busctl >/dev/null 2>&1 || return 1
    busctl --user status org.freedesktop.portal.Desktop >/dev/null 2>&1
}

if [ "${SOURCEGIT_DISABLE_GTK:-0}" = "1" ] || ! portal_available; then
    STUB="$OUT_DIR/no-gtk"
    mkdir -p "$STUB"
    # 一个非法 ELF：dlopen("libgtk-3.so.0") 必然失败，Avalonia 退回托管选择器
    printf 'libgtk-3.so.0 is intentionally disabled - see CRASH-ANALYSIS-freetype-gtk.md\n' \
        > "$STUB/libgtk-3.so.0"
    export LD_LIBRARY_PATH="$STUB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# ---------------------------------------------------------------------------
# Git 版本自检：`%(worktreepath)` 原子需要 Git >= 2.31，过旧会让分支列表静默变空
# ---------------------------------------------------------------------------
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
