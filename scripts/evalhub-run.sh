#!/usr/bin/env bash
# Scenario 4 step 1: one EvalHub run of the agent model, listed on the OpenShift AI dashboard
# (Develop & train -> Evaluations, project parasol-eval). Idempotent: applies the EvalHub CR, waits
# for it, and submits the run only if no completed run of that name exists (sqlite store: a pod
# restart empties the list, so re-run this after one). ~3 min, 5 IFEval prompts on the agent key.
# Needs: AGENT_ENDPOINT (+ AGENT_MODEL), Secret parasol-eval/maas-key-qwen3-14b with data key api-key
# (scripts/maas-model-keys.sh), OdhDashboardConfig disableLMEval=false (scripts/rhoai-enable.sh).
# Revert: oc delete evalhub parasol-evalhub -n parasol-eval
set -euo pipefail
: "${AGENT_ENDPOINT:?source scripts/load-credentials.sh or export the install contract}"
MODEL="${AGENT_MODEL:-qwen3-14b}" NAME="parasol-agent-model-ifeval" NS=parasol-eval
cd "$(dirname "$0")/.."

oc apply -f gitops/platform/eval/evalhub.yaml
oc wait evalhub/parasol-evalhub -n "$NS" --for=condition=Ready --timeout=300s

oc port-forward -n "$NS" svc/parasol-evalhub 18443:8443 >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT
sleep 3
api() { curl -skf -H "Authorization: Bearer $(oc whoami -t)" -H "X-Tenant: $NS" -H "Content-Type: application/json" "$@"; }
URL=https://localhost:18443/api/v1/evaluations/jobs

if api "$URL?limit=50" | python3 -c "import sys,json; sys.exit(0 if any(j['name']=='$NAME' and j['status']['state']=='completed' for j in json.load(sys.stdin).get('items',[])) else 1)"; then
  echo "run $NAME already completed"; exit 0
fi
# lm-eval-harness on the OpenAI-compatible /v1/completions route; the tokenizer is the HF id of the
# served model. ifeval reports under the "none" filter, so EvalHub records its metrics.
ID=$(api -X POST "$URL" -d @- <<EOF | python3 -c 'import sys,json; print(json.load(sys.stdin)["resource"]["id"])'
{"name": "$NAME",
 "description": "Agent model $MODEL on the external MaaS: IFEval instruction following, 5 prompts",
 "tags": ["parasol", "agent-model"],
 "model": {"url": "${AGENT_ENDPOINT%/}", "name": "$MODEL", "auth": {"secret_ref": "maas-key-$MODEL"}},
 "benchmarks": [{"id": "ifeval", "provider_id": "lm_evaluation_harness",
   "parameters": {"num_examples": 5, "num_few_shot": 0, "num_concurrent": 1, "tokenizer": "Qwen/Qwen3-14B"}}]}
EOF
)
echo "submitted $NAME ($ID)"
for i in $(seq 1 30); do
  S=$(api "$URL/$ID" | python3 -c 'import sys,json; print(json.load(sys.stdin)["status"]["state"])')
  echo "$(date +%T) $S"
  case "$S" in completed) exit 0;; failed|cancelled) exit 1;; esac
  sleep 20
done
echo "still running after 10 min: check oc get pods -n $NS"; exit 1
