# 崩溃分析：点击「打开文件夹」后应用闪退

> 目标：`/home/m700s/文档/outPs/sourcegit` (SourceGit 2026.24) — loongarch64 / Loongnix 20
> 现象：启动后点击「打开文件夹」（打开本地仓库弹窗里的文件夹按钮 / 欢迎页工具栏的
> 「打开本地仓库」→ 文件夹选择器）→ 进程直接崩溃退出。

---

## 1. 复现

```sh
cd out/linux-loongarch64
./SourceGit                      # 启动
# 欢迎页按 Ctrl+L（= 打开本地仓库）→ Tab（聚焦路径框右侧的文件夹按钮）→ Space
```

结果：

```
(SourceGit:1660): Gtk-WARNING **: drawing failure for widget 'GtkLabel': error occurred in libfreetype
(SourceGit:1660): Gtk-WARNING **: drawing failure for widget 'GtkFileChooserDialog': error occurred in libfreetype
munmap_chunk(): invalid pointer          <-- glibc abort，进程被 SIGABRT 杀掉
```

gdb 抓到的现场（崩溃线程 `GTK3THREAD`）：

```
#0  raise ()
#1  abort ()
#2  ?? () libc.so.6            <- malloc_printerr
#3  ?? () libc.so.6            <- free
#4  ?? () libc.so.6            <- malloc
#5  ?? () libpango-1.0.so.0
#6  pango_layout_set_text () from libpango-1.0.so.0
#7  ?? () libpangocairo-1.0.so.0
#8  ?? () libpango-1.0.so.0
```

即：**GTK 文件夹选择器在给标签做文字排版（pango_layout_set_text）时释放了损坏的堆块，
glibc 直接 abort**。不是 .NET 层的托管异常，所以 `~/.cache/SourceGit/crashes/` 里没有
崩溃日志，也没有 `Native.OS.LogException` 的记录。

---

## 2. 根因：libSkiaSharp 导出的 FreeType 符号抢占了系统 libfreetype

### 2.1 两个 FreeType 同时存在于同一进程，且 ABI 不兼容

| 来源 | 版本 | 作用 |
| --- | --- | --- |
| `libSkiaSharp.so`（SkiaSharp 2.88.9 静态内嵌） | **FreeType 2.13.1 "motley"** | Skia 渲染 Avalonia 界面文字 |
| `/usr/lib/loongarch64-linux-gnu/libfreetype.so.6.16.1` | **FreeType 2.11.1** | fontconfig / pango / GTK3 排版 |

`libSkiaSharp.so` 把内嵌的 FreeType 符号以 **GLOBAL** 可见性导出：

```sh
$ nm -D --defined-only libSkiaSharp.so | grep -c " T FT_"
142
```

而 .NET 宿主用 `RTLD_GLOBAL` 加载它，于是这些符号进入了进程的全局符号表。

### 2.2 抢占是实际发生的（LD_DEBUG 证据）

```
$ LD_DEBUG=bindings ./SourceGit 2>&1 | grep "symbol \`FT_"
binding file /lib/loongarch64-linux-gnu/libfreetype.so.6 [0]
          to .../out/linux-loongarch64/libSkiaSharp.so [0]: normal symbol `FT_Load_Glyph'
binding file /lib/loongarch64-linux-gnu/libfreetype.so.6 [0]
          to .../out/linux-loongarch64/libSkiaSharp.so [0]: normal symbol `FT_Done_Face'
binding file /lib/loongarch64-linux-gnu/libfreetype.so.6 [0]
          to .../out/linux-loongarch64/libSkiaSharp.so [0]: normal symbol `FT_Render_Glyph'
... 共 73 处
```

统计：

```
libfreetype.so.6 -> libSkiaSharp.so : 73    <-- 系统 freetype 的内部调用被抢到 Skia 的 2.13.1
libfreetype.so.6 -> libfreetype.so.6: 19
libSkiaSharp.so  -> libSkiaSharp.so : 16
```

**系统 freetype 2.11.1 自己的内部函数（`FT_Load_Glyph` / `FT_Done_Face` /
`FT_Render_Glyph` …）被解析到了 Skia 的 2.13.1 实现上**，但它操作的数据结构仍然是
2.11.1 的布局 —— 典型的 ABI 错配。

### 2.3 为什么 ABI 不兼容

FreeType 2.12 之后 `FT_Palette` 从 `FT_Color*` 变成了结构体。反向验证：

```sh
$ LD_PRELOAD=/usr/lib/loongarch64-linux-gnu/libfreetype.so.6 ./SourceGit
# SIGSEGV:
#0  ?? () from /usr/lib/loongarch64-linux-gnu/libfreetype.so.6
#1  FT_Palette_Select () from .../libSkiaSharp.so
```

让系统的 2.11.1 赢，Skia 就会拿 2.13 的 `FT_Palette` 去调 2.11 的
`FT_Palette_Select`（后者按数组下标访问）→ 越界 → 段错误。
两个方向都炸，说明这两份 FreeType 不能共存于同一进程。

### 2.4 崩溃链路

```
点击「打开文件夹」
  └─ TopLevel.StorageProvider.OpenFolderPickerAsync()
       └─ Avalonia.X11 → GtkSystemDialog (in-process GTK3 文件夹选择器)
            └─ gtk_file_chooser_dialog_new() → GTK 开始排版标签文字
                 └─ pango_layout_set_text()
                      └─ fontconfig/pango 调用被抢占的 FT_* （实际是 Skia 的 2.13.1）
                           ├─ 渲染失败 → "drawing failure for widget ... libfreetype"
                           └─ 释放损坏的堆块 → free() → munmap_chunk(): invalid pointer → abort()
```

---

## 3. 解决方案

### 方案 A（已验证，推荐）：不加载 GTK，改用 Avalonia 自带的托管选择器

Avalonia 的选择器优先级是（`src/Avalonia.X11/X11Window.cs`）：

```csharp
_storageProvider = new FallbackStorageProvider(new[]
{
    () => _platform.Options.UseDBusFilePicker ? DBusSystemDialog.TryCreateAsync(Handle) : null,
    () => GtkSystemDialog.TryCreate(this),                 // <-- 崩在这里
    () => new ManagedStorageProvider(tl),                   // <-- 纯 Avalonia，安全
});
```

只要让 `dlopen("libgtk-3.so.0")` 失败，第三个（托管）选择器就会被启用：

```sh
mkdir -p no-gtk && printf 'disabled\n' > no-gtk/libgtk-3.so.0
LD_LIBRARY_PATH="$PWD/no-gtk:$LD_LIBRARY_PATH" ./SourceGit
```

已封装为：`build/loongarch64/sourcegit-launch.sh`

验证结果：不再崩溃，点击「打开文件夹」弹出 Avalonia 托管的 **“Select directory”**
窗口，目录树与「打开/取消」按钮均正常。

### 方案 B（更“正统”，需要 root）：改用 XDG Desktop Portal

在 `App.BuildAvaloniaApp()` 中：

```csharp
builder.UsePlatformDetect()
       .With(new X11PlatformOptions { UseDBusFilePicker = true });
```

选择器由 `xdg-desktop-portal` 在**独立进程**里渲染，本进程不再碰 pango/GTK，
从根上避免 FreeType 冲突。但本机目前**没有安装** `xdg-desktop-portal`
（`dpkg -l | grep portal` 为空），需要先装 `xdg-desktop-portal` +
`xdg-desktop-portal-kde`，否则会回落到 GTK 方案、依旧崩溃。

### 方案 C（治本，需要重新构建 SkiaSharp）

让 `libSkiaSharp.so` 不再全局导出 `FT_*`，即：

* 重新编译 Skia 时加 `-fvisibility=hidden` / 版本脚本 `{ local: FT_*; };`，或
* 重新链接时加 `-Wl,-Bsymbolic-functions`；

这样系统 freetype 与 Skia 各自使用自己那份，互不干扰，GTK 也能正常显示文字。
注意：单纯用 `objcopy --localize-symbol` 改 `.dynsym` **无效**（objcopy 只改
`.symtab`，对已 strip 的 `.so` 的动态符号表不生效），而且即使改成 LOCAL，
Skia 自身对 `FT_*` 的 PLT 引用仍会被解析到系统 freetype（因为
`libfreetype.so.6` 是 `libSkiaSharp.so` 的依赖），Skia 反而会崩。

### 方案 D（不推荐）：统一成一份 FreeType

`LD_PRELOAD` 一份 **2.13.1** 的 `libfreetype.so.6`（SONAME 相同即可顶替系统那份），
进程里就只有一份 FreeType。但需要自行编译 FreeType 2.13.1（loongarch64），
且 fontconfig 2.13.1 是按 2.11 ABI 编译的，存在再次踩 `FT_Palette` 的风险。

---

## 4. 影响范围

* 受影响：所有会打开**原生**文件/文件夹选择器的入口
  —— 打开本地仓库、克隆仓库、添加 worktree、偏好设置里的目录选择、
  自定义动作、变更树里的「在文件管理器中打开」等。
* 不受影响：SourceGit 自身界面（Skia 直接用自己内嵌的 FreeType，渲染正常）。
* 与架构无关：任何「系统 FreeType < 2.13 + SkiaSharp 内嵌 2.13.1」的 Linux 发行版
  （Debian 11/12、Ubuntu 20.04/22.04 等）上理论上都会复现；升级系统 freetype
  到 2.13+ 可以从根上消除该冲突。

---

## 5. 复现/验证脚本

见 `/tmp/trigger.sh`（Ctrl+L → Tab → Space 触发选择器）：

| 用例 | 命令 | 结果 |
| --- | --- | --- |
| 基线 | `./SourceGit` | `munmap_chunk(): invalid pointer` 崩溃 |
| 预加载系统 freetype | `LD_PRELOAD=.../libfreetype.so.6 ./SourceGit` | 启动即 SIGSEGV（`FT_Palette_Select`） |
| 隐藏 GTK（方案 A） | `LD_LIBRARY_PATH=./no-gtk ./SourceGit` | **正常**，弹出托管选择器 |
