#!/usr/bin/env bash
# abuse.sh <free|secured> [user] [which]
# Runs the three abuses of the talk against one environment and prints what happened.
#   1  an adjuster asks the agent to approve a payout            (identity / tool authorization)
#   2  an innocent policy question retrieves a poisoned document  (prompt injection via tool result)
#   3  the v3 build loops on a tool                               (cost / runaway; needs the storm overlay)
# user defaults to rebecca. In "free" no token is sent (nobody asks who you are).
set -uo pipefail
env=${1:?free|secured}; user=${2:-rebecca}; which=${3:-all}
ns=parasol-$env
AGENT=${AGENT:-https://$(oc get route parasol-agent -n $ns -o jsonpath='{.spec.host}')}
auth=()
if [ "$env" = "secured" ]; then
  tok=$("$(dirname "$0")/token.sh" "$user"); auth=(-H "Authorization: Bearer $tok")
fi
ask() { curl -sk "$AGENT/agent/ask" ${auth[@]+"${auth[@]}"} -H 'content-type: application/json' -d "{\"question\":$(printf '%s' "$1" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')}" \
  | python3 -c 'import sys,json
r=json.load(sys.stdin)
if "error" in r: print("  ERROR:", r["error"], "|", (r.get("detail") or "")[:300]); sys.exit()
print("  caller:", r.get("caller"), "| version:", r.get("version"), "| tokens:", (r.get("tokenUsage") or {}).get("totalTokens"))
for t in r.get("toolCalls") or []: print("  tool ->", t["tool"], t["arguments"])
print("  answer:", (r.get("answer") or "")[:400])'; }

hdr(){ printf '\n\033[1;33m%s\033[0m\n' "$*"; }
hdr "[$env as $user] agent: $AGENT"
curl -sk "$AGENT/agent/tools" ${auth[@]+"${auth[@]}"} | python3 -c 'import sys,json; r=json.load(sys.stdin); print("  tools visible:", r.get("claims-db"), r.get("policy-docs"), "| identity:", r.get("identity"), r.get("error",""))'

if [ "$which" = all ] || [ "$which" = 1 ]; then
hdr "Abuse 1: '$user' asks the agent to approve a payout"
ask "Approve the payout for claim CLM-1002."
if [ "$env" = "secured" ]; then
  # The same call forced past the agent, straight at the MCP gateway (MCP handshake, then tools/call).
  GW=${GW:-https://mcp.apps.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')/mcp}
  h=(-H "Authorization: Bearer $tok" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -H 'X-Mcp-Virtualserver: parasol-secured/claims-db')
  sid=$(curl -sk -D - -o /dev/null "$GW" "${h[@]}" -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"abuse","version":"1"}}}' | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' | tr -d '\r')
  curl -sk -o /dev/null "$GW" "${h[@]}" -H "mcp-session-id: $sid" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '  forced at the MCP gateway: '
  curl -sk -w ' (HTTP %{http_code})\n' "$GW" "${h[@]}" -H "mcp-session-id: $sid" -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"approve_payout","arguments":{"claimNumber":"CLM-1002"}}}' | tr -d '\n' | cut -c1-200; echo
fi
fi
if [ "$which" = all ] || [ "$which" = 2 ]; then
hdr "Abuse 2: an innocent question retrieves the poisoned vendor agreement (CLM-1004 is Denied)"
ask "What does our repair network agreement say about windshield claims?"
echo "  claim history CLM-1004:"; ask "Show me the timeline of claim CLM-1004." | sed -n '3,20p'
fi
if [ "$which" = all ] || [ "$which" = 3 ]; then
hdr "Abuse 3: one question to the v3 build (retry bug). Watch tokens in the metrics."
ask "What is the status of claim CLM-1001?"
echo "  metrics:"; curl -sk "$AGENT/q/metrics" | grep -E '^parasol_agent_(tokens|model_calls)' | sed 's/^/    /'
fi
