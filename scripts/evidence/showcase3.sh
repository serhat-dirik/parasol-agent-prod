#!/usr/bin/env bash
# showcase3.sh <topic> : evidence of Showcase 3, the confidential document (read-only)
#   search [question]  one knowledge-base search, four identities: who gets what
#   kb-rule            which group may read which classification, and each persona's groups
#   rls                the database's row-level policy, and a claim record read as two people
#   kb-audit           the knowledge-base and claims-db access records
. "$(dirname "$0")/lib.sh"

row() {  # row <label> <mcp-call.sh output>
  python3 -c '
import sys, json
body = sys.argv[2].rsplit("|", 1)[0]
try: r = json.loads(json.loads(body)["result"]["content"][0]["text"])
except (ValueError, KeyError, IndexError):
    sys.exit(print("  %-30s no answer (%s); in-cluster services answer from the Showroom Terminal" % (sys.argv[1], body[:60] or "not reachable from here")))
docs = sorted({"%s (%s)" % (p["doc_id"], p["classification"]) for p in r.get("passages", [])})
w = r.get("withheld") or {}
held = ", ".join("%s %s" % (n, c) for c, n in (w.get("classifications") or {}).items()) or "-"
print("  %-30s gets: %-48s withheld: %s" % (sys.argv[1], ", ".join(docs) or "-", held))' "$1" "$2"
}
groups() { python3 -c '
import sys, json, base64
p = sys.argv[1].split(".")[1]; print(", ".join(json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))).get("groups", [])))' "$1"; }
PSQL="oc exec -n parasol-secured deploy/knowledge-base-db -- psql -U postgres -d kb -At"

case "${1:-}" in
search)
  q=${2:-What is the 2026 restructuring plan for adjuster roles?}
  args=$(python3 -c 'import sys,json; print(json.dumps({"query": sys.argv[1]}))' "$q")
  title "One knowledge-base search, four identities: \"$q\""
  row "unsecured portal (no check)" "$(run "scripts/evidence/mcp-call.sh http://knowledge-base.parasol-free.svc:8080/mcp - - search_knowledge '$args'")"
  for u in rebecca marcus nina.contractor; do
    row "$u via the agent" "$(run "scripts/evidence/mcp-call.sh $GW \$(scripts/agent-token.sh $u) parasol-secured/knowledge-base search_knowledge '$args'")"
  done
  note "Withheld passages are counted, never returned: they do not reach the model." ;;
kb-rule)
  title "Who may read which classification (the audience of every passage, knowledge-base database)"
  run "$PSQL -F '|' -c 'select classification, array_to_string(audience, \$\$, \$\$), count(distinct doc_id) from chunks group by 1,2 order by 1'" \
    | awk -F'|' '{printf "  %-11s %d documents, readable by: %s\n", $1, $3, $2}'
  title "Each persona's groups, from the token the agent presents on their behalf"
  for u in rebecca marcus nina.contractor; do
    printf '  %-16s %s\n' "$u" "$(groups "$(run "scripts/agent-token.sh $u")")"
  done ;;
rls)
  title "Row-level security on the knowledge base's table (knowledge-base-db, parasol-secured)"
  run "$PSQL -c \"select '  policy ' || policyname || ' for ' || cmd || ' to ' || array_to_string(roles, ',') || ': ' || qual from pg_policies\""
  title "The server's own database user (kb_app), with no person's groups set"
  run "$PSQL -c 'set role kb_app' -c 'select count(*) from chunks'" | grep -v '^SET' | sed 's/^/  rows visible: /'
  title "The same rule for claim records: get_claim CLM-1029 (assigned to Angela Davis) through the gateway"
  for u in rebecca marcus; do
    printf '  %-8s via the agent: %s\n' "$u" "$(text "$(run "scripts/evidence/mcp-call.sh $GW \$(scripts/agent-token.sh $u) $SERVER get_claim '{\"claimNumber\":\"CLM-1029\"}'")" | cut -c1-120)"
  done ;;
kb-audit)
  title "Knowledge-base access records, last 3 hours (deploy/knowledge-base, parasol-secured)"
  run "oc logs -n parasol-secured deploy/knowledge-base --since=3h | grep -E 'RAG (restricted|withheld)'" \
    | sed -E 's/^[0-9-]+ ([0-9:]+),[0-9]+ INFO /  \1 /' | tail -12 | grep . || echo "  none in the last 3 hours"
  title "Claim-record refusals, last 3 hours (deploy/claims-db, parasol-secured)"
  run "oc logs -n parasol-secured deploy/claims-db --since=3h | grep 'CLAIMS ACL denied' | grep -v 'user=- '" \
    | sed -E 's/^[0-9-]+ ([0-9:]+),[0-9]+ .*CLAIMS ACL denied /  \1 /' | tail -6 | grep . || echo "  none in the last 3 hours" ;;
*) usage ;;
esac
