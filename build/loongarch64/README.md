# SourceGit — loongarch64（龙芯）本机构建

本目录是 SourceGit `2026.24` 在本机架构 **loongarch64 / LoongArch-64（Loongson）** 上的构建脚本、
分析文档与会话纪要。构建产物本身放在仓库根目录的 `out/`（已被 `.gitignore` 忽略，不入库）。

## 目录内容

| 文件 | 说明 |
| --- | --- |
| `README.md` | 本文件：构建方法与限制 |
| `setup-dotnet-sdk-loongarch64.sh` | 准备 loongarch64 版 .NET 10 SDK（见下） |
| `build-loongarch64.sh` | 一键重新构建脚本 |
| `pack-deb-loongarch64.sh` | 把 publish 产物打成 Debian 包（`Architecture: loong64`），同时生成安装版的启动包装脚本与桌面项 |
| `sourcegit-launch.sh` | 启动包装脚本：规避「打开文件夹」崩溃（禁用 GTK，见 `CRASH-ANALYSIS-freetype-gtk.md`），并把 `~/.local/bin` 前置到 PATH（保证用上 Git 2.56.1） |
| `CRASH-ANALYSIS-freetype-gtk.md` | 「打开文件夹」崩溃完整分析报告（根因、证据链、四种修复方案对比） |
| `sessions/` | 本机相关开发会话纪要（2026-11-10 的四场会话，入口见 `sessions/2026-11-10-会话总览.md`） |

## 构建产物（位于仓库根目录的 `out/`，不入 git）

| 文件 | 说明 |
| --- | --- |
| `out/sourcegit_2026.24-1_loong64.deb` | Debian 包（`Architecture: loong64`），由 `pack-deb-loongarch64.sh` 生成，`dpkg -i` 安装到 `/opt/sourcegit` |
| `out/sourcegit-2026.24-linux-loongarch64.tar.gz` | 自包含运行目录的压缩包，解压即用 |
| `out/linux-loongarch64/` | `dotnet publish` 的原始输出（自包含，含 .NET 10 运行时） |

启动方式：

```sh
out/linux-loongarch64/SourceGit              # 直接运行
# 或用规避 GTK 崩溃的包装脚本（推荐，桌面项也是走它）：
build/loongarch64/sourcegit-launch.sh
# 或安装 deb 后（当前**未安装**，装完才有 sourcegit 命令）：
dpkg -i out/sourcegit_2026.24-1_loong64.deb && sourcegit
```

> 2026-11-10 手工打的那个旧 deb 里，`/usr/share/applications/sourcegit.desktop` 写的是
> `Exec=/opt/sourcegit/sourcegit`，而实际二进制名是 `SourceGit`（大写 S）→ **桌面项点了起不来**；
> 且它绕过了启动器，GTK 崩溃规避与 PATH 加固都不生效。
> 现已改由 `pack-deb-loongarch64.sh` 生成：`Exec=/usr/bin/sourcegit %u` →
> `/opt/sourcegit/sourcegit-launch.sh`（包装脚本）→ `/opt/sourcegit/SourceGit`。

## 桌面快捷方式与开机自启

桌面项**不是安装版（deb）带来的**，而是 2026-11-10「开机自启与桌面快捷方式」会话
**手工创建的用户级文件**（deb 至今未安装，`/opt/sourcegit` 不存在，`which sourcegit` 无输出）：

| 路径 | 作用 |
| --- | --- |
| `~/.local/share/applications/sourcegit.desktop` | 应用菜单项 |
| `~/.config/autostart/sourcegit.desktop` | 登录自启项（`X-GNOME-Autostart-enabled=true`） |
| `~/桌面/SourceGit.desktop` | 桌面图标（软链接 → 上面那份 applications 项） |
| `~/.local/share/icons/sourcegit.png` | 图标（复制自 `build/resources/_common/icons/sourcegit.png`） |
| `~/.local/bin/sourcegit-launch.sh` | ASCII 路径包装脚本，被上面三个 `.desktop` 的 `Exec=` 引用 |

调用链（`Exec=` 一律指向纯 ASCII 路径，避开 `文档/outPs/...` 中文路径在桌面环境里的解析风险）：

```
~/.local/bin/sourcegit-launch.sh          # ASCII 包装（转发）
  └─ build/loongarch64/sourcegit-launch.sh   # 真启动器：禁用 GTK + PATH 加固
       └─ out/linux-loongarch64/SourceGit    # 自构建产物（不在 /opt，不属于 deb）
```

所以桌面图标指向的是**仓库里的自构建产物 `out/`**：`out/` 被 `.gitignore` 忽略，
一旦清理或换机器，桌面项会启动失败（启动器会明确报 `SourceGit binary not found`）。

## Git 版本要求

上游代码用 `git branch --format` 的 `%(worktreepath)` 原子（需要 **Git ≥ 2.31**），
而本机系统 Git 是 **2.20.1**（Loongnix 自带），旧版遇到不认识的原子会让整条命令
**静默失败** → 界面「本机分支」显示 0 个。处理方式（**不改上游源码**）：

| 路径 | 版本 |
| --- | --- |
| `~/.local/bin/git` | **2.56.1**（自装，PATH 中优先） |
| `/usr/bin/git` | 2.20.1（系统自带，未动） |

SourceGit 偏好设置里的 **「Git 安装路径」** 指向 `/home/m700s/.local/bin/git`，
持久化在 `~/.config/SourceGit/preference.json` 的 `GitInstallPath` 字段；
启动器还会 `export PATH="$HOME/.local/bin:$PATH"`，双保险避免桌面/自启场景
（PATH 很干净）退回系统旧版。详见
[sessions/2026-11-10-修复本机分支显示0个.md](sessions/2026-11-10-修复本机分支显示0个.md)。

## 已知问题

* deb 尚未实际安装验证（只做了 `dpkg-deb -x` 解包后的启动冒烟测试）：
  `dpkg -i` 需要 root，且会往 `/opt` 与 `/usr/share` 写系统文件。
* deb 的依赖已放宽为 `libicu67 | libicu63 | libicu`、`libssl1.1 | libssl3`，
  但 Loongnix 仓库里实际提供的版本仍需安装前确认。
* 安装版与仓库版会同时存在：deb 装的是 `/opt/sourcegit`，
  桌面图标（用户级）指向的仍是仓库里的 `out/linux-loongarch64/SourceGit`。

## 关键说明：为什么需要自己拼 SDK

上游微软**从未发布 linux-loongarch64 的 .NET SDK**（8/9/10 均只有 x64/arm64/… 的 SDK 包，
而 loongarch64 只有运行时）。本机是 Loongnix（龙芯发行版），官方提供了
`Microsoft.NETCore.App.Runtime/Host.linux-loongarch64` 等 NuGet 包，因此采用如下组合：

1. 取上游 `dotnet-sdk-10.0.403-linux-x64.tar.gz` 的**托管载荷**（`sdk/`、`packs/`、`templates/` 等）；
2. 用 Loongnix NuGet 源（`https://nuget.loongnix.cn/v3/index.json`）的
   `microsoft.netcore.app.runtime.linux-loongarch64` / `...host...` 10.0.14 替换
   **muxer、hostfxr、shared framework、apphost 模板**；
3. SDK 内 165 个 **x64 平台的 R2R 复合镜像程序集**的 PE 机器标记为 `0xfd1d`，
   loongarch64 CLR 会拒绝加载（`BadImageFormatException`），
   已统一改写为 loongarch64 标记 `0x191d`，CLR 随即回退到 IL 执行；
4. SDK 自带的 4 个 **x86_64 单文件 bundle 启动器**（`Roslyn/bincore/{csc,vbc,VBCSCompiler}` 与 `MSBuild`）
   在龙芯上会被 `latx` 模拟器接管并失败，已替换为调用托管 DLL 的 shell 包装器。

## 构建参数与限制

```sh
dotnet publish src/SourceGit.csproj -c Release -r linux-loongarch64 \
  --self-contained true -p:DisableAOT=true -o out/linux-loongarch64
```

* `DisableAOT=true`：上游默认在 Release 下开启 `PublishAot`，但 loongarch64 尚无
  `Microsoft.DotNet.ILCompiler` 10.x（Loongnix 源只有 9.0.2），因此本版本为 **JIT 自包含**。
  如需 AOT，可先用 `Microsoft.NETCore.App.Crossgen2.linux-loongarch64` 做 ReadyToRun 预编译。
* SkiaSharp 2.88.9 与 HarfBuzzSharp 的 loongarch64 原生库由 Loongnix NuGet 源提供，
  已确认 `libSkiaSharp.so`、`libHarfBuzzSharp.so` 均为 LoongArch-64 ELF。
* 运行时依赖系统 `libicu67`、`libssl1.1`、`libfontconfig1`、`libX11` 等（deb 的 `Depends` 已列出）。

## 复现步骤

```sh
bash build/loongarch64/setup-dotnet-sdk-loongarch64.sh   # 生成 ~/.dotnet10（约 630 MB）
bash build/loongarch64/build-loongarch64.sh              # 重新构建到 out/linux-loongarch64
bash build/loongarch64/pack-deb-loongarch64.sh           # 打包成 out/sourcegit_2026.24-1_loong64.deb
```

> deb 打包脚本会一并生成安装版的启动包装脚本（禁 GTK + PATH 加固 + Git 版本自检）
> 与桌面项（`Exec=/usr/bin/sourcegit %u`），两者都写进包内，不再手工维护。

## 本次构建对环境的改动

* 新增 `~/.dotnet10/`（自建 loongarch64 版 .NET 10 SDK）
* `~/.nuget/NuGet/NuGet.Config`：`loongnix.cn` 源加上 `allowInsecureConnections="true"`
  （该源的 service index 返回的是 http 端点，否则 NuGet 报 NU1302）
* 新增 `~/.local/bin/git`（Git 2.56.1），配合 `~/.config/SourceGit/preference.json`
  的 `GitInstallPath` 指向它，绕开系统 Git 2.20.1 的 `%(worktreepath)` 缺失问题
* 新增 `~/.local/bin/sourcegit-launch.sh`、`~/.local/share/applications/sourcegit.desktop`、
  `~/.config/autostart/sourcegit.desktop`、`~/.local/share/icons/sourcegit.png`，
  以及桌面软链接 `~/桌面/SourceGit.desktop`（详见「桌面快捷方式与开机自启」）
* 仓库内：`depends/AvaloniaEdit` 子模块已 checkout（上游未修改任何源码），
  新增未跟踪目录 `out/`（已在 `.gitignore` 中），构建脚本与文档收进 `build/loongarch64/`
