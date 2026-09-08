# xEdit-API（中文说明）

基于 **[TES5Edit/TES5Edit](https://github.com/TES5Edit/TES5Edit)**（ElminsterAU 的 xEdit 代码库）的二次开发分支：为 xEdit（主要面向 **SSEEdit / 上古卷轴5：天际特别版**）内置一个**进程内 HTTP/JSON API**，让外部程序可以：

- 读取已加载的插件列表、加载顺序、ESM/ESL 标志与 **master 依赖**；
- 列出并查看**记录**、其**覆盖链**、获胜覆盖（winning override）与引用关系；
- 把记录的**元素树**导出为 JSON；
- 通过 HTTP **直接修改记录字段、创建 patch 插件、并把插件保存到磁盘**。

**已验证环境**：Windows + **Delphi 13 Community Edition（RAD Studio 37.0）**，工程配置 `LiteDebug / Win64`，基线为上游 `dev-4.1.6`。

> English version: **[README.md](README.md)**

---

## 一、相对上游新增了什么

| 新增/改动 | 作用 |
|---|---|
| `Core/wbApiServer.pas`（约 1700 行） | 本机 HTTP/1.1+JSON 服务：`-api` 开关解析、后台 accept 线程、**VCL 主线程任务泵**、可选 token、全部读写端点 |
| `xEdit.dpr`、`xEdit\xeInit.pas`、`xEdit\xeMainForm.pas` | 薄接线：注册单元、解析 `-api` 参数、插件加载完成后启动服务、注册 GUI 回调（新建文件/保存全部） |
| `api-client/xedit_api_client.py` | 零依赖 Python 客户端：`status / plugins / records / record / tree / set / save / patch` |
| `tools/delphi13-compat/` | 用 **Delphi 13** 编译本仓库所需的兼容补丁（见第三节），子模块更新后可一键重放 |
| `API_SERVER_DESIGN.md`、`DEV_SETUP_M0.md` | 中文设计文档与环境/编译实测记录 |

**一句话架构**：xEdit 的数据结构都绑定在 VCL 主线程上，因此后台 socket 线程只负责接受连接和解析 HTTP；每个请求会变成一个 job，由主线程上的 `TTimer` 泵执行，完成后把结果写回。JSON 生成/解析复用仓库自带的 `JsonDataObjects`。所有记录/文件操作走的是与 GUI、编辑脚本相同的内部 API（例如覆盖链挂在 master 实例上、复制记录用 `element.CopyInto` 自动补 required masters）。

---

## 二、使用方法

### 2.1 运行

```bat
:: 复制一份改名（xEdit 按文件名或 -SSE 参数判定游戏模式）
copy Build\xEdit.exe Build\SSEEdit.exe

:: 启动并开启 API（找不到游戏目录时把 exe 放到游戏 Data 目录再运行）
SSEEdit.exe -SSE -api:7000

:: 可选：启用 token（除 GET /api/status 外每次请求都要带）
SSEEdit.exe -SSE -api:7000 -apitoken:mysecret
```

正常在 GUI 里加载插件；加载完成后 API 即监听在 `http://127.0.0.1:7000`。

### 2.2 快速验证

```powershell
python api-client\xedit_api_client.py status
python api-client\xedit_api_client.py plugins
python api-client\xedit_api_client.py record --record 00013740 --file "SCSI-RaceGlory.esp"
curl -s http://127.0.0.1:7000/api/status
```

---

## 三、从本 fork 全新克隆后如何编译

1. 安装 **Delphi 13 CE**（Community Edition 授权禁止命令行编译，请在 IDE 里 Build）。
2. 拉取子模块：
   ```bat
   git submodule update --init --recursive
   ```
3. 重放 Delphi 13 兼容补丁（上游尚未合并前每次都需要）：
   ```bat
   tools\delphi13-compat\apply-patches.cmd
   ```
   （该脚本把 `jcld29win32/64.inc` 复制进 jcl，并应用 SynEdit、JVCL 的三处 diff；`git submodule update` 之后重跑一次即可。）
4. 用 Delphi 打开 `xEdit.dproj`：Configuration = **LiteDebug**、Platform = **Win64**，菜单 `Project → Build`（Ctrl+Shift+F9）。
   - 打开工程若弹 “Error Reading Form: 'frmMain' … VirtualEditTree”：属预期（未装 VirtualTrees 设计期包），点 **Cancel** 即可，不影响编译；**不要**在设计器里保存。
5. 产物 `Build\xEdit.exe` → 改名 `SSEEdit.exe` 或运行加 `-SSE`。

---

## 四、API 一览

约定：

- 基址 `http://127.0.0.1:7000`（可用 `-api:<端口>` 覆盖）。
- 成功：`{"ok": true, ...}`；失败：`{"ok": false, "error": {"code": "...", "message": "..."}}`。
- FormID 一律用 **8 位十六进制加载顺序 FormID**，如 `030008D2`。
- 鉴权：请求头 `Authorization: Bearer <token>`（仅使用 `-apitoken` 启动时需要；`/api/status` 始终开放）。

| 方法与路径 | 说明 |
|---|---|
| `GET /api/status` | 版本、游戏/工具模式、`pluginsLoaded`、端口 |
| `GET /api/plugins` | 按加载顺序的插件列表：fileName/fileID/ESM/ESL/medium/update 标志、Full/Light/Medium master 列表 |
| `GET /api/plugins/{fileName}` | 单个插件详情 |
| `GET /api/plugins/{fileName}/records?signature=&editorID=&offset=&limit=&names=` | 记录分页列表（limit≤500；signature 精确、editorID 子串匹配） |
| `GET /api/plugins/{fileName}/records/{loadOrderFormID}` | 记录元数据 + 完整覆盖链（master、全部 overrides、winning） |
| `GET /api/records/{loadOrderFormID}` | 跨整个加载顺序解析记录 + 覆盖链 |
| `GET /api/plugins/{fileName}/records/{loadOrderFormID}/tree?depth=N` | 记录元素树 JSON（name/path/value/children；depth 默认 8、上限 20） |
| `POST /api/plugins/{fileName}/records/{loadOrderFormID}/values` | 批量改字段。Body：`{"values": {"FULL - Name": "新名字"}}`——key 用 `tree` 输出的显示名路径 |
| `POST /api/plugins/{fileName}/save` | 落盘：与 GUI **Save** 按钮同一条代码路径（保存所有 dirty 插件，含备份/原子改名） |
| `POST /api/patch` | 创建补丁插件。Body 示例：`{"fileName": "zz_api_patch.esp", "records": [{"formID": "00013740", "file": "SCSI-RaceGlory.esp"}]}` → 新建文件（加入 GUI）→ 逐条以覆盖形式复制记录（自动补 required masters，`element.CopyInto`）→ `SortMasters/CleanMasters`。可选 `"autoSave": true` |

### 端到端示例

```powershell
# 1) 改一条 RACE 的名字
python api-client\xedit_api_client.py set --file "SCSI-RaceGlory.esp" --record 00013740 --values-file api-client\sample-values.json
#    （sample-values.json = {"FULL - Name": "亚龙人-API测试"}；用 --values-file 可避免 shell 引号问题）

# 2) 保存
python api-client\xedit_api_client.py save --file "SCSI-RaceGlory.esp"

# 3) 用两条 RACE 记录建一个补丁插件
python api-client\xedit_api_client.py patch --patch-file api-client\sample-patch.json
# 4) 保存新插件
python api-client\xedit_api_client.py save --file "zz_api_patch.esp"
```

`tree` 输出示例：

```json
{ "ok": true, "plugin": "SCSI-RaceGlory.esp", "loadOrderFormID": "00013740",
  "tree": { "name": "ArgonianRace \"亚龙人\" [RACE:00013740]", "path": "RACE",
            "children": [
              { "name": "EDID - Editor ID", "path": "RACE \\ EDID - Editor ID" },
              { "name": "FULL - Name", "path": "RACE \\ FULL - Name" }
            ] } }
```

---

## 五、已知限制与规划（M4 候选）

- `save` 目前是“保存全部 dirty 插件”（对齐 GUI Save 语义），尚未做单文件精确回报。
- `/api/status` 的 `busy` 会把“正在应答的当前请求”也算进去，语义待修。
- 超大记录（巨型数组/网格）的 `tree` 较慢，计划做紧凑模式。
- 元素路径目前是 xEdit 显示名路径，计划提供短签名别名。
- 线程模型：所有操作都在 xEdit 主线程执行（与在 GUI 里操作一致），长任务会短暂占用界面。

M4 规划：单文件 save 回报、`busy` 修正、tree 紧凑模式、路径别名、`/api/shutdown`。

---

## 六、基于本 fork 继续开发

推荐的远程布局（原始工作区已配好）：

```bat
git remote rename origin upstream                         :: 原版 TES5Edit
git remote add origin git@github.com:<你的账号>/xEdit-API.git
git switch -c dev-4.1.6-api
git push -u origin dev-4.1.6-api
```

之后同步上游：

```bat
git fetch upstream
git merge upstream/dev-4.1.6        :: 或 git rebase upstream/dev-4.1.6
git submodule update --init --recursive
tools\delphi13-compat\apply-patches.cmd
```

代码指引：

- `Core/wbApiServer.pas` 即整个服务端。新增端点 = 在 `TwbApiServer.HandleRequest` 加一条路由 + 写一个在主线程执行的 handler，用 `RespondJson` 应答。
- 需要 GUI 服务的操作（新建插件文件、保存全部）通过回调 `wbApiServerSetAddFileHandler` / `wbApiServerSetSaveAllHandler` 注册（在 `xeMainForm.WMUserLoaderDone` 里），Core 单元不直接依赖 frmMain。
- 尽量别动 `wbInterface.pas` / `wbImplementation.pas` / 记录定义，保持与上游 diff 小、便于合并。

致谢与许可：上游 xEdit 由 ElminsterAU 及贡献者维护（[仓库](https://github.com/TES5Edit/TES5Edit)，MPL-2.0）。本分支保留 MPL-2.0 许可与文件头。
