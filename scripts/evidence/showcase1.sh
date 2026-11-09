#!/usr/bin/env bash
# showcase1.sh <topic> : evidence of Showcase 1, the overstepping colleague (read-only; nothing is paid or changed)
#   payouts [claim]  the latest claims-db payout record of both portals, side by side (also Showcases 2, 7)
#   roles            rebecca's and marcus's groups and claims-db tool roles, from their Keycloak login tokens
#   token [user]     a persona's login token next to the token the claims agent gets on their behalf
#   gateway          live calls at the MCP gateway, allowed and refused, then the gateway's decision log
#   release          the audit trail: what runs in production (showcase5.sh release)
#   prompt           the audit trail: the released prompt against the running one (showcase6.sh prompt)
#   agenticops       the audit trail: the AgentOps checks on the agent's turns (showcase4.sh agenticops)
. "$(dirname "$0")/lib.sh"

call() {  # call <label> <token expression> <tool>: one tools/call at the gateway as <label>
  local out
  out=$(run "scripts/evidence/mcp-call.sh $GW $2 $SERVER $3 '{\"claimNumber\":\"CLM-1001\"}'")
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
  c=${2:-}
  title "The latest ${c:+$c }payout record written by the claims tool (claims-db), on each portal"
  for ns in parasol-free parasol-secured; do
    run "oc logs -n $ns deploy/claims-db --since=3h | grep PAYOUT | grep 'claim=${c}' | tail -1" | sed "s/.*PAYOUT/  $ns: PAYOUT/" | grep . \
      || echo "  $ns: no ${c:+$c }payout in the last 3 hours (nothing was written)"
  done ;;
roles)
  for u in rebecca marcus; do
    title "$u, as Keycloak describes this user in the login token"
    claims "$(run "scripts/token.sh $u")"
  done
  note "approve_payout is a manager's right: only claims-managers hold it." ;;
token)
  u=${2:-rebecca}
  title "1) $u's login token (what the user holds)"
  claims "$(run "scripts/token.sh $u")"
  title "2) the token the claims agent gets on $u's behalf (token exchange; what the MCP gateway receives)"
  claims "$(run "scripts/agent-token.sh $u")"
  note "Same person, new client: the agent acts for $u, with no more rights than $u has." ;;
gateway)
  title "Live calls at the MCP gateway ($SERVER)"
  call "rebecca, own login token" '$(scripts/token.sh rebecca)' get_claim
  call "rebecca via parasol-claims-agent" '$(scripts/agent-token.sh rebecca)' get_claim
  call "rebecca via parasol-claims-agent" '$(scripts/agent-token.sh rebecca)' approve_payout
  call "marcus via parasol-claims-agent" '$(scripts/agent-token.sh marcus)' get_claim
  title "The gateway's decision log (last 3 hours; marcus's approve_payout is his Approve click in the portal)"
  run "oc logs -n gateway-system -l gateway.networking.k8s.io/gateway-name=mcp-gateway --since=3h --tail=-1 | grep gateway-decision" \
    | grep -E 'user=(rebecca|marcus)' | grep -E 'tool=(get_claim|approve_payout) ' \
    | grep -v 'status=404' | sed -E 's/.*status=([0-9]+).*user=([a-z.]+) agent=([a-z.-]+).*tool=([a-z_]+).*/  \1  \2 via \3  \4/' \
    | sort | uniq -c | sort -k3,3 -k5,5 ;;
release) exec "$EV/showcase5.sh" release ;;
prompt) exec "$EV/showcase6.sh" prompt ;;
agenticops) exec "$EV/showcase4.sh" agenticops ;;
*) usage ;;
esac
