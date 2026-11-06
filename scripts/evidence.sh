#!/usr/bin/env bash
# evidence.sh <command> : the evidence demos of Showcases 1 to 8, one short read-only view per step
# (nothing is paid or changed). Runs from the Showroom Terminal with its own identity.
#   payouts [claim]  the latest claims-db payout record of both portals, side by side       (1, 2)
#   roles            each persona's group and claims-db tool roles, from their Keycloak tokens (1)
#   token [user]     a persona's login token next to the token the claims agent gets for them (1)
#   gateway          live calls at the MCP gateway, allowed and refused, then its decision log (1)
#   guardrails       the NeMo rules, where they run, gateway blocks, the tools an agent is offered (2)
#   flags            the guardrail decisions, with user, agent and trace id                    (2)
#   search [question] one knowledge-base search, four identities: who gets what               (3)
#   kb-rule          which group may read which classification, and each persona's groups    (3)
#   rls              the database's row-level policy, and a claim record read as two people   (3)
#   kb-audit         the knowledge-base and claims-db access records                           (3)
#   spend            model tokens and refusals per user and agent, from the secured portal     (4)
#   tiers            the MaaS subscriptions: who may use which model, with which token budget  (4, 5)
#   gate             both release runs: the evaluation verdict, the score, promoted or not    (5)
#   prompt           the prompt the release pinned against the prompt the portal runs          (5, 7)
#   tools            which MCP servers the secured agent can reach, and which it cannot        (6)
#   scan             the tool scanner's latest verdict per server: pinned, drifted, flagged     (6)
#   release          what runs in production: release run, Argo CD pin, running pod, admission (7, 8)
#   agenticops       the latest AgenticOps checks on the agent turns in MLflow                (7)
#   models           the model path of each portal and what it can reach                       (8)
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
  rails() {  # rails <configmap>: the rail names of one NeMo config, one line
    oc get cm "$1" -n parasol-secured -o jsonpath='{.data.config\.yaml}' 2>/dev/null \
      | sed -n 's/^ *- \(parasol [a-z ]*[a-z]\).*/\1/p' | paste -sd, - | sed 's/,/, /g'; }
  echo "Guardrails run in NeMo Guardrails (NemoGuardrails parasol-nemo, parasol-secured); two configs, one rules file:"
  echo "  parasol-tool-results  run by the MCP GATEWAY on every claims-db tool result -> block: the agent gets"
  echo "                        a refusal (HTTP 500; red chip \"refused by the MCP gateway\") and never reads the document"
  echo "      rails: $(rails nemo-parasol-tool-results || echo '?')"
  echo "  parasol-chat          run by the guardrails proxy on the secured assistant's model path"
  echo "      user input:  injection phrases -> block; off-topic -> block; personal data -> mask"
  echo "      answers:     confidential marker (not claims-managers) -> block; external links -> redact"
  echo "      rails: $(rails nemo-parasol-chat || echo '?')"
  echo
  echo "Wiring at the MCP gateway (mcp-system):"
  echo "  MCPGatewayExtension guardrails-ref:  $(oc get mcpgatewayextension -n mcp-system -o jsonpath='{.items[0].metadata.annotations.mcp\.kuadrant\.io/guardrails-ref}' 2>/dev/null || echo '(not readable)')"
  echo "  claims-db guardrails-config-ids:     $(oc get mcpserverregistration -n parasol-secured claims-db -o jsonpath='{.metadata.annotations.mcp\.kuadrant\.io/guardrails-config-ids}' 2>/dev/null || echo '(not readable)')"
  echo "  NeMo pods ready:                     $(oc get deploy parasol-nemo -n parasol-secured -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo '?')"
  echo
  echo "Tool results the gateway blocked (last 3 hours):"
  { oc logs -n mcp-system deploy/mcp-gateway --since=3h 2>/dev/null || true; } | grep 'guardrails blocked' \
    | sed -E 's/.*msg="?([^"]*)"? .*tool=([a-z_]+).*reason="?([^"]*)"?.*/  \2  \1  (\3)/' | tail -5 | grep . || echo "  none"
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
    | sed -E 's/^[0-9-]+ ([0-9:]+),[0-9]+ INFO /  \1 /' | tail -12 | grep . || echo "  none in the last 3 hours"
  echo
  echo "Claim-record refusals, last 3 hours (deploy/claims-db, parasol-secured):"
  oc logs -n parasol-secured deploy/claims-db --since=3h | grep 'CLAIMS ACL denied' | grep -v 'user=- ' \
    | sed -E 's/^[0-9-]+ ([0-9:]+),[0-9]+ .*CLAIMS ACL denied /  \1 /' | tail -6 | grep . || echo "  none in the last 3 hours" ;;
spend)
  echo "Model spend and refusals per user and agent (the secured portal's own counters, since its pod started):"
  oc exec -n parasol-secured deploy/portal -- curl -s localhost:8080/q/metrics | python3 -c '
import sys, re, collections
tok, rej = collections.Counter(), collections.Counter()
for l in sys.stdin:
    m = re.match(r"parasol_agent_(tokens|rejections)_total\{([^}]*)\} ([0-9.eE+]+)", l)
    if not m: continue
    lb = dict(re.findall(r"(\w+)=\"([^\"]*)\"", m.group(2)))
    who = "%s via %s" % (lb.get("user"), lb.get("agent"))
    if m.group(1) == "tokens": tok[who] += float(m.group(3))
    else: rej[(who, lb.get("reason"))] += float(m.group(3))
print("  tokens:")
for who, n in tok.most_common(): print("    %-42s %8d" % (who, n))
print("  refused by the platform:")
for (who, why), n in sorted(rej.items()): print("    %-42s %-16s %d" % (who, why, n))
if not rej: print("    none")'
  echo "usage_limit = the MaaS token budget of the user's tier answered 429; the model was not called." ;;
tiers)
  echo "MaaS subscriptions (models-as-a-service): who may use which model, with which token budget:"
  oc get maassubscription -n models-as-a-service -o json | python3 -c '
import sys, json
for s in json.load(sys.stdin)["items"]:
    sp, an = s["spec"], s["metadata"].get("annotations", {})
    owners = ", ".join(g["name"] for g in sp.get("owner", {}).get("groups", []))
    off = "  SWITCHED OFF (kill switch)" if "parasol.example/kill-switch-owner" in an else ""
    print("  %-20s owners: %s%s" % (s["metadata"]["name"], owners, off))
    for m in sp.get("modelRefs", []):
        lim = ", ".join("%s tokens / %s" % (r["limit"], r["window"]) for r in m.get("tokenRateLimits", [])) or "no token limit"
        print("  %-20s   %-26s %s" % ("", m["name"], lim))' ;;
gate)
  echo "The two release runs (parasol-build), from each run's own results:"
  for c in production candidate-shortened; do
    oc get pipelinerun "parasol-portal-release-$c" -n parasol-build -o json | python3 -c '
import sys, json
p = json.load(sys.stdin); r = {x["name"]: x["value"] for x in p.get("status", {}).get("results", [])}
sk = [t["name"] for t in p.get("status", {}).get("skippedTasks", [])]
print("  %-20s gate=%-6s score=%-5s promote=%-7s image=%s promoted=%s mlflow_run=%s" % (sys.argv[1], r.get("EVAL_GATE", "?"),
      r.get("EVAL_SCORE", "?"), "skipped" if "promote" in sk else "ran", r.get("IMAGE_DIGEST", "-")[7:19],
      r.get("PROMOTED_DIGEST", "-")[7:19] or "-", r.get("MLFLOW_RUN_ID", "-")[:12]))' "$c" \
      || echo "  $c: no run (scripts/pipeline-runs.sh starts it)"
  done
  g="$here/../gitops/platform/eval/mlflow-agent-eval/golden-set.json"
  [ -f "$g" ] && python3 -c 'import sys, json; d = json.load(open(sys.argv[1]))
print("The bar (golden set in Git): %d cases, pass at least %.2f with the platform." % (len(d["cases"]), d["gate_threshold"]))' "$g"
  echo "The evaluation's own MaaS subscription (agent model, and the judge model when it is listed):"
  oc get maassubscription parasol-eval -n models-as-a-service -o jsonpath='{range .spec.modelRefs[*]}{"  "}{.name}{"\n"}{end}' 2>/dev/null \
    || echo "  (not readable here: OpenShift AI, Settings, MaaS governance)" ;;
prompt)
  echo "The prompt the release pinned (Argo CD Application env-secured) and the prompt the secured portal runs:"
  pin=$(oc get application env-secured -n openshift-gitops -o json | python3 -c '
import sys, json; a = json.load(sys.stdin)["metadata"]["annotations"]
print(a.get("parasol.example/prompt-version", "-"), a.get("parasol.example/prompt-sha256", "-"))')
  run=$(oc get cm agent-prompt-release -n parasol-secured -o json | python3 -c '
import sys, json, hashlib; d = json.load(sys.stdin)["data"]
print(d.get("promptVersion", "-"), hashlib.sha256(d.get("systemPrompt", "").encode()).hexdigest())')
  echo "  pinned by the release:  $pin"
  echo "  running (agent-prompt-release): $run"
  [ "${pin#* }" = "${run#* }" ] && echo "  same sha256: the portal runs exactly the text the gate evaluated." \
    || echo "  DIFFERENT: the running prompt is not the released one." ;;
tools)
  echo "MCP servers the gateway federates for the secured agent (MCPServerRegistration, parasol-secured):"
  oc get mcpserverregistration -n parasol-secured | sed 's/^/  /'
  oc get mcpserverregistration currency-converter -n parasol-secured >/dev/null 2>&1 \
    && echo "  currency-converter IS registered (reviewed change switched on)" || echo "  currency-converter: not registered"
  echo
  echo "Can a portal reach the vendor's server directly (currency-converter.parasol-thirdparty)?"
  for ns in parasol-secured parasol-free; do
    oc exec -n "$ns" deploy/portal -- timeout 5 bash -c '</dev/tcp/currency-converter.parasol-thirdparty.svc/8080' 2>/dev/null \
      && echo "  $ns: reachable" || echo "  $ns: blocked"
  done ;;
scan)
  echo "The tool scanner's latest verdict per MCP server (mcp-system/mcp-tool-scanner):"
  # the scanner logs only changes: replay its log to the current state per server
  oc logs -n mcp-system deploy/mcp-tool-scanner --tail=-1 2>/dev/null | python3 -c '
import sys, re
last, flags = {}, {}
for l in sys.stdin:
    m = re.search(r"tool-scan action=(\w+) server=(\S+) registered=(\S+)(.*)", l)
    if not m: continue
    act, srv, reg, rest = m.groups(); kv = dict(re.findall(r"(\w+)=(\x27[^\x27]*\x27|\S+)", rest))
    if act == "scanned":
        last[srv] = "registered=%s version=%s pin=%s" % (reg, kv.get("version"), kv.get("pin"))
    elif act == "drift":
        last[srv] = "registered=%s version=%s DRIFT pinned=%s current=%s" % (reg, kv.get("version"), kv.get("pinned", "")[:8], kv.get("current", "")[:8])
    elif act == "flag":
        flags[(srv, kv.get("tool"), kv.get("rule"))] = 1
    elif act == "cleared":
        flags.pop((srv, kv.get("tool"), kv.get("rule")), None)
for s in sorted(last): print("  %-40s %s" % (s, last[s]))
print("Descriptions with instructions for the assistant (open findings, the guardrails rules):")
for s, t, r in sorted(flags): print("  %-40s %-18s %s" % (s, t, r))
if not flags: print("  none")' ;;
release)
  echo "1) The release run parasol-portal-release-production (parasol-build), its results:"
  oc get pipelinerun parasol-portal-release-production -n parasol-build -o json | python3 -c '
import sys, json
r = {x["name"]: x["value"] for x in json.load(sys.stdin).get("status", {}).get("results", [])}
for k in ("EVAL_GATE", "EVAL_SCORE", "SIGNED_IMAGES", "KEYLESS_SIGNED_IMAGES", "PROMOTED_DIGEST"): print("  %-22s %s" % (k, r.get(k, "-")))'
  echo "2) The pin on Argo CD Application env-secured:"
  oc get application env-secured -n openshift-gitops -o json | python3 -c '
import sys, json; a = json.load(sys.stdin)["metadata"]["annotations"]
for k in ("promoted-digest", "promoted-by", "prompt-version", "model-ref"): print("  %-22s %s" % (k, a.get("parasol.example/" + k, "-")))'
  echo "3) The running secured portal:"
  echo "  $(oc get pods -n parasol-secured -l app=portal -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' | sed 's/.*@/image                  /')"
  echo "4) Admission: namespace parasol-secured policy.rhtas.com/include=$(oc get ns parasol-secured -o jsonpath='{.metadata.labels.policy\.rhtas\.com/include}')"
  oc get clusterimagepolicies.policy.sigstore.dev parasol-portal-must-be-signed -o json | python3 -c '
import sys, json; s = json.load(sys.stdin)["spec"]
print("  ClusterImagePolicy parasol-portal-must-be-signed: images %s, accepted signers %s" % (
      ", ".join(i["glob"].rsplit("/", 1)[-1] for i in s["images"]), ", ".join(a["name"] for a in s["authorities"])))' ;;
agenticops)
  echo "AgenticOps (CronJob agenticops, observability, every 10 minutes): the checks on new agent turns, last runs:"
  pods=$(oc get pods -n observability -o name --sort-by=.metadata.creationTimestamp 2>/dev/null | grep '/agenticops-' | tail -3 || true)
  [ -n "$pods" ] || { echo "  no run found (not readable here, or not deployed: MLflow tab, a trace, Assessments)"; exit 0; }
  for p in $pods; do oc logs -n observability "$p" 2>/dev/null; done \
    | grep -E 'flagged=|checked ' | grep -v 'flagged=none' | tail -8 | sed 's/^/  /'
  echo "Each turn gets loop, excess_steps, unknown_tool, pii_in_tool_args; a sample also goal_achieved (the judge model through MaaS)." ;;
models)
  echo "The model endpoint each portal calls (ConfigMap agent-config, key endpoint):"
  for ns in parasol-free parasol-secured; do
    echo "  $ns: $(oc get cm agent-config -n "$ns" -o jsonpath='{.data.endpoint}')"
  done
  echo "What each portal pod can reach (HTTP code; 000 = the connection never left the namespace):"
  for ns in parasol-free parasol-secured; do
    for u in https://api.openai.com/v1/models "https://maas.apps.$DOMAIN/v1/models"; do
      printf '  %-16s %-24s %s\n' "$ns" "$(cut -d/ -f3 <<<"$u" | cut -d. -f1-2)" \
        "$(oc exec -n "$ns" deploy/portal -- curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$u" 2>/dev/null || true)"
    done
  done ;;
*)
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 1 ;;
esac
