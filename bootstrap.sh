#!/usr/bin/env bash
# One-shot, repeatable bootstrap of the "AI Agents: from localhost to production" demo on a fresh
# OpenShift 4.22 cluster. Idempotent: run it again after a failure.
#
# Required env:
#   MAAS_ENDPOINT   OpenAI-compatible base URL of the upstream MaaS, e.g. https://maas.example.com/v1
#   MAAS_API_KEY    key for that endpoint
# Optional env:
#   MAAS_MODEL      model id the agent uses (default llama-scout-17b; qwen3-14b once probe-maas.sh says tool calls work)
#   REPO_URL        Git URL Argo CD syncs from (default: this repo's origin)
#   REPO_REVISION   branch/tag (default: main)
#   SKIP_BUILDS=1   do not start image builds
set -euo pipefail
cd "$(dirname "$0")"

: "${MAAS_ENDPOINT:?set MAAS_ENDPOINT}"
: "${MAAS_API_KEY:?set MAAS_API_KEY}"
export MAAS_MODEL="${MAAS_MODEL:-llama-scout-17b}"
export REPO_URL="${REPO_URL:-$(git remote get-url origin 2>/dev/null || echo https://github.com/CHANGEME/parasol-agent-prod.git)}"
export REPO_REVISION="${REPO_REVISION:-main}"
export CLUSTER_DOMAIN="$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')"
export MAAS_HOST="$(echo "$MAAS_ENDPOINT" | sed -E 's#https?://([^/:]+).*#\1#')"
export MAAS_PORT="$(echo "$MAAS_ENDPOINT" | sed -nE 's#https?://[^/:]+:([0-9]+).*#\1#p')"; export MAAS_PORT="${MAAS_PORT:-443}"
command -v envsubst >/dev/null || { echo "envsubst (gettext) is required"; exit 1; }

log(){ printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

log "Cluster $CLUSTER_DOMAIN, repo $REPO_URL@$REPO_REVISION, model $MAAS_MODEL"

log "1/8 OpenShift GitOps"
oc apply -f - <<'YAML'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata: {name: openshift-gitops-operator, namespace: openshift-operators}
spec: {channel: latest, installPlanApproval: Automatic, name: openshift-gitops-operator, source: redhat-operators, sourceNamespace: openshift-marketplace}
YAML
until oc get ns openshift-gitops >/dev/null 2>&1 && oc get deploy openshift-gitops-server -n openshift-gitops >/dev/null 2>&1; do sleep 10; done
oc rollout status deploy/openshift-gitops-server -n openshift-gitops --timeout=600s
# let Argo manage cluster-scoped things
oc adm policy add-cluster-role-to-user cluster-admin -z openshift-gitops-argocd-application-controller -n openshift-gitops >/dev/null

log "2/8 Operators (Connectivity Link, MCP gateway TP, Keycloak, OpenShift AI, observability, pipelines)"
if oc get csv -n redhat-ods-operator 2>/dev/null | grep -q rhods-operator; then
  echo "OpenShift AI already installed: $(oc get csv -n redhat-ods-operator -o jsonpath='{.items[0].spec.version}')"
  kustomize build gitops/bootstrap/operators | oc apply -f - --dry-run=client -o yaml \
    | python3 -c 'import sys,yaml; [print("---\n"+yaml.safe_dump(d)) for d in yaml.safe_load_all(sys.stdin) if d and not (d["kind"] in ("Subscription","OperatorGroup") and d["metadata"].get("namespace")=="redhat-ods-operator")]' | oc apply -f -
else
  kustomize build gitops/bootstrap/operators | oc apply -f -
fi
scripts/wait-csv.sh kuadrant-system rhcl-operator
scripts/wait-csv.sh mcp-system mcp-gateway || echo "WARN: MCP gateway operator not found in OperatorHub, see gitops/bootstrap/operators/mcp-gateway.yaml"
scripts/wait-csv.sh keycloak rhbk-operator
scripts/wait-csv.sh redhat-ods-operator rhods-operator

log "3/8 Secrets that never go to Git"
scripts/gen-trusted-keys.sh
for ns in parasol-free parasol-secured; do
  oc get ns $ns >/dev/null 2>&1 || oc create ns $ns
  oc -n $ns create secret generic maas-credentials --from-literal=GENAI_API_KEY="$MAAS_API_KEY" --dry-run=client -o yaml | oc apply -f -
done
oc -n parasol-secured create secret generic agent-service-identity --from-literal=username=dev --from-literal=password=dev --dry-run=client -o yaml | oc apply -f -
oc get ns models-as-a-service >/dev/null 2>&1 || oc create ns models-as-a-service
oc -n models-as-a-service create secret generic maas-upstream-credentials --from-literal=apiKey="$MAAS_API_KEY" --dry-run=client -o yaml | oc apply -f -

log "4/8 OpenShift AI components (DataScienceCluster patch)"
scripts/rhoai-enable.sh

log "5/8 Argo CD app-of-apps"
kustomize build gitops/bootstrap/apps | envsubst '$CLUSTER_DOMAIN $REPO_URL $REPO_REVISION $MAAS_ENDPOINT $MAAS_MODEL $MAAS_HOST $MAAS_PORT' | oc apply -f -

log "6/8 Images"
[ "${SKIP_BUILDS:-0}" = "1" ] || scripts/build-images.sh

log "7/8 Prompt-injection detector model"
scripts/fetch-detector-model.sh || echo "WARN: detector model fetch failed; the regex detector still works. See scripts/fetch-detector-model.sh"

log "8/8 Status"
scripts/status.sh
cat <<MSG

Next:
  scripts/probe-maas.sh                 # does the model emit structured tool calls?
  scripts/abuse.sh free                 # the three abuses, uncontrolled
  scripts/abuse.sh secured rebecca      # the same three, sandboxed
  Argo CD: https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}')
MSG
