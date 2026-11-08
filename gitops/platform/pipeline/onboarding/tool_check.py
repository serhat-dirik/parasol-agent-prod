"""Onboarding check of a third-party MCP server image (pipeline parasol-tool-onboarding, task tool-check).

The image runs as the task's sidecar (no ServiceAccount token, egress only to NeMo and DNS); this script talks to it
on localhost and decides whether Parasol may run it. It reviews what can be seen before deployment:
  1 the server says the version being onboarded (serverInfo.version);
  2 the tool definitions (name, description, input schema) match the pin a person reviewed for that version in
    Git (onboarding.json); a version with no pin is not promoted, the run prints the sha256 a reviewer would add;
  3 no description names one of Parasol's own tools (a currency tool has no reason to mention approve_payout);
  4 each description passes the MCP gateway's own guardrails: NeMo, config parasol-tool-results, the check the gateway
    runs on every tool result at runtime;
  5 the contract: known calls return the expected answer, and each result passes the same NeMo check.
What it cannot see (behaviour only on some inputs, later, or only for some callers) is left to the runtime controls:
the gateway's guardrails on every result, least privilege, no egress, the runtime scanner.

  python3 tool_check.py --policy onboarding.json --server currency-converter --version 1.4.3 \
      --url http://localhost:8080/mcp --out-dir /tekton/results --report report.json
Exit 0 either way; the decision is the `gate` result (passed / refused). NEMO_URL=off skips the NeMo checks (local test).
"""
import argparse, hashlib, json, os, re, sys, time, urllib.request


def rpc(url, msg, session=None):
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if session:
        h["Mcp-Session-Id"] = session
    with urllib.request.urlopen(urllib.request.Request(url, json.dumps(msg).encode(), h), timeout=20) as r:
        sid, body = r.headers.get("Mcp-Session-Id") or session, r.read().decode()
        if "text/event-stream" in (r.headers.get("Content-Type") or ""):
            data = [l[5:].strip() for l in body.splitlines() if l.startswith("data:")]
            body = next((d for d in data if '"result"' in d or '"error"' in d), "")
        return (json.loads(body) if body.strip() else None), sid


def session(url):
    init, sid = rpc(url, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-03-26", "capabilities": {},
        "clientInfo": {"name": "parasol-tool-onboarding", "version": "1"}}})
    rpc(url, {"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    return init["result"].get("serverInfo", {}), sid


def digest(tools):
    """The same sha256 as the runtime scanner (gitops/platform/mcp-gateway/tool-scanner/scan.py)."""
    canon = sorted(({"name": t["name"], "description": t.get("description", ""),
                     "inputSchema": t.get("inputSchema", {})} for t in tools), key=lambda t: t["name"])
    return hashlib.sha256(json.dumps(canon, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def nemo_blocks(tool, text):
    """NeMo as the MCP gateway calls it on a tool result (config parasol-tool-results). None = check skipped."""
    url = os.environ.get("NEMO_URL", "http://parasol-nemo.parasol-secured.svc.cluster.local").rstrip("/")
    if url == "off":
        return None
    body = json.dumps({"model": "qwen3-14b", "messages": [{"role": "assistant", "name": tool, "content": text}],
                       "guardrails": {"config_ids": ["parasol-tool-results"]}}).encode()
    req = urllib.request.Request(url + "/v1/checks", body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=90) as r:   # unreachable = exception = the run fails (fail closed)
        return json.load(r).get("status") == "blocked"


def check(policy, server, version, url):
    """-> (report dict). Findings are short strings; any finding refuses the version."""
    cfg = policy["servers"][server]
    info, sid = session(url)
    tools, cursor = [], None
    while True:
        res, _ = rpc(url, {"jsonrpc": "2.0", "id": 2, "method": "tools/list",
                           "params": {"cursor": cursor} if cursor else {}}, sid)
        tools += res["result"]["tools"]
        cursor = res["result"].get("nextCursor")
        if not cursor:
            break
    sha, pin, findings, notes = digest(tools), cfg.get("pins", {}).get(version), [], []
    if info.get("version") != version:
        findings.append(f"version: the server says {info.get('version')!r}, onboarding {version}")
    if not pin:
        findings.append(f"pin: no reviewed pin for {server} {version} in Git; a reviewer who accepts these tool "
                        f"definitions adds \"{version}\": \"{sha}\" to onboarding.json")
    elif pin != sha:
        findings.append(f"pin: tool definitions differ from the reviewed pin of {version} ({pin[:12]}..., got {sha[:12]}...)")
    own = set(policy.get("parasol_tools", [])) - {t["name"] for t in tools}
    for t in tools:
        text = t.get("description", "") + " " + json.dumps(t.get("inputSchema", {}))
        for n in sorted(own):
            if re.search(rf"\b{re.escape(n)}\b", text):
                findings.append(f"description: {t['name']} names Parasol's tool {n}")
        blocked = nemo_blocks(t["name"], t.get("description", ""))
        if blocked:
            findings.append(f"guardrails: {t['name']}'s description blocked by NeMo parasol-tool-results "
                            "(it addresses the assistant)")
        notes.append(f"guardrails on {t['name']} description: " + {None: "skipped", True: "BLOCKED", False: "pass"}[blocked])
    for c in cfg.get("contract", []):
        res, _ = rpc(url, {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                           "params": {"name": c["tool"], "arguments": c["arguments"]}}, sid)
        text = " ".join(x.get("text", "") for x in (res or {}).get("result", {}).get("content", []))
        call = f"{c['tool']}({', '.join(f'{k}={v}' for k, v in c['arguments'].items())})"
        if c["expect"] not in text:
            findings.append(f"contract: {call} returned {text[:80]!r}, expected {c['expect']!r}")
        blocked = nemo_blocks(c["tool"], text)
        if blocked:
            findings.append(f"guardrails: the result of {call} blocked by NeMo parasol-tool-results")
        notes.append(f"contract {call} -> {text[:60]!r}: " + ("ok" if c["expect"] in text else "WRONG")
                     + {None: "", True: ", result BLOCKED", False: ", result passes guardrails"}[blocked])
    return {"server": server, "version": version, "server_info": info, "tools": [t["name"] for t in tools],
            "tools_sha256": sha, "pin": pin or "", "findings": findings, "checks": notes,
            "gate": "refused" if findings else "passed"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--policy", required=True)
    ap.add_argument("--server", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--url", default="http://localhost:8080/mcp")
    ap.add_argument("--out-dir", default="")
    ap.add_argument("--report", default="")
    a = ap.parse_args()
    health = a.url.rsplit("/", 1)[0] + "/health"
    for i in range(60):   # the sidecar starts with the step
        try:
            urllib.request.urlopen(health, timeout=2).read(); break
        except Exception:
            time.sleep(2)
    rep = check(json.load(open(a.policy)), a.server, a.version, a.url)
    print(f"===== onboarding check: {a.server} {a.version} (server says {rep['server_info'].get('version')}) =====")
    print(f"tools: {', '.join(rep['tools'])}   sha256 {rep['tools_sha256']}   reviewed pin: {rep['pin'] or 'none'}")
    for n in rep["checks"]:
        print("  " + n)
    for f in rep["findings"]:
        print("FINDING " + f)
    print(("REFUSED: " if rep["findings"] else "PASSED: ") + f"{a.server} {a.version}, {len(rep['findings'])} finding(s)"
          + ("; nothing is signed or promoted" if rep["findings"] else "; next: sign and promote"))
    if a.report:
        json.dump(rep, open(a.report, "w"), indent=1)
    if a.out_dir:
        for k, v in {"gate": rep["gate"], "tools-sha256": rep["tools_sha256"],
                     "findings": str(len(rep["findings"]))}.items():
            open(os.path.join(a.out_dir, k), "w").write(v)


if __name__ == "__main__":
    sys.exit(main())
