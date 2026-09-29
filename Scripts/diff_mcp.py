#!/usr/bin/env python3
"""MCP /mcp differential: legacy Python SDK wire (golden capture) vs
the Swift MCPHTTP mount, plus the cross-transport invariant.

Usage: python3 Scripts/diff_mcp.py <swift_port> [--against <legacy_port>]
  The legacy side is the golden-capture stub
  (<scratch>/mcp_wire_capture.py, mcp SDK 1.30.0, stateless=True) —
  it answers tools/list with its own probe tool, so tools/list is
  compared STRUCTURALLY (envelope + tool-shape keys), not by content.

Checks:
  1. RPC semantics vs legacy: initialize (known/unknown pv/no-params),
     ping, unknown-method, parse-error, accept-gate, DELETE.
     GET is the documented deviation (legacy holds the SSE stream open
     forever; stateless Swift declines with 405 — status-only check).
  2. Cross-transport invariant (Swift only, real engine): tools/call
     laya_ask returns the SAME answer document as POST /v1/laya for
     the same payload, and laya_status chains == GET /health. MCP and
     HTTP cannot drift — the legacy daemon guaranteed this by sharing
     one Server app; we guarantee it by sharing MCP.dispatch +
     QuestionAPI.answerRequest.
"""
import json, sys, urllib.request, urllib.error

def post(port, body, accept="application/json, text/event-stream",
         method="POST", path="/mcp", timeout=10):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}",
                                 data=(body.encode() if isinstance(body, str) else body)
                                      if body is not None else None,
                                 method=method,
                                 headers={"content-type": "application/json",
                                          "accept": accept})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except (TimeoutError, OSError):
        return "HELD", ""   # stream held open (legacy GET)

def sse_data(text):
    for line in text.splitlines():
        if line.startswith("data: "):
            return json.loads(line[6:])
    return None

def envelope(text):
    e = sse_data(text) or (json.loads(text) if text.strip().startswith("{") else None)
    # Each server reports ITS OWN version in serverInfo (the capture
    # stub is pinned at 0.2.0; a 0.3.0 daemon says 0.3.0). The gate is
    # about protocol behavior, so normalize that one field.
    if isinstance(e, dict):
        si = e.get("result", {}).get("serverInfo")
        if isinstance(si, dict):
            si = dict(si, version="<self>")
            e = dict(e, result=dict(e["result"], serverInfo=si))
    return e

CASES = [
    # (name, body, accept, compare: "full" | "code" | "struct")
    ("initialize",      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"0"}}}', None, "full"),
    ("init-unknown-pv", '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01","capabilities":{},"clientInfo":{"name":"c","version":"0"}}}', None, "full"),
    ("init-no-params",  '{"jsonrpc":"2.0","id":11,"method":"initialize","params":{}}', None, "full"),
    ("ping",            '{"jsonrpc":"2.0","id":10,"method":"ping"}', None, "full"),
    ("tools/list",      '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}', None, "struct"),
    ("unknown-method",  '{"jsonrpc":"2.0","id":4,"method":"nope"}', None, "full"),
    ("garbage-body",    'not json', None, "code"),
    ("json-only-accept",'{"jsonrpc":"2.0","id":5,"method":"tools/list"}', "application/json", "code"),
]

def main():
    swift_port = int(sys.argv[1])
    legacy_port = 11999
    if "--against" in sys.argv:
        legacy_port = int(sys.argv[sys.argv.index("--against") + 1])

    mismatches = 0
    checked = 0
    for name, body, accept, mode in CASES:
        checked += 1
        acc = accept or "application/json, text/event-stream"
        ls, lb = post(legacy_port, body, accept=acc)
        ss, sb = post(swift_port, body, accept=acc)
        le, se = envelope(lb), envelope(sb)
        if mode == "full":
            ok = ls == ss and le == se
        elif mode == "code":
            # same status + same JSON-RPC code + same id (message texts
            # like the pydantic dump are not reproducible by design)
            ok = (ls == ss and le and se
                  and le["error"]["code"] == se["error"]["code"]
                  and le.get("id") == se.get("id"))
        else:  # struct: envelope shape + tool entries well-formed
            ok = (ls == ss == 200 and le and se
                  and le.get("result", le).get("tools") is not None
                  and se.get("result", se).get("tools") is not None
                  and all({"name", "description", "inputSchema"} <= set(t)
                          for t in se["result"]["tools"]))
        print(f"{'OK ' if ok else 'DIFF'} {name:18s} status {ls}/{ss} mode={mode}")
        if not ok:
            mismatches += 1
            print(f"   py: {lb[:200]}")
            print(f"   sw: {sb[:200]}")

    # GET — documented deviation. Legacy opens the SSE stream and holds
    # it (HELD/406); stateless Swift declines with 405.
    checked += 1
    ls, _ = post(legacy_port, None, method="GET", timeout=4)
    ss, sb = post(swift_port, None, method="GET")
    se = envelope(sb)
    ok = ss == 405 and ls in ("HELD", 406, 200) and se and se["error"]["code"] == -32600
    print(f"{'OK ' if ok else 'DIFF'} {'GET(deviation)':18s} legacy {ls} → swift {ss}")
    if not ok: mismatches += 1

    # DELETE — exact parity expected.
    checked += 1
    ls, lb = post(legacy_port, None, method="DELETE")
    ss, sb = post(swift_port, None, method="DELETE")
    ok = ls == ss == 405 and envelope(lb) == envelope(sb)
    print(f"{'OK ' if ok else 'DIFF'} {'DELETE':18s} status {ls}/{ss}")
    if not ok: mismatches += 1

    # --- cross-transport invariants (Swift side, real engine) ---
    payload = json.dumps({"state": "rm -rf /var/tmp/scratch && echo done",
                          "questions": {"danger": {
                              "type": "noul",
                              "instructions": "Does the action destroy data irreversibly?"}}})
    checked += 1
    _, mb = post(swift_port, json.dumps({
        "jsonrpc": "2.0", "id": 40, "method": "tools/call",
        "params": {"name": "laya_ask", "arguments": json.loads(payload)}}))
    mcp_env = envelope(mb)
    _, hb = post(swift_port, payload, path="/v1/laya")
    http_doc = json.loads(hb)
    tool_text = (json.loads(mcp_env["result"]["content"][0]["text"])
                 if mcp_env and "result" in mcp_env and not mcp_env["result"].get("isError")
                 else None)
    ok = tool_text == http_doc
    print(f"{'OK ' if ok else 'DIFF'} {'ask==/v1/laya':18s} mcp_answer==http_answer {ok}")
    if not ok:
        mismatches += 1
        print(f"   mcp: {json.dumps(tool_text)[:200]}")
        print(f"   http: {json.dumps(http_doc)[:200]}")

    checked += 1
    _, sb2 = post(swift_port, json.dumps({
        "jsonrpc": "2.0", "id": 41, "method": "tools/call",
        "params": {"name": "laya_guard",
                   "arguments": {"command": "rm -rf /"}}}))
    guard = json.loads(envelope(sb2)["result"]["content"][0]["text"])
    # The documented canary contract: rm -rf / must NEVER be "allow"
    # (the trained chain answers ask_user → confirm; block → deny is
    # equally acceptable). "allow" here would be a regression.
    ok = guard.get("verdict") in ("confirm", "deny")
    print(f"{'OK ' if ok else 'DIFF'} {'guard canary':18s} {guard.get('verdict')}/{guard.get('choice')} (never allow)")
    if not ok: mismatches += 1

    checked += 1
    _, sb3 = post(swift_port, json.dumps({
        "jsonrpc": "2.0", "id": 42, "method": "tools/call",
        "params": {"name": "laya_status", "arguments": {}}}))
    st = json.loads(envelope(sb3)["result"]["content"][0]["text"])
    _, hb2 = post(swift_port, None, method="GET", path="/health")
    health = json.loads(hb2)
    ok = bool(st.get("ok")) and st.get("chains") == health.get("chains")
    print(f"{'OK ' if ok else 'DIFF'} {'status==/health':18s} chains match={ok}")
    if not ok: mismatches += 1

    print(f"\nmcp differential: {checked - mismatches}/{checked} match")
    sys.exit(1 if mismatches else 0)

main()
