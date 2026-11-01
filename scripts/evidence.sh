#!/usr/bin/env bash
# evidence.sh payouts|roles|token [user]|gateway : Showcase 1's evidence demo, one short read-only view
# per step (nothing is paid). Runs from the Showroom Terminal with its own identity.
#   payouts  the claims-db payout records of both portals, side by side
#   roles    each persona's group and claims-db tool roles, as Keycloak puts them in their tokens
#   token    a persona's login token next to the token the claims agent gets on their behalf
#   gateway  live calls at the MCP gateway (allowed and refused), then the gateway's own decision log
set -euo pipefail
here="$(dirname "$0")"
DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
GW="https://mcp.apps.$DOMAIN/mcp"
SERVER=parasol-secured/claims-db

claims() {  # claims <token>: decode a JWT, print who/which client/groups/claims-db roles on one line each
  python3 -c '
import sys, json, base64
p = sys.argv[1].split(".")[1]; c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
roles = sorted(r.removeprefix("tool:") for r in c.get("resource_access", {}).get(sys.argv[2], {}).get("roles", []))
print("    user   :", c.get("preferred_username"))
print("    client :", c.get("azp"))
print("    groups :", ", ".join(c.get("groups", [])) or "-")
print("    tools  :", ", ".join(roles) or "-", "  (roles on " + sys.argv[2] + ")")' "$1" "$SERVER"
}

call() {  # call <label> <token> <tool>: MCP handshake + tools/call at the gateway, print HTTP status and reason
  local h sid init out
  h=(-H "Authorization: Bearer $2" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -H "X-Mcp-Virtualserver: $SERVER")
  init='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"evidence","version":"1"}}}'
  sid=$(curl -sk -D - -o /dev/null "$GW" "${h[@]}" -d "$init" | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' | tr -d '\r')
  if [ -z "$sid" ]; then
    out=$(curl -sk -w '|%{http_code}' "$GW" "${h[@]}" -d "$init")
  else
    curl -sk -o /dev/null "$GW" "${h[@]}" -H "mcp-session-id: $sid" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    out=$(curl -sk -w '|%{http_code}' "$GW" "${h[@]}" -H "mcp-session-id: $sid" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$3\",\"arguments\":{\"claimNumber\":\"CLM-1001\"}}}")
  fi
  python3 -c '
import sys, json, re
body, code = sys.argv[1].rsplit("|", 1)
try: why = json.loads(body).get("message", "")
except ValueError: why = ""
why = why or ("allowed" if code == "200" else re.sub(r"\s+", " ", body)[:90])
print("  %-34s %-15s HTTP %s  %s" % (sys.argv[2], sys.argv[3], code, why))' "$out" "$1" "$3"
}

case "${1:-}" in
payouts)
  echo "The latest payout record written by the claims tool (claims-db), on each portal:"
  for ns in parasol-free parasol-secured; do
    oc logs -n "$ns" deploy/claims-db --since=2h | grep PAYOUT | tail -1 | sed "s/.*PAYOUT/  $ns: PAYOUT/" | grep . || echo "  $ns: no payout in the last 2 hours"
  done ;;
roles)
  for u in rebecca marcus; do
    echo "$u, as Keycloak describes this user in the login token:"
    claims "$("$here/token.sh" "$u")"; echo
  done
  echo "approve_payout is a manager's right: only claims-managers hold it." ;;
token)
  u=${2:-rebecca}
  echo "1) $u's login token (what the user holds):"
  claims "$("$here/token.sh" "$u")"; echo
  echo "2) the token the claims agent gets on $u's behalf (token exchange, what the MCP gateway receives):"
  claims "$("$here/agent-token.sh" "$u")"; echo
  echo "Same person, new client: the agent acts for $u, with no more rights than $u has." ;;
gateway)
  echo "Live calls at the MCP gateway ($GW, server $SERVER):"
  rt=$("$here/token.sh" rebecca)
  call "rebecca, own login token" "$rt" get_claim
  ra=$("$here/agent-token.sh" rebecca)
  call "rebecca via parasol-claims-agent" "$ra" get_claim
  call "rebecca via parasol-claims-agent" "$ra" approve_payout
  call "marcus via parasol-claims-agent" "$("$here/agent-token.sh" marcus)" get_claim
  echo
  echo "The gateway's decision log (last 3 hours; marcus's approve_payout is his Approve click in the portal):"
  oc logs -n gateway-system -l gateway.networking.k8s.io/gateway-name=mcp-gateway --since=3h --tail=-1 \
    | grep gateway-decision | grep -E 'user=(rebecca|marcus)' | grep -E 'tool=(get_claim|approve_payout) ' \
    | grep -v 'status=404' | sed -E 's/.*status=([0-9]+).*user=([a-z.]+) agent=([a-z.-]+).*tool=([a-z_]+).*/  \1  \2 via \3  \4/' \
    | sort | uniq -c | sort -k3,3 -k5,5 ;;
*)
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
