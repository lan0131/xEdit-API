# xEdit-API

A fork of **[TES5Edit/TES5Edit](https://github.com/TES5Edit/TES5Edit)** (the xEdit codebase by ElminsterAU) that adds an **in-process HTTP/JSON API** — primarily for **SSEEdit (Skyrim SE)** — plus a small **generic "atomic capability" layer**, so external tools and AI agents can read plugin data and perform almost any patch/edit by *composing generic primitives*, without modifying xEdit's source per use case.

**Verified environment:** Windows + **Delphi 13 Community Edition (RAD Studio 37.0)**, `LiteDebug / Win64`, based on upstream `dev-4.1.6`.

> 中文版见 **[README.zh-CN.md](README.zh-CN.md)**.

---

## 1. Highlights

- Localhost HTTP/1.1 + JSON API inside xEdit (`-api` switch).
- Everything runs on the xEdit main thread through a job pump — results equal doing the same action in the GUI.
- **Read**: plugins, load order, records, override chains, element trees (raw values included).
- **Write**: set field values, copy elements between records, merge actor-effect lists, add/remove list items, master maintenance, create patch plugins, save to disk — and a **`POST /api/batch` orchestrator** that composes these into one atomic-ish, dry-run-able workflow.
- **Self discovery**: `GET /api` returns the full endpoint index for agents.

| New code | Purpose |
|---|---|
| `Core/wbApiServer.pas` | the whole server (sockets, main-thread pump, endpoints, generic path resolver, batch engine) |
| `xEdit.dpr`, `xEdit\xeInit.pas`, `xEdit\xeMainForm.pas` | thin wiring + GUI-backed handlers (new file / save all) |
| `api-client/xedit_api_client.py` | zero-dependency Python client |
| `Tools/delphi13-compat/` | Delphi 13 build patches (re-apply after submodule updates) |
| `API_SERVER_DESIGN.md`, `DEV_SETUP_M0.md` | Chinese design & build docs |

---

## 2. Build & run

1. **Delphi 13 CE** installed (Community Edition; build inside the IDE).
2. `git submodule update --init --recursive`
3. `Tools\delphi13-compat\apply-patches.cmd`
4. Open `xEdit.dproj` → Configuration **LiteDebug**, Platform **Win64** → `Project > Build`. (The "Error Reading Form: frmMain … VirtualEditTree" dialog on open is expected; click **Cancel**, never save from the form designer.)
5. Run:

```bat
copy Build\xEdit.exe Build\SSEEdit.exe
SSEEdit.exe -SSE -api:7000            :: optional: -apitoken:mysecret
```

Load plugins through the GUI; the API becomes ready when `pluginsLoaded: true`.

---

## 3. API reference

Conventions:
- Base URL `http://127.0.0.1:7000`.
- Success `{"ok": true, ...}`; failure `{"ok": false, "error": {"code", "message"}}`.
- FormIDs are 8-hex load-order FormIDs (e.g. `030008D2`).
- Auth header `Authorization: Bearer <token>` when `-apitoken` is used (`/api/status` stays open).
- **Element paths**: display-name segments joined by `\`, numeric segments select list indexes (`Actor Effects\0`, `Keywords\KWDA - Keywords\0`, `DATA - DATA\Body Biped Object`).

| Method & path | Purpose |
|---|---|
| `GET /api` | endpoint index (agent discovery) |
| `GET /api/status` | app/game mode, `pluginsLoaded`, port |
| `GET /api/plugins` / `.../{fileName}` | load-ordered plugin list / one plugin (ESM/ESL flags, master lists) |
| `GET /api/plugins/{file}/records?signature&editorID&offset&limit&names` | paged record list |
| `GET /api/plugins/{file}/records/{formID}` | record metadata + full override chain |
| `GET /api/records/{formID}` | resolve a record across the whole load order + chain |
| `GET /api/find?editorID&signature&file&exact&limit` | find records by EditorID across loaded plugins (exact uses the EDID index when available, otherwise scans groups; the response reports `edidIndexEnabled`) |
| `GET /api/plugins/{file}/records/{formID}/tree?depth` | element tree JSON (`name/path/value/children`, raw values exposed) |
| `POST .../records/{formID}/values` | batch-edit fields: `{"values": {"FULL - Name": "..."}}` |
| `POST .../records/{formID}/copy-elements` | copy top-level elements *or* arbitrary paths between records |
| `POST .../records/{formID}/merge-effects` | merge Actor Effects lists (keep the override set plus extra entries) |
| `POST .../plugins/{file}/addmasters` | add masters by name |
| `POST .../plugins/{file}/save` | persist dirty plugins (GUI Save path; saves all dirty) |
| `POST /api/patch` | create a patch plugin (`{"fileName","isLight","records":[...]}`) |
| `POST /api/batch` | generic op orchestrator (below) |

### `POST /api/batch` — generic primitive orchestrator

Body: `{"strict": true|false, "ops": [ { "op": "...", ... } ]}`. Ops run in order on the main thread; each result is reported per op. **Nothing is written to disk unless an op `save` is included** — without it the batch is an in-memory dry run that is discarded when xEdit exits without saving.

```json
{ "strict": false,
  "ops": [
    { "op": "set", "file": "MyMod.esp", "formID": "010008D2",
      "values": { "FULL - Name": "New name", "DATA - DATA\\Base Carry Weight": "400" } },
    { "op": "copy", "file": "MyMod.esp", "formID": "010008D2",
      "source": { "file": "BaseMod.esm", "formID": "000008D2" }, "path": "DESC - Description" },
    { "op": "add-item", "file": "MyMod.esp", "formID": "010008D2", "path": "Actor Effects" },
    { "op": "remove-item", "file": "MyMod.esp", "formID": "010008D2",
      "path": "Actor Effects\\2" },
    { "op": "masters", "file": "MyMod.esp", "add": ["BaseMod.esm"], "sort": true },
    { "op": "save" }
  ] }
```

Supported ops: `set`, `copy`, `add-item`, `remove-item`, `create-record`, `masters`, `save`. Paths accept names or numeric indexes; `copy` creates a missing optional target automatically under its parent. `create-record` clones a source record as a **new record** (new FormID, optional `editorID` and `values`), which is how patches add content instead of only overriding it.

### Client examples (zero-dependency)

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

## 4. Known limitations / roadmap

- `save` saves all dirty plugins (same as the GUI Save button); per-file save reporting is planned.
- Edits are in-memory until saved; closing without saving discards them.
- Huge records make deep `tree` slow — filter with `signature`, or use bounded `depth`.
- Batch `copy` of reference fields requires the referenced plugins to already be masters (add them with a `masters` op first, then re-copy).
- Roadmap: per-file save report, compact tree mode, undo/snapshot support.

---

## 5. Developing on this fork

```bat
git remote rename origin upstream
git remote add origin git@github.com:<you>/xEdit-API.git
git switch -c dev-4.1.6-api
git push -u origin dev-4.1.6-api
```

Sync upstream later: `git fetch upstream && git merge upstream/dev-4.1.6`, then `git submodule update --init --recursive` and re-run `Tools\delphi13-compat\apply-patches.cmd`.

Code pointers:
- `Core/wbApiServer.pas` = whole server. Add endpoints in `TwbApiServer.HandleRequest`; handlers run on the main thread and answer with `RespondJson`.
- GUI-backed actions (new file / save-all) go through callbacks registered in `xeMainForm.WMUserLoaderDone`.
- Keep `wbInterface.pas` / `wbImplementation.pas` untouched to stay merge-friendly.

Credits: upstream xEdit by ElminsterAU and contributors ([repo](https://github.com/TES5Edit/TES5Edit), MPL-2.0). This fork keeps the MPL-2.0 license and headers.
