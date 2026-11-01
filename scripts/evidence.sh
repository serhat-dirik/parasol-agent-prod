#!/usr/bin/env bash
# evidence.sh <command> : the evidence demos of Showcases 1 to 3, one short read-only view per step
# (nothing is paid or changed). Runs from the Showroom Terminal with its own identity.
#   payouts [claim]  the latest claims-db payout record of both portals, side by side       (1, 2)
#   roles            each persona's group and claims-db tool roles, from their Keycloak tokens (1)
#   token [user]     a persona's login token next to the token the claims agent gets for them (1)
#   gateway          live calls at the MCP gateway, allowed and refused, then its decision log (1)
#   guardrails       the guardrail rules and the tools any secured agent can be offered        (2)
#   flags            the guardrail decisions, with user, agent and trace id                    (2)
#   search [question] one knowledge-base search, four identities: who gets what               (3)
#   kb-rule          which group may read which classification, and each persona's groups    (3)
#   rls              the database's row-level policy, and a claim record read as two people   (3)
#   kb-audit         the knowledge-base and claims-db access records                           (3)
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

mcp() {  # mcp <url> <token|-> <server> <tool> <json args>: MCP handshake + tools/call, prints "<body>|<http code>"
  local h sid init
  h=(-H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -H "X-Mcp-Virtualserver: $3")
  [ "$2" = - ] || h+=(-H "Authorization: Bearer $2")
  init='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"evidence","version":"1"}}}'
  local hdrs; hdrs=$(curl -sk -D - -o /dev/null "$1" "${h[@]}" -d "$init")
  # refused at the handshake already (not via an approved agent): that refusal is the answer
  head -1 <<<"$hdrs" | grep -q ' 200' || { curl -sk -w '|%{http_code}' "$1" "${h[@]}" -d "$init"; return; }
  sid=$(awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' <<<"$hdrs" | tr -d '\r')
  [ -z "$sid" ] || h+=(-H "mcp-session-id: $sid")   # a stateless server (the unsecured one) issues none
  curl -sk -o /dev/null "$1" "${h[@]}" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  curl -sk -w '|%{http_code}' "$1" "${h[@]}" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$4\",\"arguments\":$5}}"
}

text() {  # text <mcp output>: the tool's text answer (first content item)
  python3 -c '
import sys, json
body = sys.argv[1].rsplit("|", 1)[0]
body = body.split("data: ", 1)[-1] if body.startswith(("event:", "data:")) else body
print(json.loads(body)["result"]["content"][0]["text"])' "$1"
}

call() {  # call <label> <token> <tool>: a tools/call at the gateway as <label>, print HTTP status and reason
  local out
  out=$(mcp "$GW" "$2" "$SERVER" "$3" '{"claimNumber":"CLM-1001"}')
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
  echo "The latest ${c:+$c }payout record written by the claims tool (claims-db), on each portal:"
  for ns in parasol-free parasol-secured; do
    oc logs -n "$ns" deploy/claims-db --since=3h | grep PAYOUT | grep "claim=${c}" | tail -1 | sed "s/.*PAYOUT/  $ns: PAYOUT/" | grep . \
      || echo "  $ns: no ${c:+$c }payout in the last 3 hours (nothing was written)"
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
guardrails)
  rules() { oc get cm guardrails-rules -n parasol-secured -o jsonpath="{.data.$1}"; }
  echo "Guardrail rules on every model call of the secured assistant (ConfigMap guardrails-rules, parasol-secured):"
  echo "  an instruction addressed to the assistant inside a DOCUMENT (a tool result) -> flag: banner, turn continues"
  echo "  the same instruction in the USER's own message                             -> block: nothing reaches the model"
  echo "  an off-topic request (essays, poems)                                        -> block, 0 model tokens"
  echo "  personal data in the user's message                                         -> mask before the model sees it"
  echo "  a link or image in an ANSWER to a host outside the allow-list               -> redact"
  echo
  echo "  instruction phrases (detectors.json): $(rules 'detectors\.json' | python3 -c 'import sys,json; print(", ".join(p.removeprefix("(?i)") for p in json.load(sys.stdin)["regex"]["regex"]))')"
  echo "  link allow-list (links.json):         $(rules 'links\.json' | python3 -c 'import sys,json; print(", ".join(json.load(sys.stdin)["external-link"]["allow_domains"]))')"
  echo
  echo "Tools any agent in parasol-secured can be offered (MCPVirtualServer): no approve_payout, so a model can only propose:"
  oc get mcpvirtualserver -n parasol-secured -o jsonpath='{range .items[*]}{"  "}{.metadata.name}{": "}{.spec.tools}{"\n"}{end}' | tr -d '[]"' | sed 's/,/, /g'
  echo "  (portal, its own tool): propose_payout, which writes nothing; a claims manager's Approve click makes the payment" ;;
flags)
  echo "Guardrail decisions in the last 3 hours (deploy/guardrails-proxy, parasol-secured):"
  oc logs -n parasol-secured deploy/guardrails-proxy --since=3h | grep 'guardrail action=' \
    | sed -E "s/.*action=([a-z]+) detector=([a-z-]+) score=([0-9.]+) user=([^ ]+) agent=([^ ]+) trace=([0-9a-f]+) text=(.*)/  \1  \2  \4 via \5  trace=\6  \7/" \
    | awk '!seen[$0]++' | tail -8 | grep . || echo "  none in the last 3 hours" ;;
search)
  q=${2:-What is the 2026 restructuring plan for adjuster roles?}
  echo "One knowledge-base search, four identities: \"$q\""
  row() {  # row <label> <mcp output>
    python3 -c '
import sys, json
body = sys.argv[2].rsplit("|", 1)[0]
r = json.loads(json.loads(body)["result"]["content"][0]["text"])
docs = sorted({"%s (%s)" % (p["doc_id"], p["classification"]) for p in r.get("passages", [])})
w = r.get("withheld") or {}
held = ", ".join("%s %s" % (n, c) for c, n in (w.get("classifications") or {}).items()) or "-"
print("  %-30s gets: %-48s withheld: %s" % (sys.argv[1], ", ".join(docs) or "-", held))' "$1" "$2"
  }
  args=$(python3 -c 'import sys,json; print(json.dumps({"query": sys.argv[1]}))' "$q")
  row "unsecured portal (no check)" "$(mcp http://knowledge-base.parasol-free.svc:8080/mcp - - search_knowledge "$args")"
  for u in rebecca marcus nina.contractor; do
    row "$u via the agent" "$(mcp "$GW" "$("$here/agent-token.sh" "$u")" parasol-secured/knowledge-base search_knowledge "$args")"
  done
  echo "Withheld passages are counted, never returned: they do not reach the model." ;;
kb-rule)
  echo "Who may read which classification (the audience of every passage, knowledge-base database):"
  oc exec -n parasol-secured deploy/knowledge-base-db -- psql -U postgres -d kb -At -F '|' \
    -c 'select classification, array_to_string(audience, $$, $$), count(distinct doc_id) from chunks group by 1,2 order by 1' \
    | awk -F'|' '{printf "  %-11s %d documents, readable by: %s\n", $1, $3, $2}'
  echo
  echo "Each persona's groups, from the token the agent presents on their behalf:"
  for u in rebecca marcus nina.contractor; do
    printf '  %-16s %s\n' "$u" "$(python3 -c '
import sys, json, base64
p = sys.argv[1].split(".")[1]; print(", ".join(json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))).get("groups", [])))' "$("$here/agent-token.sh" "$u")")"
  done ;;
rls)
  echo "Row-level security on the knowledge base's table (knowledge-base-db, parasol-secured):"
  oc exec -n parasol-secured deploy/knowledge-base-db -- psql -U postgres -d kb -At \
    -c "select '  policy ' || policyname || ' for ' || cmd || ' to ' || array_to_string(roles, ',') || ': ' || qual from pg_policies"
  echo "  the server's own database user (kb_app), with no person's groups set:"
  oc exec -n parasol-secured deploy/knowledge-base-db -- psql -U postgres -d kb -At -c 'set role kb_app' \
    -c 'select count(*) from chunks' | grep -v '^SET' | sed 's/^/    rows visible: /'
  echo
  echo "The same rule for claim records: get_claim CLM-1029 (assigned to Angela Davis) through the gateway:"
  for u in rebecca marcus; do
    printf '  %-8s via the agent: %s\n' "$u" "$(text "$(mcp "$GW" "$("$here/agent-token.sh" "$u")" "$SERVER" get_claim '{"claimNumber":"CLM-1029"}')" | cut -c1-120)"
  done ;;
kb-audit)
  echo "Knowledge-base access records, last 3 hours (deploy/knowledge-base, parasol-secured):"
  oc logs -n parasol-secured deploy/knowledge-base --since=3h | grep -E 'RAG (restricted|withheld)' \
    | sed -E 's/^[0-9-]+ ([0-9:]+),[0-9]+ INFO /  \1 /' | tail -8 | grep . || echo "  none in the last 3 hours"
  echo
  echo "Claim-record refusals, last 3 hours (deploy/claims-db, parasol-secured):"
  oc logs -n parasol-secured deploy/claims-db --since=3h | grep 'CLAIMS ACL denied' | grep -v 'user=- ' \
    | sed -E 's/^[0-9-]+ ([0-9:]+),[0-9]+ .*CLAIMS ACL denied /  \1 /' | tail -6 | grep . || echo "  none in the last 3 hours" ;;
*)
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
