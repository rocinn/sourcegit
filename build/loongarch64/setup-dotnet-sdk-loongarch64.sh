#!/usr/bin/env bash
# =============================================================================
# 在 loongarch64（龙芯）上准备 .NET 10 SDK
#
# 背景：微软官方从未发布 linux-loongarch64 的 .NET SDK（仅有运行时），
#       因此这里用「上游 x64 SDK 载荷 + Loongnix 官方 loongarch64 运行时」
#       组装出一套可用的 .NET 10 SDK：
#         1) 下载上游 dotnet-sdk-10.0.403-linux-x64.tar.gz 的托管载荷
#         2) 从 Loongnix NuGet 源取 microsoft.netcore.app.{runtime,host}.linux-loongarch64
#         3) 替换 muxer / hostfxr / shared framework / apphost 模板
#         4) 把 SDK 内 x64 的 R2R 程序集标记改写为 loongarch64（CLR 回退到 IL 执行）
#         5) 把 4 个 x86_64 单文件 bundle 启动器换成 shell 包装器
#
# 用法： bash setup-dotnet-sdk-loongarch64.sh [安装目录(默认 ~/.dotnet10)]
# =============================================================================
set -euo pipefail

ROOT="${1:-$HOME/.dotnet10}"
SDK_VER="10.0.403"
RUNTIME_VER="10.0.14"
LOONG_NUGET="https://nuget.loongnix.cn/v3/package"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 1/6 下载 .NET ${SDK_VER} SDK 载荷 (x64)"
if [[ ! -f "$WORK/sdk.tar.gz" ]]; then
  wget -q -O "$WORK/sdk.tar.gz" \
    "https://builds.dotnet.microsoft.com/dotnet/Sdk/${SDK_VER}/dotnet-sdk-${SDK_VER}-linux-x64.tar.gz"
fi

echo "==> 2/6 下载 loongarch64 运行时与宿主包"
for p in microsoft.netcore.app.runtime.linux-loongarch64 microsoft.netcore.app.host.linux-loongarch64; do
  wget -q -O "$WORK/$p.nupkg" "$LOONG_NUGET/$p/$RUNTIME_VER/$p.$RUNTIME_VER.nupkg"
done
python3 - "$WORK" <<'PY'
import sys, zipfile, os
w = sys.argv[1]
for name in ("microsoft.netcore.app.runtime.linux-loongarch64",
             "microsoft.netcore.app.host.linux-loongarch64"):
    zipfile.ZipFile(os.path.join(w, name + ".nupkg")).extractall(os.path.join(w, name))
PY

echo "==> 3/6 解包 SDK 载荷"
mkdir -p "$WORK/sdk" && tar -xzf "$WORK/sdk.tar.gz" -C "$WORK/sdk"

echo "==> 4/6 组装 $ROOT"
rm -rf "$ROOT"
cp -a "$WORK/sdk/." "$ROOT/"
cp -f /usr/share/dotnet/dotnet "$ROOT/dotnet"                      # loongarch64 muxer
rm -rf "$ROOT/host/fxr"
mkdir -p "$ROOT/host/fxr/$RUNTIME_VER"
cp "$WORK/microsoft.netcore.app.runtime.linux-loongarch64/runtimes/linux-loongarch64/native/libhostfxr.so" \
   "$ROOT/host/fxr/$RUNTIME_VER/libhostfxr.so"
rm -rf "$ROOT/shared/Microsoft.NETCore.App"
mkdir -p "$ROOT/shared/Microsoft.NETCore.App/$RUNTIME_VER"
cp -a "$WORK/microsoft.netcore.app.runtime.linux-loongarch64/runtimes/linux-loongarch64/lib/net$RUNTIME_VER/." \
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
