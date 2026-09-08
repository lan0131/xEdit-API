# xEdit-API

A fork of **[TES5Edit/TES5Edit](https://github.com/TES5Edit/TES5Edit)** (the xEdit codebase by ElminsterAU) that adds an **in-process HTTP/JSON API** to xEdit — primarily for **SSEEdit (Skyrim Special Edition)** — so external programs can:

- read the loaded plugin list, load order, ESM/ESL flags and master dependencies;
- list and inspect records, their override chains, winning overrides and referencers;
- dump a record's element tree as JSON;
- **edit record fields**, **create patch plugins** and **save plugins to disk** — over plain HTTP.

**Verified environment:** Windows + **Delphi 13 Community Edition (RAD Studio 37.0)**, target config `LiteDebug / Win64`, based on upstream `dev-4.1.6`.

> 中文版见 **[README.zh-CN.md](README.zh-CN.md)**.

---

## 1. What was added (vs. upstream)

| New file / change | Purpose |
|---|---|
| `Core/wbApiServer.pas` (~1700 lines) | localhost HTTP/1.1 + JSON server: `-api` switch parsing, background accept thread, **VCL main-thread job pump**, optional bearer token, all read/write handlers |
| `xEdit.dpr`, `xEdit\xeInit.pas`, `xEdit\xeMainForm.pas` | thin wiring: register unit, parse `-api` switches, start the server after plugins load, register GUI-backed handlers (create file / save all) |
| `api-client/xedit_api_client.py` | zero-dependency Python client (`status / plugins / records / record / tree / set / save / patch`) |
| `tools/delphi13-compat/` | patches needed to build this codebase with **Delphi 13** (see §3), re-appliable after submodule updates |
| `API_SERVER_DESIGN.md`, `DEV_SETUP_M0.md` | design docs and environment/build notes (Chinese) |

Architecture in one paragraph: xEdit data structures are bound to the VCL main thread, so a background socket thread only accepts connections and parses HTTP; every request becomes a job that is executed on the main thread through a `TTimer` pump, and the answer is written back when the job finishes. JSON is produced/parsed with `JsonDataObjects` (already bundled). All record/file work reuses the same internal APIs the GUI and edit-scripts use.

---

## 2. Usage

### 2.1 Build

See §3 for prerequisites. After a successful IDE build you get `Build\xEdit.exe`.

### 2.2 Run

```bat
:: copy once
copy Build\xEdit.exe Build\SSEEdit.exe

:: start with the API enabled (place in the game Data folder if it can't find the game)
SSEEdit.exe -SSE -api:7000

:: optional auth token (required on every call except GET /api/status)
SSEEdit.exe -SSE -api:7000 -apitoken:mysecret
```

Load plugins normally in the GUI. When loading finishes the API is listening on `http://127.0.0.1:7000`.

### 2.3 Quick check

```powershell
python api-client\xedit_api_client.py status
python api-client\xedit_api_client.py plugins
python api-client\xedit_api_client.py record --record 00013740 --file "SCSI-RaceGlory.esp"
curl -s http://127.0.0.1:7000/api/status
```

---

## 3. Building from a fresh clone of this fork

1. **Delphi 13 CE** installed (Community Edition; command-line compilation is disabled by the license, use the IDE).
2. Initialize submodules:
   ```bat
   git submodule update --init --recursive
   ```
3. Re-apply the Delphi 13 compatibility patches (required until upstream ships them):
   ```bat
   tools\delphi13-compat\apply-patches.cmd
   ```
   (copies `jcld29win32/64.inc` into jcl and applies the SynEdit + JVCL diffs. Re-run after `git submodule update`.)
4. Open `xEdit.dproj` in Delphi; Configuration = **LiteDebug**, Platform = **Win64**; `Project -> Build` (`Ctrl+Shift+F9`).
   - The “Error Reading Form: 'frmMain' … VirtualEditTree” dialog on open is **expected** (no design-time VirtualTree package installed). Click **Cancel** — it does not affect compilation. Never save from the form designer.
5. Output: `Build\xEdit.exe` → rename to `SSEEdit.exe` or run with `-SSE`.

---

## 4. API reference

Conventions:

- Base URL `http://127.0.0.1:7000` (override with `-api:<port>`).
- Responses: success `{"ok": true, ...}`; failure `{"ok": false, "error": {"code", "message"}}`.
- FormIDs are **8-hex load-order FormIDs**, e.g. `030008D2`.
- Auth: header `Authorization: Bearer <token>` (only when started with `-apitoken`; `/api/status` stays open).

| Method & path | Description |
|---|---|
| `GET /api/status` | version, game/tool mode, `pluginsLoaded`, port |
| `GET /api/plugins` | load-ordered plugin list: fileName, fileID, ESM/ESL/medium/update flags, full/light/medium master lists |
| `GET /api/plugins/{fileName}` | single plugin details (same fields) |
| `GET /api/plugins/{fileName}/records?signature=&editorID=&offset=&limit=&names=` | paged record list (limit ≤ 500; `signature` exact, `editorID` substring) |
| `GET /api/plugins/{fileName}/records/{loadOrderFormID}` | record metadata + full override chain (master, all overrides, winning override) |
| `GET /api/records/{loadOrderFormID}` | resolve a record across the whole load order + override chain |
| `GET /api/plugins/{fileName}/records/{loadOrderFormID}/tree?depth=N` | element tree JSON (`name` / `path` / `value` / `children`; depth default 8, max 20) |
| `POST /api/plugins/{fileName}/records/{loadOrderFormID}/values` | batch-edit fields. Body: `{"values": {"FULL - Name": "New name"}}` — keys are the display-name paths shown by `tree` |
| `POST /api/plugins/{fileName}/save` | persist dirty plugins using the same code path as the GUI **Save** button (saves *all* dirty plugins, with backups/atomic rename) |
| `POST /api/patch` | create a patch plugin. Body example: `{"fileName": "zz_api_patch.esp", "records": [{"formID": "00013740", "file": "SCSI-RaceGlory.esp", "winning": false}]}` → creates the file (added to the GUI), copies each record as an override with required masters (`element.CopyInto`), then `SortMasters`/`CleanMasters`. Optional `"autoSave": true` |

### Examples

```powershell
# change a record's name
python api-client\xedit_api_client.py set --file "SCSI-RaceGlory.esp" --record 00013740 --values-file api-client\sample-values.json

# save it
python api-client\xedit_api_client.py save --file "SCSI-RaceGlory.esp"

# build a patch plugin with two RACE overrides
python api-client\xedit_api_client.py patch --patch-file api-client\sample-patch.json

# ... then save the new file too
python api-client\xedit_api_client.py save --file "zz_api_patch.esp"
```

`tree` output looks like:

```json
{ "ok": true, "plugin": "SCSI-RaceGlory.esp", "loadOrderFormID": "00013740",
  "tree": { "name": "ArgonianRace \"Argonian\" [RACE:00013740]", "path": "RACE",
            "children": [
              { "name": "EDID - Editor ID", "path": "RACE \\ EDID - Editor ID" },
              { "name": "FULL - Name", "path": "RACE \\ FULL - Name" }
            ] } }
```

---

## 5. Known limitations & roadmap

- `save` = “save all dirty plugins” (same semantics as the GUI Save), not a per-file report yet.
- `/api/status` `busy` currently also counts the request that is being answered.
- Very large records (huge arrays / navmeshes) make `tree` slow; a compact mode is planned.
- Element paths are xEdit display-name paths; short/signature aliases are planned.
- Threading: everything runs on the xEdit main thread (same guarantees as doing it in the GUI); long operations block the GUI briefly.

Roadmap (M4): single-file save reporting, `busy` fix, compact tree mode, short-path aliases, `/api/shutdown`.

---

## 6. Developing on this fork

Remote layout that we recommend (already set up in the original workspace):

```bat
git remote rename origin upstream                      :: the original TES5Edit repo
git remote add origin git@github.com:<you>/xEdit-API.git
git switch -c dev-4.1.6-api
git push -u origin dev-4.1.6-api
```

Sync upstream later:

```bat
git fetch upstream
git merge upstream/dev-4.1.6        :: or: git rebase upstream/dev-4.1.6
git submodule update --init --recursive
tools\delphi13-compat\apply-patches.cmd
```

Code pointers:

- `Core/wbApiServer.pas` — the whole server. New endpoints = add a route in `TwbApiServer.HandleRequest` + a handler method that runs on the main thread and answers with `RespondJson`.
- Handlers that need GUI services (create a plugin file, save-all) go through the registered callbacks `wbApiServerSetAddFileHandler` / `wbApiServerSetSaveAllHandler` (registered in `xeMainForm.WMUserLoaderDone`) — the Core unit stays GUI-free.
- Do not touch `wbInterface.pas` / `wbImplementation.pas` / record definitions; keep the diff small for easy merging with upstream.

Credits & license: upstream xEdit by ElminsterAU and contributors ([repo](https://github.com/TES5Edit/TES5Edit), MPL-2.0). This fork keeps the MPL-2.0 license and headers.
