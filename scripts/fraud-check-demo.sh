#!/usr/bin/env bash
# V3 proof: the agent-to-agent call through the MCP gateway.
# The claims assistant calls the fraud-check agent as a tool (fraud_check) through the ONE MCP gateway,
# carrying the caller's own Keycloak token, so the same per-identity authz as every other tool applies.
#   rebecca (adjuster)        -> allowed -> HIGH-risk verdict flagging CLM-1004 AED 84,000 vs record 8,400
#   marcus  (claims-manager)  -> allowed -> same verdict
#   tom.becker (policyholder) -> 403 at the gateway (no tool:fraud_check role)
# This reproduces exactly what the portal's fraud-check MCP client sends (initialize -> tools/call).
set -uo pipefail
HERE="$(dirname "$0")"
CLAIM="${CLAIM:-CLM-1004}"
GW="${GW:-https://mcp.apps.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')/mcp}"
VS="parasol-secured/fraud-check"
hdr(){ printf '\n\033[1;33m%s\033[0m\n' "$*"; }

# One agent-to-agent fraud_check call through the gateway as $1. Prints HTTP status + verdict/refusal.
call() {
  local user="$1" tok h sid
  tok="$("$HERE/token.sh" "$user")" || { echo "  token mint failed for $user"; return; }
  # Show the token actually carries (or lacks) the tool role the gateway checks.
  printf '  %s resource_access[%s]: ' "$user" "$VS"
  printf '%s' "$tok" | python3 -c 'import sys,json,base64
p=sys.stdin.read().split(".")[1]; p+="="*(-len(p)%4)
c=json.loads(base64.urlsafe_b64decode(p))
print(c.get("resource_access",{}).get("parasol-secured/fraud-check",{}).get("roles",[]))'
  h=(-H "Authorization: Bearer $tok" -H 'content-type: application/json'
     -H 'accept: application/json, text/event-stream' -H "X-Mcp-Virtualserver: $VS")
  sid=$(curl -sk -D - -o /dev/null "$GW" "${h[@]}" \
    -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"fraud-check-demo","version":"1"}}}' \
    | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' | tr -d '\r')
  curl -sk -o /dev/null "$GW" "${h[@]}" -H "mcp-session-id: $sid" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '  %s -> fraud_check(%s): ' "$user" "$CLAIM"
  curl -sk -w '|HTTP %{http_code}' "$GW" "${h[@]}" -H "mcp-session-id: $sid" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"fraud_check\",\"arguments\":{\"claimNumber\":\"$CLAIM\"}}}" \
    | python3 -c 'import sys,json
raw=sys.stdin.read(); code=raw.rsplit("|HTTP ",1)[-1].strip() if "|HTTP " in raw else "?"
body=raw.rsplit("|HTTP ",1)[0]
txt=None
for line in body.splitlines():
    line=line[5:].strip() if line.startswith("data:") else line
    try: j=json.loads(line)
    except Exception: continue
    if "result" in j:
        try: txt=j["result"]["content"][0]["text"]
        except Exception: txt=json.dumps(j["result"])[:200]
    elif "error" in j: txt="JSON-RPC error: "+json.dumps(j["error"])[:200]
if txt is None: txt=body.strip()[:200]
print("HTTP",code)
for l in txt.splitlines(): print("     "+l)'
}

hdr "Gateway: $GW   virtual server: $VS   claim: $CLAIM"
hdr "tools/list for rebecca (fraud_check federated behind the gateway):"
rtok="$("$HERE/token.sh" rebecca)"
rh=(-H "Authorization: Bearer $rtok" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -H "X-Mcp-Virtualserver: $VS")
rsid=$(curl -sk -D - -o /dev/null "$GW" "${rh[@]}" -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"fraud-check-demo","version":"1"}}}' | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' | tr -d '\r')
curl -sk -o /dev/null "$GW" "${rh[@]}" -H "mcp-session-id: $rsid" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
curl -sk "$GW" "${rh[@]}" -H "mcp-session-id: $rsid" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | python3 -c 'import sys,json
for line in sys.stdin:
    line=line[5:].strip() if line.startswith("data:") else line
    try: j=json.loads(line)
    except Exception: continue
    if "result" in j:
        print("  ", [t["name"] for t in j["result"].get("tools",[])])'

hdr "Abuse case: three identities call the fraud-check agent through the gateway"
call rebecca
call marcus
call tom.becker
echo
