# M0 —— 本机搭建 xEdit(SSEEdit) 开发环境（必读）

> 适用：Windows 10/11 64 位。目标：从 `D:\Workspace\dsh\TES5Edit` 编译出可运行的 **SSEEdit.exe**。
> 分两步：**A 部分需要你本人操作（约 10–15 分钟，含注册）**；B 部分大部分可由我代劳/指导。

---

## A. 安装 Delphi（必须由你本人完成）

xEdit 是 Delphi/Pascal 写的，官方推荐 **Delphi 12 Community Edition**（免费，个人/小团队）。

1. 打开 https://www.embarcadero.com/products/delphi/starter （或 https://www.embarcadero.com/products/rad-studio/starter ）。
2. 点击 **Download / Register**，用你的邮箱注册 Embarcadero 账号（**这一步必须是本人**，许可绑定账号；我无法替你注册或登录）。
3. 注册后按提示下载 **Delphi 12 CE** 安装器（约 2–4 GB，建议挂代理/夜间下载）。
4. 运行安装器：
   - 勾选组件时至少保留：**Delphi 12 (Win64)**、**VCL**、**Database 组件可全不选**（xEdit 不需要）、**Indy** 可留默认。
   - 安装结束后首次启动 Delphi，用刚注册的账号登录完成**许可激活**（激活一次后即可离线）。
5. 验证：Delphi 里 `Help → About` 显示 Community Edition；能新建一个 VCL 工程并 F9 跑起来即算成功。

> 说明：Delphi 12.0/12.1/12.2 均可。仓库 README 里 “D29 / D290” 字样指 Delphi 29.x = RAD Studio 12.x，版本一致即可。

## B. 环境配套（我已在工作区/仓库准备）

### B1. 初始化 git 子模块（仓库依赖的第三方库，源码在 submodule 里）

在**普通终端**（不要在我这个受限会话里跑，会报 msys 管道错误）执行：

```bat
cd /d D:\Workspace\dsh\TES5Edit
git submodule update --init --recursive
```

完成后 `External\` 下 jcl/jvcl/VirtualTrees/JsonDataObjects/DWScript/SynEdit/FileContainer/imaginglib/libdeflate-pas/lz4-delphi/delphi-detours-library/vcl-styles-utils 应都有内容。

### B2. 安装两个 IDE 增强插件（普通终端，均为免费）

1. **Project Magician**：https://www.uweraabe.de/Blog/downloads/download-info/project-magician/ （下载 zip，按其说明安装 IDE 包）。
2. **DDevExtensions**：https://github.com/DelphiPraxis/DDevExtensions/releases （下载 exe/zip 安装）。

### B3. Delphi IDE 配置（一次性）

按仓库 `README.md` 第 81–114 行（即上面给的第 3~4 点）执行，要点：

- Tools → DDevExtensions Options：
  - Extended IDE Settings：勾选 **Disable Package Cache**；
  - Form Designer：勾选 **Do not store the Explicit properties into the DFM**；重启 Delphi。
- 复制 `External\jcl\jcl\source\include\jcl.template.inc` → 同目录 **`jcld29win32.inc`**（若编 64 位再加 `jcld29win64.inc`）。
- 依次用 Delphi 打开并 **Build All / Install**：
  1. `External\jcl\jcl\packages\JclPackagesD290.groupproj`
  2. `External\jvcl\jvcl\packages\D29 Packages.groupproj`（期间在 Tools→Options→Language→Delphi→Library 加入 `External\jcl\jcl\lib\d29\win32` 和 `External\jcl\jcl\source\include`）
  3. `External\VirtualTrees\Packages\RAD Studio 12\VirtualTreeView.groupproj`（装 VirtualTreesD29.bpl）
  4. `External\FileContainer\FileContainer29.groupproj`（装 FileContainerD29.bpl）

### B4. 编译 SSEEdit

1. 打开仓库根的 `BethWorkBench.groupproj`。
2. 项目配置（Project Manager 下拉）选 **LiteDebug**（没有 DevExpress 时；若你有 DevExpress 商业组件可选 Full Debug）。
3. 右键 xEdit 工程 → **Build**。
4. 产物：xEdit.exe（在仓库某输出目录）。复制一份改名为 **SSEEdit.exe**（或运行时加 `-SSE`），放进你的 Skyrim SE `Data` 目录运行验证。

## C. 验证清单

- [ ] `SSEEdit.exe` 能启动、能加载插件列表
- [ ] 打开一个 esp 能看到记录树
- [ ] 告诉我“M0 完成”，我接着在命令行里驱动编译/验证 API 代码

---

## 常见问题

- **Delphi 下载太慢/断点**：官方下载器支持续传；也可从网络搜寻 CE 12 ISO 镜像链接（需登录态），或分时段下载。
- **License 激活失败**：检查系统时间；用注册邮箱在 https://my.embarcadero.com 确认 license 已下发；Delphi 内 Help→Manage Licenses 手动刷新。
- **LiteDebug 里某些包编译失败**：多半是 B3 的 jcl/jvcl/virtualtree 安装顺序或 `.inc` 复制遗漏，回头逐条核对。
- **运行时缺 DLL/样式**：xEdit 发布包需 `Themes`、`Edit Scripts` 目录等放在 exe 旁（仓库 `Build\` 下），从 `Build\` 复制到 exe 目录。

---

## D. 本机实测结论（Delphi 13 Community Edition = RAD Studio 37.0）

**已达成：`xEdit.exe` 在 Delphi 13 CE (RAD Studio 37.0) IDE 内编译成功（LiteDebug / Win64，产物 25.6 MB，仅警告无报错）。**

1. **Community Edition 禁止命令行编译**。`dcc32.exe` 直接调用或 `msbuild xEdit.dproj` 都会报
   “This version of the product does not support command line compiling.” → **只能在 Delphi IDE 内按 Ctrl+Shift+F9 编译**。
   命令行只能做预处理/检查（子模块、inc 配置、diff 等）。
2. 仓库官方目标是 **Delphi 12 (D29)**；本机装的是 Delphi 13（37.0）。IDE 首次打开 `.dproj` 会提示“由旧版本创建”，选择继续即可。
3. **为 Delphi 13 应用的兼容补丁**（均已本地应用；另存于 `D:\Workspace\dsh\delphi13-compat-patches\`，**子模块更新后需重放**）：
   - jcl：复制 `jcl.template.inc` → `jcld29win32.inc` 与 `jcld29win64.inc`（jcl.inc:440 要求）。
   - SynEdit `Source/SynEdit.inc`：新增 `VER370` 分支（映射 `SYN_COMPILER_29`）。
   - SynEdit `Source/SynHighlighterMulti.pas`：3 处 E2197（cast 实参作 var 形参）改临时变量。
   - JVCL `jvcl/run/JvExExtCtrls.pas`：`SplitterMouseDownFix` 局部变量改名（`Control/Pt/R/Size` → `lControl/lPt/lR/lSize`），
     避免与 `TSplitter.Control`（只读属性）遮蔽。
4. 实测 IDE 内编译路径：
   - 打开 `D:\Workspace\dsh\TES5Edit\xEdit.dproj`（不必打开整个 groupproj）；
   - 右上 Project Manager：Configuration = **LiteDebug**（默认），Platform = **Win64**（x64）；
   - 主菜单 Project → Build（Ctrl+Shift+F9）；
   - 产物：`D:\Workspace\dsh\TES5Edit\Build\xEdit.exe`（改名为 `SSEEdit.exe` 或加 `-SSE` 即 SSEEdit）。
   - 打开工程时的 “Error Reading Form frmMain” 弹窗：点 **Cancel**（设计期缺 VirtualTrees 包所致，不影响编译），
     不要在设计器里保存任何东西。
5. DDevExtensions / Project Magician 对“只编译 xEdit.dproj 单个工程”**不是必需**（.dproj 自带全部 External 单元搜索路径）；
   仅当你想在 IDE 里编译安装 jcl/jvcl/VirtualTrees/FileContainer 的 .bpl 包时才按官方 README 装。

