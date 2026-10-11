#!/usr/bin/env bash
# The data the guide shows as already there (Scenario 2 playground, Scenario 4, supply chain). Run by
# bootstrap.sh after the platform is up; idempotent, and each step can be re-run alone (printed on WARN).
#   1 MLflow experiment parasol-portal-chat (chat traces; must be experiment id 1, see otel-collector.yaml)
#   2 MLflow Prompt Registry: system prompt v1 + v2
#   3 MLflow golden-set runs: v1 20/20 PASS, v2 17/20 BLOCK (judge = JUDGE model)
#   4 Model Registry parasol-model-registry: parasol-claims-assistant v1 + v2 with those eval results
#   5 EvalHub run parasol-agent-model-ifeval + LMEvalJob parasol-agent-model-eval (Evaluations pages)
#   6 GenAI Studio playground (OGXServer on the agent model)
#   7 release PipelineRuns v2 (blocked) and v1 (promoted; bootstrap.sh waits for it)
# Needs the install contract env (AGENT_*, JUDGE_* ...), see bootstrap.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
: "${AGENT_ENDPOINT:?export the install contract (see bootstrap.sh)}"
export AGENT_MODEL="${AGENT_MODEL:-qwen3-14b}"
export CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')}"
WARN=""
warn() { echo "WARN: $1 -> re-run: $2"; WARN="$WARN\n  $2"; }
wait_for() {  # wait_for <tries> <what> <command...>   (15 s apart)
  local n=$1 what=$2 i; shift 2
  for i in $(seq 1 "$n"); do "$@" >/dev/null 2>&1 && return 0; echo "$(date +%T) waiting for $what ($i/$n)"; sleep 15; done
  return 1
}

echo "== 1 MLflow chat-trace experiment"
if wait_for 60 "MLflow service (DSC mlflowoperator + MLflow CR)" oc get svc mlflow -n redhat-ods-applications; then
  scripts/mlflow-experiment.sh || warn "MLflow experiment" scripts/mlflow-experiment.sh
else warn "MLflow not up" scripts/seed-demo.sh; fi

echo "== 2 prompt registry"
gitops/platform/pipeline/prompts/register.sh || warn "prompt registration" gitops/platform/pipeline/prompts/register.sh

echo "== 3 golden-set evaluation runs"
ids=$(scripts/eval-seed.sh | tail -1) || { warn "golden-set runs" scripts/eval-seed.sh; ids=""; }
case "$ids" in MLFLOW_EXPERIMENT_ID=*) eval "export $ids"; echo "$ids";; *) ids="";; esac

echo "== 4 model registry"
if wait_for 40 "Model Registry CRD + namespace" oc get crd modelregistries.modelregistry.opendatahub.io -o name \
   && wait_for 20 "namespace rhoai-model-registries" oc get ns rhoai-model-registries; then
  oc apply -f gitops/platform/model-registry/instance.yaml
  if oc wait modelregistries.modelregistry.opendatahub.io/parasol-model-registry -n rhoai-model-registries --for=condition=Available --timeout=600s; then
    gitops/platform/model-registry/register.sh || warn "model registration" gitops/platform/model-registry/register.sh
  else warn "parasol-model-registry not Available" "oc get modelregistries.modelregistry.opendatahub.io -n rhoai-model-registries; gitops/platform/model-registry/register.sh"; fi
else warn "Model Registry component not installed (DSC modelregistry)" scripts/seed-demo.sh; fi

echo "== 5 evaluations (EvalHub, LMEval)"
if wait_for 40 "EvalHub CRD" oc get crd evalhubs.trustyai.opendatahub.io; then
  scripts/evalhub-run.sh || warn "EvalHub run" scripts/evalhub-run.sh
else warn "EvalHub CRD missing (DSC trustyai)" scripts/evalhub-run.sh; fi
if oc get lmevaljob parasol-agent-model-eval -n parasol-eval >/dev/null 2>&1; then echo "LMEvalJob already present"
else envsubst '$AGENT_ENDPOINT $AGENT_MODEL' < gitops/platform/eval/lmevaljob-agent-model.yaml | oc apply -f - \
  || warn "LMEvalJob" "envsubst '\$AGENT_ENDPOINT \$AGENT_MODEL' < gitops/platform/eval/lmevaljob-agent-model.yaml | oc apply -f -"; fi

echo "== 6 GenAI Studio playground"
if wait_for 40 "OGXServer CRD (DSC ogx)" oc get crd ogxservers.ogx.io; then
  : "${AGENT_KEY:?}"; scripts/ogx-playground.sh || warn "playground" scripts/ogx-playground.sh
else warn "OGX CRD missing" scripts/ogx-playground.sh; fi

echo "== 7 release pipeline runs"
scripts/pipeline-runs.sh || warn "pipeline runs" scripts/pipeline-runs.sh

[ -z "$WARN" ] && echo "seed complete" || { printf "seed finished with warnings; re-run:%b\n" "$WARN"; exit 1; }
