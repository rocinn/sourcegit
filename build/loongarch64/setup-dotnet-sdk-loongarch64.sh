#!/usr/bin/env bash
# =============================================================================
# 在 loongarch64（龙芯）上准备 .NET 10 SDK —— LoongArch psABI v2.0（ABI2）适配版
#
# 背景：
#   1) 微软官方从未发布 linux-loongarch64 的 .NET SDK（仅有运行时），
#      因此这里用「上游 x64 SDK 载荷 + Loongnix 官方 loongarch64 运行时」
#      组装出一套可用的 .NET 10 SDK；
#   2) 本机是 Loongnix 25 / glibc 2.41 / gcc 14，属于 **LoongArch ABI 2.0**
#      系统（ELF e_flags 带 OBJ-v1 标记 = 0x40）。Loongnix NuGet 源提供的
#      loongarch64 运行时是 ABI 1.0 构建（e_flags 0x3 / OBJ-v0）；
#      ABI2 内核与 glibc 对 ABI1 二进制保持向后兼容，实测可直接运行。
#      但 **本机没有系统 dotnet**，所以 muxer（`dotnet` 宿主）也要从
#      NuGet 的 runtime.linux-loongarch64.Microsoft.NETCore.DotNetHost 取。
#
# 步骤：
#   0) 探测本机 ABI，打印 e_flags（ABI2 期望 OBJ-v1）
#   1) 下载上游 dotnet-sdk-<ver>-linux-x64.tar.gz 的托管载荷
#   2) 从 Loongnix NuGet 源取 loongarch64 的
#      microsoft.netcore.app.{runtime,host}.linux-loongarch64 与
#      runtime.linux-loongarch64.Microsoft.NETCore.DotNetHost
#   3) 解包 SDK 载荷
#   4) 组装：muxer / hostfxr / shared framework / apphost 模板
#   5) 把 SDK 内 x64 的 R2R 程序集标记改写为 loongarch64（CLR 回退到 IL 执行）
#   6) 把 4 个 x86_64 单文件 bundle 启动器换成 shell 包装器
#
# 用法： bash setup-dotnet-sdk-loongarch64.sh [安装目录(默认 ~/.dotnet10)]
#
# 可用环境变量覆盖：
#   SDK_VER=10.0.403  RUNTIME_VER=10.0.14  MUXER_VER=8.0.34
#   WORK=<下载缓存目录，默认 ~/.cache/sourcegit-abi2/work>
# =============================================================================
set -euo pipefail

ROOT="${1:-$HOME/.dotnet10}"
SDK_VER="${SDK_VER:-10.0.403}"
RUNTIME_VER="${RUNTIME_VER:-10.0.14}"
# loongarch64 的独立 muxer 目前只发到 8.0.x；muxer 只负责定位 hostfxr，
# 与运行时大版本无关（本机实测 8.0.34 muxer + 10.0.14 hostfxr 可用）。
MUXER_VER="${MUXER_VER:-8.0.34}"
LOONG_NUGET="https://nuget.loongnix.cn/v3/package"
WORK="${WORK:-$HOME/.cache/sourcegit-abi2/work}"

SDK_URLS=(
  "https://builds.dotnet.microsoft.com/dotnet/Sdk/${SDK_VER}/dotnet-sdk-${SDK_VER}-linux-x64.tar.gz"
  "https://dotnetcli.blob.core.windows.net/dotnet/Sdk/${SDK_VER}/dotnet-sdk-${SDK_VER}-linux-x64.tar.gz"
)

get() {  # get <url> <out>：下载到 .part 再改名，避免中断留下半截缓存
  local url="$1" out="$2"
  [[ -s "$out" ]] && return 0
  echo "    下载 $(basename "$out")"
  wget -q -O "$out.part" "$url" && mv -f "$out.part" "$out"
}

mkdir -p "$WORK"

echo "==> 0/6 探测本机 ABI"
HOST_FLAGS="$(readelf -h /bin/ls 2>/dev/null | sed -n 's/.*0x\([0-9a-f]*\),.*/\1/p' | head -1)"
if [[ -n "${HOST_FLAGS:-}" ]]; then
  printf '    /bin/ls e_flags = 0x%s' "$HOST_FLAGS"
  if (( (16#$HOST_FLAGS) & 0x40 )); then
    echo "  (OBJ-v1 → 本机为 LoongArch ABI 2.0)"
  else
    echo "  (OBJ-v0 → 本机为 LoongArch ABI 1.0)"
  fi
else
  echo "    无法读取 e_flags（缺 readelf？）"
fi

echo "==> 1/6 下载 .NET ${SDK_VER} SDK 载荷 (x64)"
if [[ ! -s "$WORK/sdk.tar.gz" ]]; then
  for u in "${SDK_URLS[@]}"; do
    if wget -q -O "$WORK/sdk.tar.gz.part" "$u"; then
      mv -f "$WORK/sdk.tar.gz.part" "$WORK/sdk.tar.gz"
      break
    fi
    rm -f "$WORK/sdk.tar.gz.part"
  done
fi
[[ -s "$WORK/sdk.tar.gz" ]] || { echo "下载 SDK 载荷失败" >&2; exit 1; }

echo "==> 2/6 下载 loongarch64 运行时 / 宿主包"
get "$LOONG_NUGET/microsoft.netcore.app.runtime.linux-loongarch64/$RUNTIME_VER/microsoft.netcore.app.runtime.linux-loongarch64.$RUNTIME_VER.nupkg" \
    "$WORK/microsoft.netcore.app.runtime.linux-loongarch64.nupkg"
get "$LOONG_NUGET/microsoft.netcore.app.host.linux-loongarch64/$RUNTIME_VER/microsoft.netcore.app.host.linux-loongarch64.$RUNTIME_VER.nupkg" \
    "$WORK/microsoft.netcore.app.host.linux-loongarch64.nupkg"
get "$LOONG_NUGET/runtime.linux-loongarch64.Microsoft.NETCore.DotNetHost/$MUXER_VER/runtime.linux-loongarch64.Microsoft.NETCore.DotNetHost.$MUXER_VER.nupkg" \
    "$WORK/runtime.linux-loongarch64.Microsoft.NETCore.DotNetHost.nupkg"

python3 - "$WORK" <<'PY'
import sys, zipfile, os
w = sys.argv[1]
for name in ("microsoft.netcore.app.runtime.linux-loongarch64",
             "microsoft.netcore.app.host.linux-loongarch64",
             "runtime.linux-loongarch64.Microsoft.NETCore.DotNetHost"):
    dst = os.path.join(w, name)
    if os.path.isdir(dst) and os.listdir(dst):
        continue
    zipfile.ZipFile(os.path.join(w, name + ".nupkg")).extractall(dst)
PY

echo "==> 3/6 解包 SDK 载荷"
rm -rf "$WORK/sdk"
mkdir -p "$WORK/sdk" && tar -xzf "$WORK/sdk.tar.gz" -C "$WORK/sdk"

echo "==> 4/6 组装 $ROOT"
rm -rf "$ROOT"
cp -a "$WORK/sdk/." "$ROOT/"
# muxer：优先用 NuGet 里的 loongarch64 版（本机没有系统 dotnet）；
# 若系统 /usr/share/dotnet/dotnet 存在（Loongnix 20 这类旧机器）则沿用系统版。
if [[ -f "$WORK/runtime.linux-loongarch64.Microsoft.NETCore.DotNetHost/runtimes/linux-loongarch64/native/dotnet" ]]; then
  cp -f "$WORK/runtime.linux-loongarch64.Microsoft.NETCore.DotNetHost/runtimes/linux-loongarch64/native/dotnet" "$ROOT/dotnet"
elif [[ -f /usr/share/dotnet/dotnet ]]; then
  cp -f /usr/share/dotnet/dotnet "$ROOT/dotnet"
else
  echo "找不到 loongarch64 muxer（NuGet DotNetHost 与系统 dotnet 均不存在）" >&2
  exit 1
fi
NET_TFM="net${RUNTIME_VER%.*}"
rm -rf "$ROOT/host/fxr"
mkdir -p "$ROOT/host/fxr/$RUNTIME_VER"
cp "$WORK/microsoft.netcore.app.runtime.linux-loongarch64/runtimes/linux-loongarch64/native/libhostfxr.so" \
   "$ROOT/host/fxr/$RUNTIME_VER/libhostfxr.so"
rm -rf "$ROOT/shared/Microsoft.NETCore.App"
mkdir -p "$ROOT/shared/Microsoft.NETCore.App/$RUNTIME_VER"
cp -a "$WORK/microsoft.netcore.app.runtime.linux-loongarch64/runtimes/linux-loongarch64/lib/$NET_TFM/." \
      "$ROOT/shared/Microsoft.NETCore.App/$RUNTIME_VER/"
cp -a "$WORK/microsoft.netcore.app.runtime.linux-loongarch64/runtimes/linux-loongarch64/native/." \
      "$ROOT/shared/Microsoft.NETCore.App/$RUNTIME_VER/"
rm -rf "$ROOT/packs/Microsoft.NETCore.App.Host.linux-x64"
mkdir -p "$ROOT/packs/Microsoft.NETCore.App.Host.linux-loongarch64/$RUNTIME_VER"
cp -a "$WORK/microsoft.netcore.app.host.linux-loongarch64/runtimes" \
      "$ROOT/packs/Microsoft.NETCore.App.Host.linux-loongarch64/$RUNTIME_VER/"
cp -f "$ROOT/packs/Microsoft.NETCore.App.Host.linux-loongarch64/$RUNTIME_VER/runtimes/linux-loongarch64/native/apphost" \
      "$ROOT/sdk/$SDK_VER/AppHostTemplate/apphost"
chmod +x "$ROOT/dotnet" "$ROOT/sdk/$SDK_VER/AppHostTemplate/apphost"

echo "==> 5/6 改写 R2R 程序集架构标记 (0xfd1d -> 0x191d)"
python3 - "$ROOT/sdk/$SDK_VER" <<'PY'
import os, struct, sys
root = sys.argv[1]
n = 0
for dp, _, fns in os.walk(root):
    for f in fns:
        if not f.endswith(('.dll', '.exe')):
            continue
        p = os.path.join(dp, f)
        with open(p, 'r+b') as fh:
            head = fh.read(0x200)
            if head[:2] != b'MZ':
                continue
            e = struct.unpack_from('<I', head, 0x3c)[0]
            if head[e:e+4] != b'PE\0\0':
                continue
            m = struct.unpack_from('<H', head, e+4)[0]
            if m == 0xfd1d:                     # x64 R2R 复合镜像标记
                fh.seek(e+4); fh.write(struct.pack('<H', 0x191d))  # loongarch64 标记
                n += 1
print(f"    已改写 {n} 个程序集")
PY

echo "==> 6/6 替换 x86_64 原生启动器"
for f in "Roslyn/bincore/csc:csc.dll" "Roslyn/bincore/vbc:vbc.dll" \
         "Roslyn/bincore/VBCSCompiler:VBCSCompiler.dll" "MSBuild:MSBuild.dll"; do
  rel="${f%%:*}"; dll="${f##*:}"
  cat > "$ROOT/sdk/$SDK_VER/$rel" <<EOF
#!/bin/sh
export DOTNET_HOST_PATH="\${DOTNET_HOST_PATH:-$ROOT/dotnet}"
exec "\$DOTNET_HOST_PATH" exec "\$(dirname "\$0")/$dll" "\$@"
EOF
  chmod +x "$ROOT/sdk/$SDK_VER/$rel"
done

echo
echo "完成。验证： DOTNET_ROOT=$ROOT $ROOT/dotnet --info"
