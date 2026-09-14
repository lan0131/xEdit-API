# xEdit API 客户端与冒烟测试

针对 `Core\wbApiServer.pas` 提供的本地 HTTP/JSON API（读 + 写：`status` / `plugins` / `records` / `tree` / `set` / `patch`；**不含保存**——保存请在 xEdit 界面操作）。

## 启动

```bat
:: 1) 把 SSEEdit.exe 放到 Skyrim SE 的 Data 目录（或用 -SSE 参数）
SSEEdit.exe -SSE -api:7000

:: 2) 可选：要求 token（除 GET /api/status 外都要带）
SSEEdit.exe -SSE -api:7000 -apitoken:mysecret

:: 3) 手动照常选择/加载插件；加载完成后 API 即就绪
```

## 客户端用法（零第三方依赖）

```bash
python xedit_api_client.py status
python xedit_api_client.py plugins
python xedit_api_client.py plugin --file Skyrim.esm
python xedit_api_client.py records --file "MyMod.esp" --signature ARMO --names
python xedit_api_client.py records --file "MyMod.esp" --editorID armor --offset 0 --limit 50
python xedit_api_client.py record --record 030008D2                  # 全加载顺序解析 + 覆盖链
python xedit_api_client.py record --record 030008D2 --file MyMod.esp # 限定在某插件内

:: 写操作（全部仅改内存；API 没有保存能力，改完请在 xEdit 界面里保存）
python xedit_api_client.py tree --file "MyMod.esp" --record 030008D2 --depth 4
python xedit_api_client.py set  --file "MyMod.esp" --record 030008D2 --values-file values.json
python xedit_api_client.py patch --patch-file patch.json  # {"fileName":..,"records":[..]}
```

带 token 时给每个子命令加 `--token mysecret`。

## 策略/回归验证脚本

`verify_api.py` 用来在编译出新 exe 后确认"API 无保存能力"这一策略真的生效，并顺带冒烟：

```powershell
python verify_api.py                                   # 默认端口 7000
python verify_api.py --port 7000 --token mysecret
python verify_api.py --write-test                      # 额外做一次"改字段→读回→改回"的往返（仅内存，净变化为零）
python verify_api.py --patch-test --data-dir "F:\Skyrim SCSIM\Game\Data"   # 验证 /api/patch 的 autoSave 已失效
```

检查项：

| 检查 | 期望 |
|---|---|
| `GET /api` | 索引里**没有** save 端点，batch op 列表**没有** `save`，且带 `savePolicy` 字段 |
| `POST /api/plugins/{file}/save` | 404 `not_found`（端点已删除）；若返回 200 说明跑的是**旧 exe** |
| `POST /api/batch` 且 `op="save"` | HTTP 200 但 `ok:false`，错误信息说明"保存不可用，请到 GUI 保存" |
| `api-client` 源码 | 不再有 `save` 子命令 |
| 读链路 | plugins / plugin / records / tree / find 均正常（证明 exe 本身健康） |
| `--write-test` | 改 `FULL - Name` → 读回确认变化 → 改回原值（净变化为零，不落盘） |
| `--patch-test` | `/api/patch` 带 `autoSave:true` 后**磁盘上没有新文件**（需 `--data-dir`） |
| `--patch-test`（同名已存在） | 返回 409 `file_exists` 且不阻塞；旧 build 会弹模态框并冻住 API，脚本 20s 超时后报 FAIL |

退出码 0 = 全部通过；有 FAIL 时脚本会提示"运行中的 exe 与源码不一致，请重新编译并替换 exe"。

> `--patch-test` 会在当前会话里新建一个**临时内存插件**（`zz_api_policy_probe_*.esp`）：之后**不要在 GUI 里保存**，退出不保存它就会消失。另外 `/api/patch` 在目标文件名已存在时会弹模态对话框卡住 API，所以脚本用随机名并会先检查磁盘。

## 直接 curl

```bash
curl -s http://127.0.0.1:7000/api/status
curl -s http://127.0.0.1:7000/api/plugins
curl -s http://127.0.0.1:7000/api/plugins/Skyrim.esm
curl -s "http://127.0.0.1:7000/api/plugins/MyMod.esp/records?signature=ARMO&names=1&limit=20"
curl -s http://127.0.0.1:7000/api/records/030008D2
curl -s -H "Authorization: Bearer mysecret" http://127.0.0.1:7000/api/plugins
```

## 响应形态

- 成功：`{"ok":true, ...}`
- 失败：`{"ok":false,"error":{"code":"...","message":"..."}}`
- FormID 一律 8 位大写十六进制（loadOrderFormID），如 `030008D2`。

## 已知限制

- 记录列表在未指定 `signature` 时会遍历该插件全部顶层组，大文件（如
  Skyrim.esm）首次请求可能较慢；强烈建议配合 `signature=` 过滤 + 分页。
- `editorID` 为不区分大小写的子串匹配。
- 长耗时查询会短暂占用 xEdit 主线程（与 GUI 里做同样操作的行为一致）。
- `/api/plugins/{file}/records/{formid}` 用 loadOrderFormID（8 hex）查该插件内实例。
- 客户端目前只覆盖上述子命令（**没有 save**）；`/api`、`/api/find`、`copy-elements`、`merge-effects`、
  `addmasters`、`/api/batch` 请直接 curl（见仓库 `README.md` 的端点表）。
- **保存只能由用户在 xEdit 界面完成**：API 既没有 `/save` 端点，batch 的 `save` op 也会被拒绝；
  所有修改仅存在于内存，不保存关闭即丢弃。
