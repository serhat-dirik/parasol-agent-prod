# Shared by the OGX checks (source it). A test OGX server runs in parasol-ogx-lab (setup.sh); the checks reach
# it through a port-forward and pass MCP tools that point at the in-cluster MCP gateway, as an agent pod would.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../../.." && pwd)"
NS=${OGX_LAB_NS:-parasol-ogx-lab}
OGX=${OGX_URL:-http://localhost:18321}
MODEL=${OGX_MODEL:-maas/qwen3-14b}
GW_IN_CLUSTER=http://mcp-gateway-openshift-default.gateway-system.svc.cluster.local:8080/mcp

if ! curl -sf "$OGX/v1/health" >/dev/null 2>&1; then
  oc port-forward -n "$NS" svc/ogx-lab-service 18321:8321 >/dev/null 2>&1 &
  _pf=$!; trap 'kill $_pf 2>/dev/null' EXIT
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sf "$OGX/v1/health" >/dev/null 2>&1 && break; sleep 1; done
fi

# token <user> [agent]: the on-behalf-of token an agent presents at the gateway (never printed)
token() { "$repo/scripts/agent-token.sh" "$@"; }

# mcp_tool <label> <virtual server> <bare token> [allowed tools json]: a Responses API MCP tool entry
mcp_tool() {
  python3 -c 'import json,sys
t={"type":"mcp","server_label":sys.argv[1],"server_url":sys.argv[2],"headers":{"X-Mcp-Virtualserver":sys.argv[3]},
   "authorization":sys.argv[4],"require_approval":"never"}
if sys.argv[5]: t["allowed_tools"]=json.loads(sys.argv[5])
print(json.dumps(t))' "$1" "$GW_IN_CLUSTER" "parasol-secured/$2" "$3" "${4:-}"
}

# summary: one line per output item of a Responses API result on stdin, then the status
summary() {
  python3 -c 'import json,sys
r=json.load(sys.stdin)
if "output" not in r: print("ERROR", json.dumps(r)[:300]); sys.exit(0)
for o in r["output"]:
    t=o["type"]
    if t=="mcp_list_tools": print("  mcp_list_tools", o["server_label"], [x["name"] for x in o["tools"]])
    elif t=="mcp_call": print("  mcp_call", o["name"], "error=" + str(o.get("error"))[:160] if o.get("error") else "ok")
    elif t=="function_call": print("  function_call", o["name"], o["arguments"])
    elif t=="message": print("  message", " ".join(c.get("text","") for c in o["content"]).strip().replace("\n"," ")[:160])
    else: print("  ", t)
print("status:", r["status"], "id:", r["id"])'
}

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; exit 1; }
