#!/usr/bin/env python3
"""Mint a LAVA artifact upload slot via the MCP streamable-HTTP endpoint.
No `claude` CLI needed — a plain 3-step JSON-RPC handshake (initialize ->
notifications/initialized -> tools/call create_artifact_upload) using the
X-Lava-Token already present in ~/.claude.json (or $LAVA_TOKEN).

Usage: mint_lava.py <filename> <size_bytes>
Prints a compact JSON object: {"get_url":..., "token":..., "name":...}
"""
import json, os, sys, urllib.request

LAVA_URL = os.environ.get("LAVA_URL", "https://lava.infra.foundries.io").rstrip("/")
CJ = os.environ.get("CLAUDE_JSON", os.path.expanduser("~/.claude.json"))

def token():
    t = os.environ.get("LAVA_TOKEN", "").strip()
    if t:
        return t
    d = json.load(open(CJ))
    cands = [d.get("mcpServers", {})]
    cands += [p.get("mcpServers", {}) for p in d.get("projects", {}).values()]
    for m in cands:
        l = m.get("lava")
        if l:
            h = l.get("headers", {})
            t = h.get("X-Lava-Token") or h.get("C-Lava-Token")
            if t:
                return t
    raise SystemExit("no LAVA token in $LAVA_TOKEN or %s" % CJ)

def post(tok, body, sid=None):
    hdr = {"X-Lava-Token": tok, "Content-Type": "application/json",
           "Accept": "application/json, text/event-stream"}
    if sid:
        hdr["mcp-session-id"] = sid
    req = urllib.request.Request(LAVA_URL + "/mcp",
                                 data=json.dumps(body).encode(), headers=hdr)
    r = urllib.request.urlopen(req, timeout=30)
    return r, r.read().decode()

def parse(raw):
    # response is either plain JSON or SSE ("data: {...}")
    for line in raw.splitlines():
        line = line[6:] if line.startswith("data: ") else line
        line = line.strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except Exception:
                pass
    return json.loads(raw)

def main():
    fn, sz = sys.argv[1], int(sys.argv[2])
    tok = token()
    # 1) initialize -> session id (in response header)
    r, _ = post(tok, {"jsonrpc":"2.0","id":0,"method":"initialize",
        "params":{"protocolVersion":"2025-06-18","capabilities":{},
                  "clientInfo":{"name":"submit.sh","version":"1"}}})
    sid = r.headers.get("mcp-session-id")
    if not sid:
        raise SystemExit("no mcp-session-id from initialize")
    # 2) initialized notification
    post(tok, {"jsonrpc":"2.0","method":"notifications/initialized"}, sid)
    # 3) tools/call
    _, raw = post(tok, {"jsonrpc":"2.0","id":1,"method":"tools/call",
        "params":{"name":"create_artifact_upload",
                  "arguments":{"filename":fn,"size_bytes":sz}}}, sid)
    d = parse(raw)
    txt = d["result"]["content"][0]["text"]
    j = json.loads(txt)
    out = {"get_url": j["get_url"], "token": j["token"],
           "name": j.get("remote_artifact_token", {}).get("name", "")}
    print(json.dumps(out))

if __name__ == "__main__":
    main()
