#!/usr/bin/env bash
# incident-report.sh <claim> : one payout on the secured portal, reconstructed from the platform's own records.
# Read-only: it only reads (claims-db timeline and log, MLflow traces, Keycloak events, the MCP gateway's decision log,
# the Argo CD Application env-secured, the MLflow agent version, the release PipelineRun and the running pod).
# Each section prints "n/a: <why>" when this identity may not read that source.
#   scripts/incident-report.sh CLM-1001
# Full report: a workstation with `oc` signed in as an administrator (MLflow takes the
# oc token; Keycloak events need the Keycloak admin, scripts/keycloak-admin.sh). From the Showroom Terminal
# the cluster sections run; MLflow and Keycloak are then read in their browser tabs.
set -uo pipefail
claim=${1:?usage: scripts/incident-report.sh <claim number, e.g. CLM-1001>}
cd "$(dirname "$0")/.."
NS=parasol-secured
D=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
TOK=$(oc whoami -t 2>/dev/null || true)
hdr() { printf '\n== %s\n' "$*"; }
na() { echo "  n/a: $*"; }

hdr "1. The claim: timeline and the write (claims-db, $NS)"
# claims-db answers record reads only for a verified user token: read as a claims manager (marcus, via the agent)
MGR=$(scripts/agent-token.sh marcus 2>/dev/null || true)
hist=$(oc exec -n $NS deploy/claims-db -- curl -s -H "Authorization: Bearer $MGR" "localhost:8080/api/claims/$claim/history" 2>/dev/null) || hist=""
if [ -n "$hist" ]; then
  printf '%s' "$hist" | python3 -c 'import sys,json
for e in json.load(sys.stdin): print("  %s  %-16s %s" % (e["createdAt"], e["eventType"], e["note"]))'
else na "cannot exec into claims-db"; fi
# two-stage approval: who approved the claim ("Claim approved for USD <n> by rebecca via parasol-claims-agent") and who
# released the payment ("Payment released by marcus via parasol-claims-agent"), from the events their tokens wrote
by() { printf '%s' "$hist" | python3 -c 'import sys,json,re
try: n=[x["note"] for x in json.load(sys.stdin) if x["eventType"]==sys.argv[1]][-1]; m=re.search(sys.argv[2], n); print(m.group(1) if m else "")
except Exception: print("")' "$1" "$2" 2>/dev/null; }
who=$(by ClaimApproved 'by (\S+) via') rel=$(by Approved 'Payment released by (\S+)')
[ -n "$rel" ] || echo "  no 'Payment released by <user> via <agent>' event yet: approve the claim and release the payment first (see Before you start)"
# the payment's time: section 4 reads the gateway's decisions in the 15 minutes up to it (approval and release)
appr=$(printf '%s' "$hist" | python3 -c 'import sys,json
try: e=[x for x in json.load(sys.stdin) if x["eventType"]=="Approved" and "Payment released by" in x["note"]]; print(e[-1]["createdAt"] if e else "")
except Exception: print("")' 2>/dev/null)
oc logs -n $NS deploy/claims-db --tail=2000 2>/dev/null | grep -E "(CLAIM APPROVED|PAYMENT RELEASED) claim=$claim" | tail -3 | sed 's/^/  log: /'

hdr "2. The conversation and the approval (MLflow, workspace $NS, experiment parasol-portal-chat)"
mlf() { curl -sk -m 20 -H "Authorization: Bearer $TOK" -H "x-mlflow-workspace: $NS" "https://rh-ai.apps.$D/mlflow/$1"; }
if [ -n "$TOK" ] && mlf "api/2.0/mlflow/traces?experiment_ids=1&max_results=1" | grep -q '"request_id"'; then   # readable = traces come back
  MLF_TOKEN=$TOK MLF_BASE="https://rh-ai.apps.$D/mlflow" CLAIM=$claim WHO="$who" python3 - <<'PY'
import json, os, ssl, urllib.parse, urllib.request
ctx = ssl._create_unverified_context()
H = {"Authorization": "Bearer " + os.environ["MLF_TOKEN"], "x-mlflow-workspace": "parasol-secured"}
base, claim, who = os.environ["MLF_BASE"], os.environ["CLAIM"], os.environ.get("WHO") or None
def get(path):
    return json.load(urllib.request.urlopen(urllib.request.Request(base + "/" + path, headers=H), timeout=30, context=ctx))
def tags(t):
    return {x["key"]: x["value"] for x in t.get("tags", [])}
def spans(tid):
    return get("ajax-api/3.0/mlflow/traces/get?trace_id=" + tid)["trace"]["spans"]
def attrs(s):   # [{key, value: {string_value|int_value|double_value: v}}] -> {key: v}
    return {a["key"]: next(iter((a.get("value") or {None: None}).values())) for a in s.get("attributes", [])}
q = "api/2.0/mlflow/traces?experiment_ids=1&max_results=5&order_by=" + urllib.parse.quote("timestamp_ms DESC")
appr = get(q + "&filter=" + urllib.parse.quote(f"tags.action = 'release_payment {claim}'")).get("traces", [])
if appr:
    a = appr[0]; t = tags(a)
    user = next((x for x in [attrs(sp).get("enduser.id") for sp in spans(a["request_id"])] if x), "?")
    print(f"  payment    {a['request_id']}  user={user} agent={t.get('agent')} action='{t.get('action')}'")
else:
    print(f"  payment    no trace with tag action='release_payment {claim}' (released outside the portal's Release payment button?)")
# the chat turn that approved the claim: latest claims-agent traces with an approve_claim tool call for this claim
def approves(s):
    a = attrs(s)
    return "approve_claim" in (a.get("gen_ai.tool.name"), a.get("tool.name"), s.get("name", "").removeprefix("tool.")) \
        and claim in json.dumps(s)
for tr in get(q.replace("max_results=5", "max_results=60") + "&filter=" + urllib.parse.quote("tags.agent = 'parasol-claims-agent'")).get("traces", []):
    t = tags(tr)
    if "prompt" not in t:
        continue
    sp = spans(tr["request_id"])
    if not any(approves(s) for s in sp):
        continue
    root = attrs(next((s for s in sp if not s.get("parent_span_id")), sp[0]))
    if who and root.get("enduser.id") != who:   # the approver's own chat turn
        continue
    print(f"  approval   {tr['request_id']}  user={root.get('enduser.id')} agent={t.get('agent')} model={t.get('model')}")
    print(f"             prompt={t.get('prompt')} prompt_sha256={t.get('prompt_sha256', 'n/a')}")
    names = [s["name"] for s in sp if s["name"].startswith(("tool.", "guardrails.", "agent."))]
    print("             spans: " + " > ".join(dict.fromkeys(names)))
    for s in sp:
        if s["name"].startswith("guardrails."):
            a = attrs(s); print(f"             {s['name']}: action={a.get('guardrail.action')} detectors={a.get('guardrail.detectors')} score={a.get('guardrail.score')}")
    print(f"             open: {base}/#/experiments/1/traces?selectedEvaluationId={tr['request_id']}&workspace=parasol-secured")
    break
else:
    print(f"  approval   no chat turn by {who or 'anyone'} approving {claim} among the last 60 claims-agent traces")
PY
else na "MLflow API not readable with this identity (open the MLflow tab, Traces, filter tags.action = 'release_payment $claim')"; fi

hdr "3. Who acted for whom (Keycloak, realm parasol, events TOKEN_EXCHANGE)"
if (. scripts/keycloak-admin.sh) >/dev/null 2>&1; then
  ( . scripts/keycloak-admin.sh
    KC=https://sso.apps.$D
    at=$(curl -sk "$KC/realms/master/protocol/openid-connect/token" -d grant_type=password -d client_id=admin-cli \
      --data-urlencode "username=$KC_USER" --data-urlencode "password=$KC_PASS" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))')
    curl -sk -H "Authorization: Bearer $at" "$KC/admin/realms/parasol/events?type=TOKEN_EXCHANGE&max=500" | WHO="$who" python3 -c '
import sys, json, os, datetime
who = os.environ.get("WHO") or None
ev = [e for e in json.load(sys.stdin) if who is None or e.get("details", {}).get("username") == who]
print("  %d TOKEN_EXCHANGE events for %s (newest first):" % (len(ev), who or "all users"))
for e in ev[:3]:
    d = e.get("details", {})
    print("  %s  agent=%s user=%s subject_token_client=%s audience=%s" % (
        datetime.datetime.fromtimestamp(e["time"] / 1000, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S"),
        e.get("clientId"), d.get("username"), d.get("subject_token_client_id"), d.get("audience")))' )
else na "Keycloak admin login not available here (Keycloak tab: realm parasol, Events, User events, type TOKEN_EXCHANGE)"; fi

hdr "4. What the gateway decided (the MCP gateway's decision log, every tools/call, gateway-system)"
# One access-log line per MCP gateway decision (allow and deny) with the user and agent Authorino verified and the
# tool; the claim's turns are the 15 minutes up to its payment (the gateway sees the tool, not its arguments).
if dlog=$(oc logs -n gateway-system -l gateway.networking.k8s.io/gateway-name=mcp-gateway --tail=-1 --max-log-requests=6 2>/dev/null); then
  printf '%s\n' "$dlog" | APPR="$appr" python3 -c '
import os, re, sys, datetime as dt
rx = re.compile(r"^(\S+) gateway-decision status=(\d+) req=\[([^]]*)\] resp=\[([^]]*)\] (?:method=\S+ )?tool=(\S+) server=(\S+)")
rows = sorted(m.groups() for m in map(rx.match, sys.stdin.read().splitlines()) if m)
a = os.environ.get("APPR", "")[:16]
if a:
    t = dt.datetime.strptime(a, "%Y-%m-%dT%H:%M")
    lo, hi = (t - dt.timedelta(minutes=15)).isoformat(), (t + dt.timedelta(minutes=2)).isoformat()
    rows = [r for r in rows if lo <= r[0] <= hi]
    print("  %d gateway decisions from %s to %s (UTC):" % (len(rows), lo[:16], hi[:16]))
else:
    rows = rows[-8:]
    print("  no approval yet: the last %d gateway decisions" % len(rows))
for ts, st, req, resp, tool, server in rows[-25:]:
    who = req if st == "200" else resp   # allowed: the header Authorino set on the request; refused: on the response
    print("  %s %-5s %s tool=%s server=%s" % (ts, {"200": "allow", "403": "deny", "401": "deny"}.get(st, st), who if who != "-" else "user=- agent=-", tool, server))'
else na "gateway log not readable (oc logs -n gateway-system -l gateway.networking.k8s.io/gateway-name=mcp-gateway)"; fi
echo "  the allowed writes are also attributed in claims-db: see the CLAIM APPROVED / PAYMENT RELEASED lines and their events above"

hdr "5. What was live: the release on Argo CD Application env-secured"
oc get application env-secured -n openshift-gitops -o json 2>/dev/null | python3 -c '
import sys, json
a = json.load(sys.stdin); an = a["metadata"].get("annotations", {})
for k in ("promoted-digest", "promoted-by", "prompt-ref", "prompt-version", "prompt-sha256", "agent-version"):
    print("  %-16s %s" % (k, an.get("parasol.example/" + k, "-")))
for h in a.get("status", {}).get("history", [])[-3:]:
    print("  synced %s  revision %s" % (h.get("deployedAt"), h.get("revision", "")[:12]))' || na "cannot read the Application"

hdr "6. Which evaluated agent version (MLflow, workspace $NS, Agent versions of parasol-agent-eval)"
AV=$(oc get application env-secured -n openshift-gitops -o jsonpath='{.metadata.annotations.parasol\.example/agent-version-id}' 2>/dev/null)
if [ -n "$TOK" ] && [ -n "$AV" ] && [ "$AV" != unrecorded ] && mlf "api/2.0/mlflow/logged-models/$AV" | grep -q model_id; then
  mlf "api/2.0/mlflow/logged-models/$AV" | python3 -c '
import sys, json
i = json.load(sys.stdin)["model"]; info, d = i["info"], i.get("data", {})
t = {x["key"]: x["value"] for x in info.get("tags", [])}; p = {x["key"]: x["value"] for x in d.get("params", [])}
print("  %s %s (%s)  gate=%s score=%s eval run=%s" % (info["name"], t.get("version"), info["model_id"], t.get("eval_gate"), t.get("eval_score"), t.get("eval_run_id", "")[:12]))
print("  prompt %s (%s) sha256 %s  tool policy sha256 %s  model %s" % (p.get("prompt_ref"), p.get("prompt_version"),
      p.get("prompt_sha256", "")[:12], p.get("tools_policy_sha256", "")[:12], p.get("model_id")))'
else na "agent version not readable here (annotation parasol.example/agent-version-id=${AV:-none}; MLflow tab: experiment parasol-agent-eval, Agent versions)"; fi

hdr "7. Is it the signed image? (release run, admission, the running pod)"
oc get pipelinerun parasol-portal-release-production -n parasol-build -o json 2>/dev/null | python3 -c '
import sys, json
r = {x["name"]: x["value"] for x in json.load(sys.stdin).get("status", {}).get("results", [])}
for k in ("PROMOTED_DIGEST", "EVAL_GATE", "EVAL_SCORE", "MLFLOW_RUN_ID", "AGENT_VERSION", "SBOM_SHA256"):
    print("  %-24s %s" % (k, str(r.get(k, "-"))[:110]))' || na "cannot read PipelineRuns in parasol-build"
echo "  running portal: $(oc get pods -n $NS -l app=portal -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null | sed 's/.*@//')"
echo "  admission: namespace label policy.rhtas.com/include=$(oc get ns $NS -o jsonpath='{.metadata.labels.policy\.rhtas\.com/include}' 2>/dev/null), ClusterImagePolicy parasol-portal-must-be-signed (unsigned images are refused: scripts/signing-demo.sh)"
