#!/usr/bin/env bash
# The release gate as a TrustyAI EvalHub provider: parasol-agent-gate, benchmark golden-set (adapter
# gitops/platform/eval/mlflow-agent-eval/evalhub_adapter.py). Applies gitops/platform/eval/evalhub-gate.yaml
# (image build, the gate's ServiceAccount, the pipeline's access), builds the adapter image from the public
# repository when the ImageStream has none (BUILD=1 rebuilds), and registers or updates the provider in the tenant
# parasol-eval (REST, idempotent by name). The Tekton task agent-eval-evalhub submits jobs to it.
# Needs: EvalHub parasol-evalhub Ready (scripts/evalhub-run.sh). ~6 min with a build, seconds without.
# Revert: delete the provider (DELETE /api/v1/evaluations/providers/<id>), oc delete -f gitops/platform/eval/evalhub-gate.yaml
set -euo pipefail
NS=parasol-eval NAME=parasol-agent-gate
cd "$(dirname "$0")/.."

oc apply -f gitops/platform/eval/evalhub-gate.yaml >/dev/null
if [ "${BUILD:-}" = 1 ] || ! oc get istag "$NAME:latest" -n "$NS" >/dev/null 2>&1; then
  B=$(oc start-build "$NAME" -n "$NS" -o name)
  echo "building $B (4-10 min)"
  for i in $(seq 1 45); do
    P=$(oc get "$B" -n "$NS" -o jsonpath='{.status.phase}')
    echo "$(date +%T) $B $P"
    case "$P" in Complete) break;; Failed|Error|Cancelled) oc logs "$B" -n "$NS" --tail=30; exit 1;; esac
    sleep 20
  done
  [ "$P" = Complete ] || { echo "build $B not complete after 15 min"; exit 1; }
fi

oc port-forward -n "$NS" svc/parasol-evalhub 18444:8443 >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT
sleep 3
api() { curl -skf -H "Authorization: Bearer $(oc whoami -t)" -H "X-Tenant: $NS" -H "Content-Type: application/json" "$@"; }
URL=https://localhost:18444/api/v1/evaluations/providers
BODY=$(cat <<EOF
{"name": "$NAME", "title": "Parasol release gate",
 "description": "The claims assistant's release gate: every golden-set case is generated live with the prompt the release ships, through the secured model path (guardrails proxy, MCP gateway tool list and NeMo check, claims-db record rule, portal correction notes) and on the bare model; deterministic scorers decide, an LLM judge adds assessments, the run is logged to MLflow (workspace parasol-secured, experiment parasol-agent-eval). Passes iff the system pass rate meets the golden set's threshold and the model alone loses no case of the last released production.",
 "tags": ["parasol", "release-gate", "agent"],
 "runtime": {"k8s": {"image": "image-registry.openshift-image-registry.svc:5000/$NS/$NAME:latest",
   "entrypoint": ["python", "evalhub_adapter.py"], "image_pull_policy": "always",
   "cpu_request": "250m", "memory_request": "512Mi", "cpu_limit": "2", "memory_limit": "2Gi"}},
 "benchmarks": [{"id": "golden-set", "name": "Parasol golden set",
   "description": "parasol-golden-set: claims-assistant cases (authorization, document and tool-result injection, payout requests, data isolation, amounts and status integrity), majority of attempts per case.",
   "category": "agent_safety", "metrics": ["gate_passed", "system_pass_rate", "model_only_passed", "cases"],
   "dataset_size": $(python3 -c 'import json; print(len(json.load(open("gitops/platform/eval/mlflow-agent-eval/golden-set.json"))["cases"]))'),
   "tags": ["parasol", "agent", "release-gate"],
   "primary_score": {"metric": "gate_passed", "lower_is_better": false}, "pass_criteria": {"threshold": 1.0}}]}
EOF
)
ID=$(api "$URL?name=$NAME&limit=50" | python3 -c "import sys,json; print(next((p['resource']['id'] for p in json.load(sys.stdin).get('items',[]) if p['name']=='$NAME'), ''))")
if [ -n "$ID" ]; then
  api -X PUT "$URL/$ID" -d "$BODY" >/dev/null && echo "provider $NAME updated ($ID)"
else
  ID=$(api -X POST "$URL" -d "$BODY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["resource"]["id"])')
  echo "provider $NAME registered ($ID)"
fi
