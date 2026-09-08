#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Smoke-test client for the xEdit (SSEEdit) HTTP/JSON API (M1/M2/M3).

Usage:
    status / plugins / plugin --file X
    records --file X [--signature S] [--editorID sub] [--names] [--offset N] [--limit N]
    record --record 030008D2 [--file X]
    tree --file X --record 030008D2 [--depth 8]
    set  --file X --record 030008D2 --values '{"DATA\\Weight":"12.5"}'

No third-party dependencies (urllib only).
"""
import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = "http://127.0.0.1"


def request(port, path, token=None, method="GET", body=None):
    data = body.encode("utf-8") if body is not None else None
    req = urllib.request.Request(f"{BASE}:{port}{path}", data=data, method=method)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode("utf-8"))
        except Exception:
            return e.code, {"raw": str(e)}
    except Exception as e:
        return None, {"error": str(e)}


def show(status, data, summarize=False):
    print(f"-> HTTP {status}")
    if summarize and status == 200:
        print(json.dumps(data, ensure_ascii=False, indent=2)[:8000])
    else:
        print(json.dumps(data, ensure_ascii=False, indent=2))


def main():
    ap = argparse.ArgumentParser(description="xEdit API client")
    sub = ap.add_subparsers(dest="cmd", required=True)

    for name in ("status", "plugins"):
        p = sub.add_parser(name)
        p.add_argument("--port", type=int, default=7000)
        p.add_argument("--token", default="")

    p = sub.add_parser("plugin"); p.add_argument("--port", type=int, default=7000); p.add_argument("--token", default="")
    p.add_argument("--file", required=True)

    p = sub.add_parser("records"); p.add_argument("--port", type=int, default=7000); p.add_argument("--token", default="")
    p.add_argument("--file", required=True)
    p.add_argument("--signature", default="")
    p.add_argument("--editorID", default="")
    p.add_argument("--offset", type=int, default=0)
    p.add_argument("--limit", type=int, default=100)
    p.add_argument("--names", action="store_true")

    p = sub.add_parser("record"); p.add_argument("--port", type=int, default=7000); p.add_argument("--token", default="")
    p.add_argument("--record", required=True, help="8-hex FormID, e.g. 030008D2")
    p.add_argument("--file", default="")

    p = sub.add_parser("tree"); p.add_argument("--port", type=int, default=7000); p.add_argument("--token", default="")
    p.add_argument("--file", required=True); p.add_argument("--record", required=True)
    p.add_argument("--depth", type=int, default=8)

    p = sub.add_parser("set"); p.add_argument("--port", type=int, default=7000); p.add_argument("--token", default="")
    p.add_argument("--file", required=True); p.add_argument("--record", required=True)
    p.add_argument("--values", default="",
                   help='JSON object of path->value, e.g. {"FULL - Name":"xxx"} (shell quoting is fragile; prefer --values-file)')
    p.add_argument("--values-file", default="", help="path to a UTF-8 JSON file containing the path->value object")

    p = sub.add_parser("save"); p.add_argument("--port", type=int, default=7000); p.add_argument("--token", default="")
    p.add_argument("--file", required=True)

    p = sub.add_parser("patch"); p.add_argument("--port", type=int, default=7000); p.add_argument("--token", default="")
    p.add_argument("--patch-file", required=True,
                   help='UTF-8 JSON file: {"fileName":"zz.esp","records":[{"formID":"00013740","file":"X.esp","winning":true}]}')

    args = ap.parse_args()
    token = getattr(args, "token", "")

    if args.cmd == "status":
        show(*request(args.port, "/api/status", token))
    elif args.cmd == "plugins":
        st, data = request(args.port, "/api/plugins", token)
        print(f"-> HTTP {st}")
        if st == 200:
            print(f"plugins loaded: {data.get('count')}")
            for pl in data.get("plugins", []):
                print(f"  [{pl['index']:>2}] LO{pl['loadOrder']:>3}  "
                      f"{pl['fileName']:<40} esm={pl['isESM']!s:<5} "
                      f"light={pl['isLight']!s:<5} masters={len(pl['masters'])}")
        else:
            show(st, data)
    elif args.cmd == "plugin":
        show(*request(args.port, "/api/plugins/" + urllib.parse.quote(args.file), token))
    elif args.cmd == "records":
        q = urllib.parse.urlencode({
            "offset": args.offset, "limit": args.limit,
            **({"signature": args.signature} if args.signature else {}),
            **({"editorID": args.editorID} if args.editorID else {}),
            **({"names": "1"} if args.names else {}),
        })
        st, data = request(args.port,
                           "/api/plugins/" + urllib.parse.quote(args.file) + "/records?" + q, token)
        print(f"-> HTTP {st}")
        if st == 200:
            print(f"plugin={data.get('plugin')} returned={data.get('returned')} hasMore={data.get('hasMore')}")
            for r in data.get("records", []):
                print(f"  {r['loadOrderFormID']} {r['signature']:<4} "
                      f"{r.get('editorID', ''):<45} "
                      f"{'MASTER' if r['isMaster'] else ''}{'WIN' if r['isWinningOverride'] else ''}")
        else:
            show(st, data)
    elif args.cmd == "record":
        path = "/api/records/" + args.record if not args.file else \
               "/api/plugins/" + urllib.parse.quote(args.file) + "/records/" + args.record
        show(*request(args.port, path, token))
    elif args.cmd == "tree":
        path = ("/api/plugins/" + urllib.parse.quote(args.file) + "/records/" + args.record +
                f"/tree?depth={args.depth}")
        show(*request(args.port, path, token), summarize=True)
    elif args.cmd == "set":
        if args.values_file:
            with open(args.values_file, "r", encoding="utf-8") as fh:
                vals_raw = fh.read()
        else:
            vals_raw = args.values
        if not vals_raw.strip():
            print("ERROR: provide --values or --values-file")
            sys.exit(1)
        try:
            vals_obj = json.loads(vals_raw)
        except json.JSONDecodeError as e:
            print(f"ERROR: --values is not valid JSON: {e}")
            sys.exit(1)
        if not isinstance(vals_obj, dict):
            print("ERROR: --values must be a JSON object")
            sys.exit(1)
        path = "/api/plugins/" + urllib.parse.quote(args.file) + "/records/" + args.record + "/values"
        show(*request(args.port, path, token, method="POST", body=json.dumps({"values": vals_obj})))
    elif args.cmd == "save":
        path = "/api/plugins/" + urllib.parse.quote(args.file) + "/save"
        show(*request(args.port, path, token, method="POST", body="{}"))
    elif args.cmd == "patch":
        with open(args.patch_file, "r", encoding="utf-8") as fh:
            body = fh.read()
        show(*request(args.port, "/api/patch", token, method="POST", body=body))
    else:
        ap.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
