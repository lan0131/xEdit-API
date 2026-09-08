# xEdit API 客户端与冒烟测试

针对 `Core\wbApiServer.pas` 提供的本地 HTTP/JSON API（M1 + M2，只读）。

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
```

带 token 时给每个子命令加 `--token mysecret`。

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

## 已知限制（M2）

- 记录列表在未指定 `signature` 时会遍历该插件全部顶层组，大文件（如
  Skyrim.esm）首次请求可能较慢；强烈建议配合 `signature=` 过滤 + 分页。
- `editorID` 为不区分大小写的子串匹配。
- 长耗时查询会短暂占用 xEdit 主线程（与 GUI 里做同样操作的行为一致）。
- `/api/plugins/{file}/records/{formid}` 用 loadOrderFormID（8 hex）查该插件内实例。
