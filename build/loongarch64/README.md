# SourceGit — loongarch64（龙芯）本机构建 · LoongArch ABI 2.0 版

本目录是 SourceGit `2026.24` 在龙芯 **loongarch64** 上的构建脚本、分析文档与会话纪要。
构建产物放在仓库根目录的 `out/`（已被 `.gitignore` 忽略，不入库）。

> **两代机器的区别**：ABI1 适配（3A6000 NUC / Loongnix 20，主机名 `m700s`）做在
> `feature/3a6000nuc-abi1` 分支上；当前分支 `feature/Meta-3b6000-abi2` 的内容已按
> **3B6000 / Loongnix 25（LoongArch ABI 2.0，主机名 `b6000`）** 重新适配并实机验证。
> ABI1 时期的现象与结论保留在 `sessions/2026-11-10-*.md`，ABI2 的适配过程见
> `sessions/2026-11-11-ABI2适配.md`。

## 环境对比

| 项目 | ABI1（旧机 m700s：3A6000 / Loongnix 20） | ABI2（本机 b6000：3B6000 / Loongnix 25） |
| --- | --- | --- |
| 系统 | Loongnix 20 (DaoXiangHu) | **Loongnix GNU/Linux 25** |
| 内核 | — | 6.6.52-loong64 |
| glibc | 2.28 | **2.41-13.lnd.1** |
| gcc / binutils | — | 14.2.0 / 2.44 |
| ELF e_flags | `0x3`（OBJ-v0） | **`0x43`（DOUBLE-FLOAT + OBJ-v1）** |
| 系统 Git | 2.20.1（缺 `%(worktreepath)`） | **2.47.2**（满足 >= 2.31） |
| 系统 dotnet | 有 `/usr/share/dotnet/dotnet`（8.0.22） | **无** |
| ICU / OpenSSL | libicu67 / libssl1.1 | libicu76 / libssl3t64 3.5.4 |
| 桌面 / 文件对话框 | KDE，Avalonia 走 GTK3 | **KDE Plasma，Avalonia 走 xdg-desktop-portal** |

### 如何判定本机是 ABI2

```sh
readelf -h /bin/ls | grep -E 'Flags|标志'
#  标志： 0x43, DOUBLE-FLOAT, OBJ-v1     ← ABI 2.0（本机）
#  标志： 0x3,  DOUBLE-FLOAT, OBJ-v0     ← ABI 1.0（旧机器 / Loongnix NuGet 的 .NET 运行时）
```

e_flags 的 `0x40` 位是 LoongArch psABI v2.0 引入的 **OBJ-v1** 对象 ABI 标记，
由 gcc 14 / binutils 2.44 默认产生。`setup-dotnet-sdk-loongarch64.sh` 的第 0 步会自动探测并打印。

### 关键结论：.NET 运行时仍是 ABI1 构建，但能在本机直接跑

* 微软与 Loongnix 都**没有发布 loongarch64 的 .NET 10 运行时 ABI2 构建**，
  Loongnix NuGet 源里的 `microsoft.netcore.app.runtime.linux-loongarch64` 10.0.14
  实际是 **e_flags `0x3`（ABI 1.0）**；
* 本机保留了一整套 **ABI1 兼容运行库** `/usr/local/app-compat/`，
  且 `/lib64/ld.so.1` 指向兼容层的 `ld-2.28.so`。ABI1 二进制（我们的 apphost、
  libcoreclr、libSystem.Native…）由这个旧 loader 启动，整个进程的
  libc/libicu/libssl/libfreetype/fontconfig 都来自 app-compat：
  `/proc/<pid>/maps` 里能看到 `libc-2.28.so`、`libicuuc.so.67.1`、`libssl` 1.1、
  `libfreetype.so.6.16.1`、`libfontconfig.so.1.12.0`（共 225 个映射）。
* 因此**托管层与原生依赖都自洽**，实测 `dotnet --info`、`dotnet publish`、
  GUI 启动、文件选择器全部正常；不需要（也没有）为 ABI2 重新编译 .NET 运行时。

## 与 ABI1 版脚本的差异（适配点）

1. **muxer 来源**：本机没有系统 dotnet。muxer（`dotnet` 宿主）改为从 Loongnix NuGet 的
   `runtime.linux-loongarch64.Microsoft.NETCore.DotNetHost` **8.0.34** 取
   （loongarch64 独立 muxer 只发到 8.0.x；muxer 只负责定位 hostfxr，与 10.0 运行时兼容，
   实测可用）。系统有 `/usr/share/dotnet/dotnet` 的旧机器仍会优先用系统版。
2. **NuGet 源映射**：`nuget.org` 上的 `SkiaSharp.NativeAssets.Linux 2.88.9`
   **不含 linux-loongarch64 原生库**，若不锁定源，发布产物里会**缺少 `libSkiaSharp.so`**
   （构建不报错，运行时崩溃）。`~/.nuget/NuGet/NuGet.Config` 里用 `packageSourceMapping`
   把 `SkiaSharp.NativeAssets.Linux` / `HarfBuzzSharp.NativeAssets.Linux` /
   `Microsoft.*.Runtime.linux-loongarch64` 固定到 loongnix 源（见下）。
3. **文件选择器不再无条件禁用 GTK**：本机 Avalonia 11.3 走 xdg-desktop-portal（DBus，
   KDE 的 Qt 对话框），**根本不加载 GTK**（实测 `/proc/<pid>/maps` 里没有 libgtk）。
   启动器改为「有 portal 就用原生对话框；没有 portal 或显式 `SOURCEGIT_DISABLE_GTK=1`
   时才禁用 GTK 走托管选择器」。ABI1 时代的 FreeType 符号抢占崩溃条件仍然存在
   （app-compat 里还是 FreeType 2.11.1），只是默认不触发。
4. **Git 不再需要自装/改 PATH**：系统 Git 2.47.2 已满足 `%(worktreepath)` 所需的 2.31，
   启动器只保留版本自检提示，删掉了 `~/.local/bin/git` 与 PATH 前置逻辑。
5. **deb 依赖改为本机可满足的包名**：`libicu76 | libicu72 | libicu67`、
   `libssl3t64 | libssl3 | libssl1.1`、`libglib2.0-0t64 | libglib2.0-0`，
   并补上 `libxi6/libxext6/libxrender1/libgl1`；版本号默认从 `VERSION` 文件读取。

## 目录内容

| 文件 | 说明 |
| --- | --- |
| `README.md` | 本文件 |
| `setup-dotnet-sdk-loongarch64.sh` | 组装 loongarch64 版 .NET 10 SDK（ABI2 版：muxer 取自 NuGet、自动探测 ABI） |
| `build-loongarch64.sh` | 一键重新构建脚本 |
| `pack-deb-loongarch64.sh` | 打成 `Architecture: loong64` 的 deb，并生成安装版启动包装脚本与桌面项 |
| `sourcegit-launch.sh` | 启动包装脚本：portal/GTK 选择器逻辑 + Git 版本自检 |
| `CRASH-ANALYSIS-freetype-gtk.md` | 「打开文件夹」崩溃分析（ABI1 时代的根因报告，结论对 app-compat 环境仍成立） |
| `sessions/` | 开发会话纪要（ABI1 四篇 + ABI2 一篇） |

## 构建产物（仓库根目录 `out/`，不入 git）

| 文件 | 大小 | 说明 |
| --- | --- | --- |
| `out/sourcegit_2026.24-1_loong64.deb` | 31 MB | Debian 包，`dpkg -i` 安装到 `/opt/sourcegit` |
| `out/sourcegit-2026.24-linux-loongarch64.tar.gz` | 45 MB | 自包含运行目录压缩包，解压即用；由下面「复现步骤」里的 `tar` 命令手工生成（脚本不含此步） |
| `out/linux-loongarch64/` | 126 MB | `dotnet publish` 原始输出（自包含，含 .NET 10 运行时） |

启动方式：

```sh
out/linux-loongarch64/SourceGit            # 直接运行
bash build/loongarch64/sourcegit-launch.sh # 带选择器/Git 自检的包装脚本（推荐）
# 安装版：
sudo dpkg -i out/sourcegit_2026.24-1_loong64.deb && sourcegit
```

## 桌面快捷方式 / 菜单项（用户级，已在本机创建）

| 路径 | 作用 |
| --- | --- |
| `~/.local/bin/sourcegit` | **ASCII 路径**启动入口：优先 deb 的 `/opt/sourcegit/sourcegit-launch.sh`，否则仓库的 `build/loongarch64/sourcegit-launch.sh`，最后兜底 `out/linux-loongarch64/SourceGit` |
| `~/.local/share/applications/sourcegit.desktop` | 应用菜单项（`Exec=/home/b6000/.local/bin/sourcegit %u`，`StartupWMClass=SourceGit`） |
| `~/.local/share/icons/sourcegit.png` | 图标（复制自 `build/resources/_common/icons/sourcegit.png`） |
| `~/桌面/SourceGit.desktop` | 桌面图标（软链接到上面的菜单项，KDE Plasma 6 的桌面目录即 `~/桌面`） |

为什么中间要夹一个 `~/.local/bin/sourcegit`：仓库路径含中文（`~/文档/...`），
桌面项与自启动（PATH/环境很干净）直接写中文路径容易解析失败，
所以 `.desktop` 一律指向纯 ASCII 的包装脚本，真实路径只在脚本里出现。

> `.desktop` 里的 `Exec=` / `TryExec=` 一律写**绝对路径**（如
> `/home/b6000/.local/bin/sourcegit`）：桌面项规范不展开 `~`，部分实现
> （如某些 KDE 版本）会好心替你展开，但不可依赖。

开机自启（可选，未默认创建）：

```sh
mkdir -p ~/.config/autostart
cp ~/.local/share/applications/sourcegit.desktop ~/.config/autostart/
```

> 刚在桌面放上图标后如果没立刻出现：在桌面按 F5 / 右键「刷新」，
> 或按 `Meta+D` 显示一次桌面即可（实测 Plasma 6.3 会立即把新条目登记进
> `plasma-org.kde.plasma.desktop-appletsrc` 并为它分配网格位置）。

## 复现步骤

```sh
bash build/loongarch64/setup-dotnet-sdk-loongarch64.sh   # 组装 ~/.dotnet10（约 630 MB）
bash build/loongarch64/build-loongarch64.sh              # 发布到 out/linux-loongarch64
bash build/loongarch64/pack-deb-loongarch64.sh           # 打包 out/sourcegit_2026.24-1_loong64.deb
# 可选：再打一个免安装的压缩包（脚本不含此步，手工执行）
tar -C out -czf out/sourcegit-2026.24-linux-loongarch64.tar.gz linux-loongarch64
```

脚本会用 `WORK` 缓存下载物（默认 `~/.cache/sourcegit-abi2/work`），重复执行不会重新下载。

## NuGet 配置（构建前必须）

`~/.nuget/NuGet/NuGet.Config`：

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />
    <!-- Loongnix 源提供 linux-loongarch64 运行时与 SkiaSharp/HarfBuzz 原生库；
         service index 指向 http 端点，必须 allowInsecureConnections。 -->
    <add key="loongnix" value="https://nuget.loongnix.cn/v3/index.json"
         protocolVersion="3" allowInsecureConnections="true" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="loongnix">
      <package pattern="SkiaSharp.NativeAssets.Linux" />
      <package pattern="HarfBuzzSharp.NativeAssets.Linux" />
      <package pattern="Microsoft.NETCore.App.Runtime.linux-loongarch64" />
      <package pattern="Microsoft.AspNetCore.App.Runtime.linux-loongarch64" />
      <package pattern="Microsoft.NETCore.App.Host.linux-loongarch64" />
      <package pattern="Microsoft.NETCore.App.Crossgen2.linux-loongarch64" />
    </packageSource>
    <packageSource key="nuget.org">
      <package pattern="*" />
    </packageSource>
  </packageSourceMapping>
</configuration>
```

> 子模块 `depends/AvaloniaEdit/NuGet.config` 会 `<clear/>` 掉包源，所以首次构建
> 会出现 `NU1101: 找不到包 Microsoft.NETCore.App.Runtime.linux-loongarch64`。
> 这是**预期现象**：先单独 `dotnet restore src/SourceGit.csproj` 一次（把 loongarch64 运行时
> 灌进全局包缓存 `~/.nuget/packages`），再重跑 `build-loongarch64.sh` 即可通过。

## 关键说明：为什么需要自己拼 SDK

上游微软**从未发布 linux-loongarch64 的 .NET SDK**（8/9/10 均只有 x64/arm64/… 的 SDK 包，
而 loongarch64 只有运行时）。本机是 Loongnix（龙芯发行版），官方提供了
`Microsoft.NETCore.App.Runtime/Host.linux-loongarch64` 等 NuGet 包，因此采用如下组合：

1. 取上游 `dotnet-sdk-10.0.403-linux-x64.tar.gz` 的**托管载荷**（`sdk/`、`packs/`、`templates/` 等）；
2. 用 Loongnix NuGet 源（`https://nuget.loongnix.cn/v3/index.json`）的
   `microsoft.netcore.app.runtime.linux-loongarch64` / `...host...` 10.0.14 替换
   **muxer、hostfxr、shared framework、apphost 模板**；
3. SDK 内 **165 个 x64 平台的 R2R 复合镜像程序集**的 PE 机器标记为 `0xfd1d`，
   loongarch64 CLR 会拒绝加载（`BadImageFormatException`），
   已统一改写为 loongarch64 标记 `0x191d`，CLR 随即回退到 IL 执行；
4. SDK 自带的 4 个 **x86_64 单文件 bundle 启动器**（`Roslyn/bincore/{csc,vbc,VBCSCompiler}` 与 `MSBuild`）
   在龙芯上无法执行，已替换为调用托管 DLL 的 shell 包装器。

## 构建参数与限制

```sh
dotnet publish src/SourceGit.csproj -c Release -r linux-loongarch64 \
  --self-contained true -p:DisableAOT=true -o out/linux-loongarch64
```

* `DisableAOT=true`：上游默认在 Release 下开启 `PublishAot`，但 loongarch64 尚无
  `Microsoft.DotNet.ILCompiler` 10.x（Loongnix 源只有 9.0.2），因此本版本为 **JIT 自包含**。
  如需 AOT，可先用 `Microsoft.NETCore.App.Crossgen2.linux-loongarch64` 10.0.14 做 ReadyToRun 预编译。
* SkiaSharp 2.88.9 / HarfBuzzSharp 8.3.1.1 的 loongarch64 原生库由 Loongnix NuGet 源提供，
  发布产物中 `libSkiaSharp.so`、`libHarfBuzzSharp.so` 均为 LoongArch-64 ELF（e_flags `0x3`，ABI1）。
* 运行时依赖本机 **app-compat** 兼容层提供的 libicu67 / libssl1.1 / fontconfig / freetype / X11，
  以及 ABI2 系统的一批 X11 库（deb 的 `Depends` 已按本机包名列出）。

## 本机验证记录（2026-11-11）

| 项目 | 结果 |
| --- | --- |
| SDK 组装 | `dotnet --info` → SDK 10.0.403 / Host 10.0.14 / loongarch64 正常；R2R 改写 165 个 |
| 构建 | `dotnet publish` 成功，`out/linux-loongarch64` 126 MB，`SourceGit` 为 LoongArch ELF |
| 启动 | `xwininfo` 可见窗口 `Repositories - Default`，1280×720；日志仅一条无害的 Fontconfig 警告 |
| 文件选择器 | 按 Ctrl+L → Tab → Space：弹出 xdg-desktop-portal（KDE）对话框，进程存活；Esc 关闭；`/proc/<pid>/maps` 无 libgtk |
| 依赖清单 | `dpkg-deb -I` 正常；`apt-get -s install ./out/*.deb` 无未满足依赖 |
| 安装包冒烟 | `dpkg-deb -x` 解包到 `/tmp` 后运行 `sourcegit-launch.sh`，窗口正常、无崩溃 |

## 本次构建对环境的改动

* 新增 `~/.dotnet10/`（自建 loongarch64 版 .NET 10 SDK，约 630 MB）
* 新增 `~/.cache/sourcegit-abi2/work/`（SDK 载荷与 nupkg 下载缓存，可删）
* `~/.nuget/NuGet/NuGet.Config`：nuget.org + loongnix（`allowInsecureConnections`）+ 源映射
* 仓库内：`depends/AvaloniaEdit` 子模块已 checkout 到 `ddf00a91`；
  `out/` 已在 `.gitignore` 中；未改动上游任何源码
* 未安装 deb（需要时执行 `sudo dpkg -i out/sourcegit_2026.24-1_loong64.deb`）
* 已创建用户级桌面快捷方式：`~/.local/bin/sourcegit`、
  `~/.local/share/applications/sourcegit.desktop`、`~/.local/share/icons/sourcegit.png`、
  `~/桌面/SourceGit.desktop`（未创建自启动项）

## 已知限制 / 后续建议

* 运行时是 **ABI1 构建 + app-compat**：能跑，但等于停留在旧 glibc 2.28 用户态里；
  若将来 Loongnix 移除 `/usr/local/app-compat` 或 `/lib64/ld.so.1` 兼容链接，就需要
  用 ABI2 工具链自行编译 dotnet/runtime（目前上游没有 loongarch64 ABI2 的官方二进制）。
* `R2R 机器标记改写`属 hack（依赖 CLR 回退 IL 执行），升级 SDK 需重做；
  165 这个数字会随 SDK 版本变化，脚本会自动统计。
* 非 AOT：启动与首次 JIT 略慢，可用 Crossgen2 10.0.14 预编译改善。
* deb 已做依赖模拟与解包冒烟，**尚未真正 `dpkg -i` 安装**（会写 `/opt` 与 `/usr`）。
* `git describe` 在无 tag 的克隆上会打印「致命错误：没有发现名称」，属无害提示
  （`FriendlyVersion` 取不到而已），不影响构建。
