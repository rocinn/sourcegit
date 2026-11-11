#!/usr/bin/env bash
# =============================================================================
# 构建 SourceGit 的 loongarch64（龙芯）本机版本
#
# 前提：已执行 setup-dotnet-sdk-loongarch64.sh 生成 ~/.dotnet10
#       NuGet 源需按 README 的「NuGet 配置」一节设置（loongnix + 源映射），
#       否则 SkiaSharp/HarfBuzz 的 loongarch64 原生库会被解析成无原生库的版本。
#
# 注意：子模块 depends/AvaloniaEdit 自带会 <clear/> 包源的 NuGet.config，
#       首次构建可能在子模块项目上报 NU1101（找不到 loongarch64 运行时包）。
#       这是预期现象：主项目已把包灌进 ~/.nuget/packages，**重跑一次即可**。
#
# 用法： bash build-loongarch64.sh [仓库根目录]
# =============================================================================
set -euo pipefail

REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
SDK_ROOT="$HOME/.dotnet10"
RID="linux-loongarch64"

export DOTNET_ROOT="$SDK_ROOT"
export PATH="$SDK_ROOT:$PATH"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1

cd "$REPO"

# 子模块（depends/AvaloniaEdit）必须存在
if [[ ! -f depends/AvaloniaEdit/src/AvaloniaEdit/AvaloniaEdit.csproj ]]; then
  git submodule update --init --recursive
fi

# loongarch64 尚无 ILCompiler（NativeAOT）包，只能走 JIT 发布
"$SDK_ROOT/dotnet" publish src/SourceGit.csproj \
  -c Release \
  -r "$RID" \
  --self-contained true \
  -p:DisableAOT=true \
  -o "out/$RID"

echo
echo "完成： $REPO/out/$RID"
file "out/$RID/SourceGit"
