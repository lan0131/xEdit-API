# SSEEdit 进程内外部 API —— 二次开发设计文档

> 目标仓库：`TES5Edit/TES5Edit`（xEdit 代码库），当前克隆分支 `dev-4.1.6`（HEAD `9fb0168`，2026-09-06）。
> 目标形态：SSEEdit.exe（`-SSE` 模式 / 重命名 exe 均可）。
> 状态：v0 设计稿，待用户确认选型后进入编码。

---

## 1. 需求

运行修改后的 SSEEdit（带插件加载完成后），通过 API 让**其它程序**可以：

1. 读取模组列表 / 加载顺序 / 插件类型（ESM/ESP/ESL/Medium）与**master 依赖**（含 Full/Light/Medium master 分组）。
2. 读取**记录**及其**覆盖链**（override chain）、获胜覆盖（winning override）、记录所属文件、被谁引用等。
3. 通过 API **创建 patch 插件**、**修改记录字段**、保存插件（复用 xEdit 的保存/备份机制）。

参考场景：Python / Node / C# 脚本在 SSEEdit 进程外做批量分析或生成兼容补丁，不需要再让用户手动操作 xEdit GUI。

---

## 2. 代码库现状勘察结论（已核对源码）

### 2.1 程序入口与启动链

- `xEdit.dpr`（仓库根）：`Application.CreateForm(TfrmMain, frmMain); Application.Run;`
  之前所有初始化都发生在 `xeDoInit`（`xEdit\xeInit.pas`，1660 行）里。
- 游戏模式 / 工具模式判定在 `xeInit.pas` 的 `DetectAppMode`（行 625~706）：
  - 模式表：`GameModes = [... 'sse', ...]`、`ToolModes = [... 'edit', 'script', ...]`；
  - 通过命令行参数、exe 文件名（含 `sse`）或弹窗选择决定；**`wbGameMode`、`wbToolMode`、`wbToolSource` 为全局判定结果**。
- `-script:<file>`（或直接传 .pas 文件）→ 进入 `tmScript` 工具模式并执行脚本（`xeInit.pas` 行 715~733 `CheckForcedMode`）。
- `-autoload` / `-autoexit` 开关在 `xeInit.pas` 行 1224~1230 处理（仅 `tmEdit`/`tmScript` 时生效）。
- 新命令行开关都应仿照 `xeInit._DoInit` 里的写法：`FindCmdLineSwitch(...)` / `wbFindCmdLineParam(...)`（工具在 `Core\wbCommandLine.pas`）。

### 2.2 代码组织（哪些文件是大头）

| 文件 | 内容 |
|---|---|
| `Core\wbInterface.pas`（834 KB） | 全部核心接口与类型声明（IwbElement / IwbFile / IwbMainRecord / TwbFiles 等） |
| `Core\wbImplementation.pas`（823 KB） | 核心实现（`wbNewFile`、元素/记录实现类、文件读写等） |
| `xEdit\xeMainForm.pas`（752 KB） | GUI 壳 TfrmMain（加载、菜单动作、脚本执行、退出保存等） |
| `Core\wbDefinitionsTES5.pas` | TES5/SSE 记录结构定义（记录 -> 子记录 -> 字段） |
| `xEdit\JvI\*` | 新脚本引擎宿主（JvInterpreter），脚本函数 = 内部 Pascal 的薄封装 |
| `Build\Edit Scripts\*.pas` | 官方示例脚本（脚本语言编写的“自动化”，API 的重要参照） |

其它：`Core\wbLoadOrder.pas`（加载顺序）、`Core\wbDefinitionsCommon.pas`（通用定义）。

### 2.3 可直接复用的内部 API（真实符号，出处已核对）

**全局：**
- `wbFiles: TwbFiles`，`TwbFiles = TArray<IwbFile>`（`wbInterface.pas` 行 908），带数组助手 `TwbFilesHelper`（行 924，含排序/查找辅助）。
- 游戏模式 `wbGameMode`、数据目录 `wbDataPath`、插件列表文件名 `wbPluginsFileName`（如 SkyrimSE 的 `Plugins.txt`）。
- 新建插件：`function wbNewFile(const aFileName: string; aLoadOrder: Integer; aIsLight, aIsMedium: Boolean): IwbFile` 及带模板重载（`wbImplementation.pas` 行 56~57、24000 起）。GUI 包装：`frmMain.AddNewFile / AddNewFileName`（`xeMainForm.pas` 行 868~871、1881 起）。

**IwbFile（`wbInterface.pas` 行 1568~1797）— master / 加载顺序 / 记录查询：**
- `FileName`、`FileNameOnDisk`、`LoadOrder`、`LoadOrderFileID`、`FileFileID[aNew]`、`ResolvedLoadOrderFileID[aNew]`
- `Masters[i, aNew]`、`MasterCount[aNew]`、`HasMaster(name)`、`GetMasters(TStrings)`、`AllMasters: TwbFiles`
- `FullMasters` / `MediumMasters` / `LightMasters` 及各自 Count（ESM/ESL/Medium master 分组）
- `AddMasterIfMissing` / `AddMastersIfMissing` / `SortMasters` / `CleanMasters`
- `Records[i]`、`RecordCount`、`RecordByFormID[formID, allowInjected, newMasters]`、`RecordByEditorID[edid]`
- `GroupBySignature[signature]`、`Header`、`IsESM/IsLight/IsMedium/IsUpdate/IsBlueprint`、`NextObjectID`、`NewFormID`、`UnsavedSince`、`FileStates`
- `GetContainedRecordByLoadOrderFormID`（按“加载顺序 FormID”找记录，API 查询主入口之一）

**IwbMainRecord（`wbInterface.pas` 行 1965~2212）— 覆盖链 / 引用：**
- `FormID`（文件内 FormID）、`LoadOrderFormID`、`FixedFormID`、`EditorID`、`FullName`、`Signature`（继承自 IwbRecord / IwbHasSignature）
- `Master`、`IsMaster`、`MasterOrSelf`、`MasterAndLeafs: TDynMainRecords`
- `Overrides[i]`、`OverrideCount`、`WinningOverride`、`IsWinningOverride`、`HighestOverrideOrSelf[maxLoadOrder]`、`HighestOverrideVisibleForFile[file]`、`AllVisibleForFile[file]`
- `ReferencedBy[i]`、`ReferencedByCount`、`References[i]`、`ReferencesCount`、`ExternalReferencesCount`（需已建引用索引）
- `ConflictAll` / `ConflictThis`（冲突状态，读取前需保证冲突已计算/构建 refs）
- `Delete` / `DeleteInto(file)`、`ChangeFormSignature(sig)`、`IsPersistent/IsDeleted/IsInitiallyDisabled/IsCompressed/IsLight...`、`Flags`
- 记录/元素树遍历在 `IwbContainerBase`/`IwbContainer`（行 1406~1560，含 `ElementByPath` 等）；字段读写靠元素接口的 `EditValue/NativeValue/Value`（与脚本 `GetElementEditValues/SetElementEditValues` 语义一致）。

### 2.4 脚本引擎 = 现成的“只差壳”的自动化内核

`Build\Edit Scripts\Skyrim - Book Covers Patch.pas` 几乎演示了 API 需要的全部原语：

```pascal
pluginPatch := AddNewFile;                              // 新建 patch 插件
AddRequiredElementMasters(Book, pluginPatch, False);    // 补 master
BookPatch := wbCopyElementToFile(BookOvr, pluginPatch, False, True); // 复制记录覆盖
ElementAssign(ElementByPath(BookPatch, 'OBND'), LowInteger, ElementByPath(Book, 'OBND'), False);
SetElementEditValues(BookPatch, 'DATA\Type', GetElementEditValues(Book, 'DATA\Type')); // 改字段
SortMasters(pluginPatch); CleanMasters(pluginPatch);    // 清理 master
```

这些脚本函数由 `xEdit\JvI\` 适配层映射到内部 Pascal；**API 层可以直接调用同名的内部函数/或走底层 IwbFile/IwbMainRecord 接口**，二选一在 M3 决定（倾向底层接口 + 必要处复用内部函数）。

### 2.5 没有现成的网络服务；线程模型是核心约束

- 代码库**不含**任何 HTTP/TCP/命名管道服务器（仅 WinINet 用于更新检查 `xeMainForm.pas` 行 1378、`PeekNamedPipe` 工具函数在 `wbHelpers.pas`）。
- 全程 VCL 单线程模型：插件加载有后台任务（带进度），但元素树/记录对象的读取与修改必须发生在 **VCL 主线程**（消息循环里），否则会与 GUI、内部编辑、保存等竞态。
- 已内置 `JsonDataObjects`（submodule，代码多处使用，脚本宿主也导出 JSON 类）→ **JSON 序列化直接用 JsonDataObjects，无需新增依赖**。
- 自带的 `jcl` 提供 `TThread` 相关工具、`vcl-styles-utils` 等，网络层不会用到。

### 2.6 保存插件的内部入口

GUI 里对文件节点保存/退出保存走的是 frmMain 与 wbImplementation 内部的既有路径（如备份到 `wbBackupPath` = `Data\xEdit Edit Backups\`）；确切内部函数名在 M3 编码时定位（重点看 `xeMainForm.pas` 行 20500~20860 的 autoexit/保存逻辑与 `wbWriteOffsetData`/文件写入实现）。设计上 API 的 `save` 动作 = 在**主线程**上调用与 GUI “Save”完全相同的代码路径（包括 `.bak` 备份、`UnsavedSince` 标记等）。

---

## 3. 方案选型（待确认，见文末问题）

### 3.1 传输协议建议：**HTTP/1.1 + JSON，仅监听 127.0.0.1**

理由：
- 任何语言客户端都容易调用（Python `requests`、Node `fetch`、C# `HttpClient`），无需专用 SDK。
- JSON 序列化已有 JsonDataObjects。
- 备选：命名管道（Windows 原生、默认仅本机、无端口占用问题，但跨语言要写一点点胶水）；远程（监听 0.0.0.0）默认关闭。

HTTP 服务实现二选一：
- **(推荐) 自写精简 HTTP 服务器单元**（~300 行，WinSock2 阻塞 socket + 后台线程 accept），零新依赖、可控性强；
- 或使用 Delphi 自带的 Indy `TIdHTTPServer`（随 Delphi CE 提供，但增加编译面与包依赖，xEdit 目前不引用 Indy）。

### 3.2 进程模型与“谁在跑”

xEdit 主窗口正常启动后加载插件，API 服务在“插件加载完成”后启动：
- **A. 常规 GUI 模式 + `-api[:<port>]`**：用户自己开 SSEEdit 选插件加载；GUI 与 API 并存（客户端可见进度/日志）。
- **B. 自动加载模式 `-api[:<port>] -autoload`**：加载全部启用插件（不弹模块选择），GUI 仍在但可最小化；适合“一次性起服务跑批”。
- （两者都要）**C. 退出控制**：`POST /api/shutdown`（受 token 保护）或 `-autoexit` 语义由客户端脚本完成后再关。

启动/关闭接入点：`xeInit._DoInit` 解析 `-api` 参数 → `xeMainForm` 插件加载完成后回调启动服务 → `Application.Run` 退出前（`xEdit.dpr` 的 finally / frmMain.FormClose）停止服务。

### 3.3 线程与任务模型（关键设计）

```
┌─ 后台 Accept 线程 ──────────────┐      ┌─ VCL 主线程（唯一可碰 wb 对象）────┐
│ 监听 127.0.0.1:port             │      │ 消息循环 / Application.OnIdle 轮询  │
│ 收 HTTP 请求 → 解析 → 入队 job   │ ───▶ │ 队列里逐个执行（读/写/建/存）         │
│ 同步等待结果(事件/超时)          │ ◀─── │ 结果序列化成 JSON → 出队           │
│ 写回 HTTP 响应                  │      │ GUI 照常可操作（长任务期间可轮询）    │
└────────────────────────────────┘      └────────────────────────────────────┘
```

- 所有触碰 `wb*` 数据结构的代码都在主线程执行 → 与 GUI/保存天然串行，无锁。
- 长操作（大查询、建 patch、保存）返回 `jobId`，客户端轮询 `GET /api/jobs/{id}`，避免 HTTP 连接长时间占用且不冻结 GUI。
- 查询类短操作（如 `/api/plugins`）可直接同步完成。
- 主线程执行器：优先用 `Application.OnIdle` 钩子（若空闲期不稳定再改用 TTimer/自定义消息 `PostMessage(frmMain.Handle, WM_...)`）。实现时以“不干扰 GUI 消息循环”为验收点。

### 3.4 认证/安全

- 默认只绑 `127.0.0.1`；支持 `-apitoken:<token>`，要求请求头 `Authorization: Bearer <token>`（写入与 shutdown 类方法强制校验；只读方法可配置不校验）。
- 修改/写入受 xEdit 既有保护约束（游戏主文件只读、`wbIKnowWhatImDoing` 门槛等）照常生效。

### 3.5 错误与状态模型

- 统一响应：`{"ok": true, "data": ...}` / `{"ok": false, "error": {"code": "...", "message": "..."}}`。
- 顶层 `GET /api/status` 返回：`appTitle`、`gameMode`（sse）、`pluginsLoaded`、`busy`、`apiVersion`、`uptime`。

---

## 4. API 草案（v0）

所有路径前缀 `/api`。FormID 一律用 `"XXYYYYZZ"` 形式的**加载顺序 FormID**（`LoadOrderFormID`），也接受 `文件内FormID` + `file` 参数的组合。

| 方法/路径 | 说明 |
|---|---|
| `GET /api/status` | 版本、游戏模式、加载状态、busy |
| `GET /api/plugins` | 按加载顺序返回：`index, fileName, isESM, isLight, isMedium, isActive, isUpdate, isBlueprint, masterCount, masters[], fullMasters[], lightMasters[], mediumMasters[], unsaved` |
| `GET /api/plugins/{fileName}/records?signature=&editorID=&page=&pageSize=` | 记录列表（FormID、EDID、FULL、flags、冲突概要） |
| `GET /api/plugins/{fileName}/records/{loadOrderFormID}` | 记录详情 + 元素树 JSON（限深度）；含 `master, isMaster, overrides[{file, formID}], winningOverride, referencedBy[], references[]` |
| `GET /api/records/{loadOrderFormID}` | 跨插件解析：哪个文件、是否已加载、覆盖链摘要（无需先知道文件名） |
| `POST /api/plugins/{fileName}/records/{loadOrderFormID}/values` | 批量改字段：`{"values": {"DATA\\Weight": "12.5", "EDID": "x"}}`（`\` 路径语义与脚本一致） |
| `POST /api/patch` | 创建 patch 插件：`{"fileName": "...", "records": [{"formID": "...", "includeWinning": true}...]}` → 新建文件+复制记录+补 master，返回新文件名 |
| `POST /api/plugins/{fileName}/save` | 保存（走 xEdit 备份路径）；`POST /api/plugins/{fileName}/cleanmasters`、`sortmasters` |
| `GET /api/jobs/{jobId}` | 长任务状态/结果轮询 |
| `POST /api/shutdown` | 安全退出（token 必需） |

查询/遍历参数后续版本可加：按 Group（签名）分页遍历全表、conflicts 报告输出（对齐 GUI 的“冲突过滤器”）。

---

## 5. 代码落点规划（新文件，尽量不碰巨石单元）

| 新文件 | 职责 |
|---|---|
| `Core\wbApiServer.pas` | `-api` 参数、监听线程、HTTP 解析/响应、JSON（JsonDataObjects）、认证、任务队列管理 |
| `Core\wbApiHandlers.pas` | 各端点的处理器：全部在主线程执行；内部调用 IwbFile/IwbMainRecord/wbNewFile 等；记录元素树 JSON 序列化器、`path` 解析（仿脚本 `ElementByPath` 语义） |
| `Core\wbApiMain.pas`（可选） | 主线程任务执行器钩子（OnIdle/消息），生命周期 Start/Stop 供 xeInit/xeMainForm 调用 |

改动既有文件仅限**薄接线**：
- `xEdit.dpr`：uses 增加新单元。
- `xeInit.pas` `_DoInit`：解析 `-api[:port]`、`-apitoken:`、`-apinokeys` 等开关 → 置全局（约 10 行）。
- `xeMainForm.pas`：插件加载完成回调处启动服务；`FormClose`/退出路径停止服务（约 10~15 行，位置在实现时以最小 diff 确定）。

> 不改 `Core\wbInterface.pas` / `wbImplementation.pas` / 记录定义 —— 降低与上游 dev-4.1.6 合并时的冲突面。

---

## 6. 里程碑

| 里程碑 | 内容 | 验收 |
|---|---|---|
| **M0 工具链** | 本机装 Delphi 12 CE + Project Magician + DDevExtensions；submodule 初始化；按 README 步骤；用 `LiteDebug` 配置编译出 SSEEdit.exe（本沙箱无 Delphi，需你在本机完成，我可给逐步清单） | 能跑 SSEEdit |
| **M1 骨架** | `-api[:port]` 参数解析；服务起停；`GET /api/status`、`GET /api/plugins` 返回正确 JSON | curl 可调用 |
| **M2 数据查询** | records / override 链 / master 依赖 / 引用查询端点；分页与超时保护 | 与 GUI 树核对一致 |
| **M3 写入** | 元素树 JSON；改字段（values 批量）；建 patch 插件；保存插件 | 生成文件可在 GUI 打开验证 |
| **M4 完善** | token、jobs 轮询、示例 Python 客户端、文档、整理成对上游可 diff 的补丁集 | 端到端跑通一条业务流 |

---

## 7. 风险与对策

1. **主线程串行化的吞吐**：长任务走 job 轮询；查询限制深度/页大小；必要时为元素树 JSON 加“只输出已定义的知名字段”的紧凑模式。
2. **冲突状态（ConflictAll/This）与 ReferencedBy 需要“构建引用/冲突”**：加载后可能尚未计算 → 在 API 首次查询前按需触发与 GUI 等价的构建（找到确切入口后封装，注意大列表耗时走 job）。
3. **保存入口**：M3 先精确定位 GUI 保存路径（`xeMainForm.pas` 行 20500+ 与 wbImplementation 文件写入），API 只做转发，不自己实现插件写盘。
4. **受保护记录/主文件只读**：沿用 xEdit 既有写保护开关；默认拒绝写游戏主文件和 `wbNeverShow`/受保护元素，与 GUI 行为一致。
5. **与上游合并**：改动面控制在新增单元 + 少量接线，便于随时 rebase dev-4.1.6。

---

## 8. M0 前置：本机构建清单（给你）

1. 安装 [Delphi 12 Community Edition](https://www.embarcadero.com/products/delphi/starter)（免费个人/小团队授权）。
2. 安装 [Project Magician](https://www.uweraabe.de/Blog/downloads/download-info/project-magician/) 与 [DDevExtensions](https://github.com/DelphiPraxis/DDevExtensions/releases)。
3. DDevExtensions 选项：启用 *Disable Package Cache*；Form Designer 勾选 *Do not store the Explicit properties into the DFM*；重启 Delphi。
4. 初始化子模块：`git submodule update --init --recursive`（本沙箱克隆时未拉子模块；详见 README.md 行 91~110 的 JCL/JVCL/VirtualTrees/FileContainer 构建与安装步骤，含把 `External\jcl\jcl\source\include\jcl.template.inc` 复制为 `jcld29win32.inc` 等）。
5. 没有 DevExpress 时：打开 `BethWorkBench.groupproj`，Build Configuration 选 **LiteDebug**。
6. 用 `-SSE` 或把 exe 改名为 `SSEEdit.exe` 运行。

> 详细操作另见 `DEV_SETUP_M0.md`。

---

## 9. M1 已落地代码（本工作区，2026 快照 dev-4.1.6）

> **状态：M0 完成 ✅ —— 已在 Delphi 13 CE (RAD Studio 37.0) 内编译成功**
> `D:\Workspace\dsh\TES5Edit\Build\xEdit.exe`（LiteDebug/Win64，25.6 MB，仅警告无报错）。
> Delphi 13 兼容补丁另存于 `D:\Workspace\dsh\delphi13-compat-patches\`（jcl inc、SynEdit VER370/2 处、JVCL 变量遮蔽），**子模块更新后需重放**。

**新增：**
- `Core\wbApiServer.pas` —— HTTP/1.1+JSON 服务：命令行走线、后台 accept 线程、主线程 TTimer 任务泵、token 校验、`/api/status`、`/api/plugins`、`/api/plugins/{fileName}`。
- `api-client\xedit_api_client.py` —— 零依赖 Python 冒烟客户端。

**接线（薄改动）：**
- `xEdit.dpr`：uses 注册新单元；`finally` 中调 `wbApiServerStop`。
- `xEdit\xeInit.pas`：implementation uses 加 `wbApiServer`；`_DoInit` 末尾调 `wbApiServerConfigureFromCmdLine`（解析 `-api[:port]` / `-apitoken:`）。
- `xEdit\xeMainForm.pas`：implementation uses 加 `wbApiServer`；`WMUserLoaderDone` 中插件加载完成后（`wbLoaderDone := True` 且无 `wbLoaderError`）以 `frmMain.Files` 为数据源启动服务。

**使用（编译后）：**
```bat
SSEEdit.exe -SSE -api:7000            :: 手动加载插件后服务自动就绪
python api-client\xedit_api_client.py --port 7000
```

**M2 待办（M1 验证通过后）：** 记录列表/详情/覆盖链与 master 依赖查询端点 → 记录元素树 JSON → 改字段/建 patch/保存。

---

## 10. M2 已落地代码（本工作区）

在 `Core\wbApiServer.pas` 内扩展（未新增文件、未动 wbInterface/wbImplementation）：

| 端点 | 说明 |
|---|---|
| `GET /api/plugins/{file}/records?signature=&editorID=&offset=&limit=&names=` | 记录分页列表（FormID/loadOrderFormID/signature/editorID/fullName/是否 master/winning/deleted/persistent；`signature` 精确过滤、`editorID` 子串过滤、limit≤500） |
| `GET /api/plugins/{file}/records/{8hexFormID}` | 单文件记录详情 + 覆盖链（master、所有 overrides、winningOverride） |
| `GET /api/records/{8hexFormID}` | 跨全部已加载插件解析：按加载顺序找到实例 → 输出整条覆盖链（即“记录/覆盖链/master 归属”全局查询） |

实现要点（源码出处均已在代码注释中标明）：
- 覆盖链走 master 实例的 `OverrideCount/Overrides[]` + `MasterOrSelf`（`wbImplementation.pas`：链挂在 master 实例的 `mrOverrides` 上）。
- 记录定位走 `IwbFile.ContainedRecordByLoadOrderFormID`（其内部把 load-order FileID 经 master 映射回文件内 FileID）。
- FormID 一律按 **8 位大写十六进制** 输出/接受（= xEdit 的 loadOrderFormID 数值），如 `030008D2`。
- 文件列表排序、拷贝数组（不污染 `frmMain.Files`）、全部在主线程执行。

**M3 待办：** 记录元素树 JSON 序列化 → `PUT/POST values` 改字段 → `POST /api/patch` 创建补丁（wbNewFile + 复制记录 + Sort/CleanMasters）→ `save`（走 xEdit 备份路径，入口待 M3 精确定位后封装）。


