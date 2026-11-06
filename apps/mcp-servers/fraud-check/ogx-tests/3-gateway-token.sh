#!/usr/bin/env bash
# 3. The MCP gateway wants a token from the first message (initialize). OGX sends the MCP tool's
# `authorization` (bare token; OGX adds "Bearer") on initialize, tools/list and tools/call, and does not
# store it with the response.
# Expected:
#   without authorization: HTTP 401 (the gateway's 401 on initialize fails the whole turn: no tools, no answer)
#   with authorization:    mcp_list_tools claims-db [...3 tools] / mcp_call get_claim ok / message ... / status: completed
#   stored response carries no authorization: True
#   PASS  gateway token at initialize via `authorization`
set -uo pipefail
. "$(dirname "$0")/lib.sh"
allowed='["get_claim","get_claim_documents","get_claim_history"]'
none=$(mcp_tool claims-db claims-db "" "$allowed" | python3 -c 'import json,sys; t=json.load(sys.stdin); t.pop("authorization"); print(json.dumps(t))')
code=$(curl -s -o /dev/null -w '%{http_code}' "$OGX/v1/responses" -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"input\":\"Status of CLM-1004?\",\"tools\":[$none]}")
echo "without authorization: HTTP $code"
with=$(mcp_tool claims-db claims-db "$(token rebecca fraud-agent)" "$allowed")
r=$(curl -s "$OGX/v1/responses" -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"store\":true,\"input\":\"What is the status of claim CLM-1004? /no_think\",\"tools\":[$with]}")
echo "with authorization:"; printf '%s' "$r" | summary
id=$(printf '%s' "$r" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
stored=$(curl -s "$OGX/v1/responses/$id" | python3 -c 'import json,sys
r=json.load(sys.stdin); print(all(not t.get("authorization") for t in r.get("tools",[])) and "eyJ" not in json.dumps(r))')
echo "stored response carries no authorization: $stored"
printf '%s' "$r" | python3 -c 'import json,sys
r=json.load(sys.stdin); sys.exit(0 if r["status"]=="completed" and any(o["type"]=="mcp_call" and not o.get("error") for o in r["output"]) else 1)' \
  && [ "$code" != 200 ] && [ "$stored" = True ] && pass "gateway token at initialize via \`authorization\`" || fail "see above"
