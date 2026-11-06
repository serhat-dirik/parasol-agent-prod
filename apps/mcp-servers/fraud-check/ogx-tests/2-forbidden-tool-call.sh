#!/usr/bin/env bash
# 2. A gateway refusal on tools/call must be ONE failed mcp_call, not a failed turn. Two refusals:
#  a) 403, per-tool authz. The gateway filters tools/list per identity, so a forbidden call needs a listing
#     made with wider rights: turn A lists claims-db as rebecca via the claims agent (4 tools); turn B continues
#     it (previous_response_id: OGX reuses A's listing) with rebecca's token re-exchanged by the fraud agent
#     (read-only ceiling) and asks for list_claims_by_status. Same path as a role or agent switched off
#     between two turns.
#  b) the MCP gateway guardrails block CLM-1004's document (normal use: the fraud-check case itself); the
#     gateway answers tools/call with HTTP 500 "guardrails blocked tool response".
# Expected (wanted):
#   a) turn B: mcp_call list_claims_by_status error=...403... / message ... / status: completed
#   b)         mcp_call get_claim_documents error=... / message ... / status: completed
# Recorded with OGX 1.2.5.1 (see RESULTS.md): both turns fail whole with HTTP 500 and no output. The MCP
# client (mcp 1.28.1, streamable HTTP) raises on any non-2xx POST; that cancels the session's task group and
# the CancelledError (a BaseException) passes OGX's `except Exception` around invoke_mcp_tool.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
narrow_tok="$(token rebecca fraud-agent)"
wide=$(mcp_tool claims-db claims-db "$(token rebecca claims-agent)")
narrow=$(mcp_tool claims-db claims-db "$narrow_tok")
reads=$(mcp_tool claims-db claims-db "$narrow_tok" '["get_claim","get_claim_documents","get_claim_history"]')
check() {  # check <label> <tool name> <http code> <body>
  echo "  HTTP $3"
  [ "$3" = 200 ] && printf '%s' "$4" | summary
  [ "$3" = 200 ] && printf '%s' "$4" | python3 -c 'import json,sys
r=json.load(sys.stdin)
calls=[o for o in r.get("output",[]) if o["type"]=="mcp_call" and o["name"]==sys.argv[1]]
sys.exit(0 if r.get("status")=="completed" and calls and all(c.get("error") for c in calls) else 1)' "$2" \
    && pass "$1: per-call mcp_call error, response completed" || { echo "FAIL  $1: the whole turn failed"; rc=1; }
}
rc=0
post() { curl -s -w '\n%{http_code}' "$OGX/v1/responses" -H 'content-type: application/json' -d "$1"; }

a=$(post "{\"model\":\"$MODEL\",\"store\":true,\"input\":\"What is the status of claim CLM-1004? /no_think\",\"tools\":[$wide]}")
echo "a) turn A (rebecca via claims agent):"; printf '%s' "${a%$'\n'*}" | summary
aid=$(printf '%s' "${a%$'\n'*}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
b=$(post "{\"model\":\"$MODEL\",\"store\":true,\"previous_response_id\":\"$aid\",\"tools\":[$narrow],
  \"input\":\"Now call list_claims_by_status with status Submitted and tell me what it returned. /no_think\"}")
echo "a) turn B (rebecca via fraud agent, read-only ceiling):"
check "403 on tools/call" list_claims_by_status "${b##*$'\n'}" "${b%$'\n'*}"

c=$(post "{\"model\":\"$MODEL\",\"store\":true,\"tools\":[$reads],
  \"input\":\"Read the documents uploaded to claim CLM-1004 with get_claim_documents and summarise them. /no_think\"}")
echo "b) guardrails block CLM-1004's document (rebecca via fraud agent):"
check "guardrails refusal on tools/call" get_claim_documents "${c##*$'\n'}" "${c%$'\n'*}"
exit $rc
