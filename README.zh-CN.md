# xEdit-API（中文说明）

基于 **[TES5Edit/TES5Edit](https://github.com/TES5Edit/TES5Edit)**（ElminsterAU 的 xEdit 代码库）的二次开发分支：为 xEdit（主要面向 **SSEEdit / 上古卷轴5：天际特别版**）内置一个**进程内 HTTP/JSON API**，并提供一套**通用“原子能力”层**——外部工具与 AI agent 通过**组合少量通用原语**即可完成几乎任意 patch/编辑需求，**无需针对每个新需求修改 xEdit 源码**。

**已验证环境**：Windows + **Delphi 13 Community Edition（RAD Studio 37.0）**，工程配置 `LiteDebug / Win64`，基线 `dev-4.1.6`。

> English version: **[README.md](README.md)**

---

## 一、亮点

- xEdit 进程内 localhost HTTP/1.1+JSON 服务（`-api` 开关）。
- 全部操作在 xEdit **主线程任务泵**中执行，结果与在 GUI 里操作一致。
- **读**：插件/加载顺序/记录/覆盖链/元素树（含原始值）。
- **写**：改字段值、跨记录复制元素、Actor Effects 列表合并、列表项增删、master 维护、建补丁插件、落盘保存；以及 **`POST /api/batch`** 把这些原语编排成“近似原子、可 dry-run”的工作流。
- **自发现**：`GET /api` 返回全部端点索引（agent 可直接探测）。

| 新增代码 | 作用 |
|---|---|
| `Core/wbApiServer.pas` | 整个服务端：socket、主线程泵、端点、通用路径解析器、batch 引擎 |
| `xEdit.dpr` / `xEdit\xeInit.pas` / `xEdit\xeMainForm.pas` | 薄接线 + GUI 回调（新建文件/保存全部） |
| `api-client/xedit_api_client.py` | 零依赖 Python 客户端 |
| `Tools/delphi13-compat/` | Delphi 13 构建补丁（submodule 更新后重放） |
| `API_SERVER_DESIGN.md` / `DEV_SETUP_M0.md` | 中文设计/构建文档 |

---

## 二、构建与运行

1. 安装 **Delphi 13 CE**（社区版需在 IDE 内编译）。
2. `git submodule update --init --recursive`
3. `Tools\delphi13-compat\apply-patches.cmd`
4. Delphi 打开 `xEdit.dproj` → **LiteDebug / Win64** → `Project > Build`。（打开时的 “Error Reading Form: frmMain … VirtualEditTree” 属预期，点 **Cancel**，勿在设计器保存。）
5. 运行：

```bat
copy Build\xEdit.exe Build\SSEEdit.exe
SSEEdit.exe -SSE -api:7000            :: 可选：-apitoken:mysecret
```

GUI 加载插件完成后 API 就绪（`pluginsLoaded: true`）。

---

## 三、API 参考

约定：
- 基址 `http://127.0.0.1:7000`。
- 成功 `{"ok":true,...}`；失败 `{"ok":false,"error":{"code","message"}}`。
- FormID 一律 8 位十六进制加载顺序 FormID（如 `030008D2`）。
- 启用 `-apitoken` 后除 `/api/status` 外都要带 `Authorization: Bearer <token>`。
- **元素路径**：显示名段用 `\` 连接，数字段表示列表下标（`Actor Effects\0`、`Keywords\KWDA - Keywords\0`、`DATA - DATA\Body Biped Object`）。

| 方法与路径 | 说明 |
|---|---|
| `GET /api` | 端点索引（agent 自发现） |
| `GET /api/status` | 应用/游戏模式、`pluginsLoaded`、端口 |
| `GET /api/plugins` / `.../{fileName}` | 加载顺序插件列表 / 单插件（ESM/ESL 标志、master 列表） |
| `GET /api/plugins/{file}/records?signature&editorID&offset&limit&names` | 记录分页列表 |
| `GET /api/plugins/{file}/records/{formID}` | 记录元数据 + 完整覆盖链 |
| `GET /api/records/{formID}` | 跨加载顺序解析记录 + 覆盖链 |
| `GET /api/plugins/{file}/records/{formID}/tree?depth` | 元素树 JSON（`name/path/value/children`，含原始值） |
| `POST .../records/{formID}/values` | 批量改字段：`{"values":{"FULL - Name":"..."}}` |
| `POST .../records/{formID}/copy-elements` | 在记录间复制顶层元素或**任意路径** |
| `POST .../records/{formID}/merge-effects` | 合并 Actor Effects（覆盖组 + 追加额外项） |
| `POST .../plugins/{file}/addmasters` | 按名补 master |
| `POST .../plugins/{file}/save` | 保存 dirty 插件（GUI Save 路径，保存全部 dirty） |
| `POST /api/patch` | 建补丁插件（`{"fileName","isLight","records":[...]}`） |
| `GET /api/find?editorID&signature&file&exact&limit` | 跨插件按 EDID 查找（exact 优先用 EDID 索引，缺失时回退为按分组扫描；响应含 `edidIndexEnabled`） |
| `POST /api/batch` | 通用原语编排器（见下） |

### `POST /api/batch` —— 通用原子操作编排

请求：`{"strict": bool, "ops":[{"op":"...", ...}]}`。op 依序在主线程执行，逐条返回结果。**不含 `save` op 就绝不落盘**——可作为内存 dry-run，退出不保存即丢弃。

```json
{ "strict": false,
  "ops": [
    { "op": "set", "file": "MyMod.esp", "formID": "010008D2",
      "values": { "FULL - Name": "New name", "DATA - DATA\\Base Carry Weight": "400" } },
    { "op": "copy", "file": "MyMod.esp", "formID": "010008D2",
      "source": { "file": "BaseMod.esm", "formID": "000008D2" }, "path": "DESC - Description" },
    { "op": "add-item", "file": "MyMod.esp", "formID": "010008D2", "path": "Actor Effects" },
    { "op": "remove-item", "file": "MyMod.esp", "formID": "010008D2", "path": "Actor Effects\\2" },
    { "op": "masters", "file": "MyMod.esp", "add": ["BaseMod.esm"], "sort": true },
    { "op": "save" }
  ] }
```

支持 op：`set`、`copy`、`add-item`、`remove-item`、`create-record`、`masters`、`save`。路径段支持名称或数字下标；`copy` 在目标缺失时会在父容器下自动补建可选子记录；`create-record` 把源记录克隆为**全新记录**（新 FormID，可选 `editorID` 与 `values`），用于“生成内容”而非仅覆盖。

### 客户端示例（零依赖）

```powershell
python api-client\xedit_api_client.py status
python api-client\xedit_api_client.py plugins
python api-client\xedit_api_client.py records --file "MyMod.esp" --signature RACE --names --limit 20
python api-client\xedit_api_client.py tree --file "MyMod.esp" --record 010008D2 --depth 4
python api-client\xedit_api_client.py set --file "MyMod.esp" --record 010008D2 --values-file values.json
python api-client\xedit_api_client.py save --file "MyMod.esp"
python api-client\xedit_api_client.py patch --patch-file patch.json
```

---

## 四、已知限制 / 规划

- `save` = 保存全部 dirty（对齐 GUI Save）；单文件保存报告在规划中。
- 修改在保存前仅内存态；不保存关闭即丢弃。
- 超大数据记录深 `tree` 较慢——尽量用 `signature` 过滤或限制 `depth`。
- batch `copy` 引用字段前需先通过 `masters` op 添加对应插件为 master（否则引用会被置空；先加 master 再复制）。
- 规划：单文件保存报告、tree 紧凑模式、undo/快照。

---

## 五、基于本 fork 开发

```bat
git remote rename origin upstream
git remote add origin git@github.com:<你的账号>/xEdit-API.git
git switch -c dev-4.1.6-api
git push -u origin dev-4.1.6-api
```

同步上游：`git fetch upstream && git merge upstream/dev-4.1.6`，随后 `git submodule update --init --recursive` 并重跑 `Tools\delphi13-compat\apply-patches.cmd`。

代码指引：
- 服务端全部在 `Core/wbApiServer.pas`：`HandleRequest` 加路由、handler 在主线程跑、用 `RespondJson` 应答。
- 依赖 GUI 的动作（新建文件/保存全部）走 `xeMainForm.WMUserLoaderDone` 注册的回调。
- 尽量不动 `wbInterface.pas` / `wbImplementation.pas`，保持与上游易合并。

致谢与许可：上游 xEdit 由 ElminsterAU 及贡献者维护（[仓库](https://github.com/TES5Edit/TES5Edit)，MPL-2.0）。本分支保留 MPL-2.0 许可与文件头。
