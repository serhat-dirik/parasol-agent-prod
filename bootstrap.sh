#!/usr/bin/env bash
# One-shot, repeatable bootstrap of the "AI Agents: from localhost to production" demo on a fresh
# OpenShift 4.22 cluster. Idempotent: run it again after a failure.
#
# Required env (or: source scripts/load-credentials.sh to read them from the RHDP credentials file):
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
if oc get deploy openshift-gitops-server -n openshift-gitops >/dev/null 2>&1; then
  echo "OpenShift GitOps already installed"
else
oc apply -f - <<'YAML'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata: {name: openshift-gitops-operator, namespace: openshift-operators}
spec: {channel: latest, installPlanApproval: Automatic, name: openshift-gitops-operator, source: redhat-operators, sourceNamespace: openshift-marketplace}
YAML
for i in $(seq 1 45); do oc get deploy openshift-gitops-server -n openshift-gitops >/dev/null 2>&1 && break; echo "$(date +%T) waiting for GitOps operator ($i/45)"; sleep 20; done
fi
oc rollout status deploy/openshift-gitops-server -n openshift-gitops --timeout=600s
# let Argo manage cluster-scoped things
oc adm policy add-cluster-role-to-user cluster-admin -z openshift-gitops-argocd-application-controller -n openshift-gitops >/dev/null

log "2/8 Operators (Connectivity Link, MCP gateway TP, Keycloak, OpenShift AI, observability, pipelines)"
# Operators the lab already installed keep their own Subscription/OperatorGroup (a second
# OperatorGroup in the same namespace breaks OLM for that namespace).
SKIP_NS=""
# (no `grep -q` here: under pipefail its early exit SIGPIPEs oc and the test fails on long CSV lists)
[ -n "$(oc get csv -n redhat-ods-operator -o name 2>/dev/null | grep rhods-operator)" ] && SKIP_NS="$SKIP_NS redhat-ods-operator"
[ -n "$(oc get csv -n keycloak -o name 2>/dev/null | grep rhbk-operator)" ] && SKIP_NS="$SKIP_NS keycloak"
[ -n "$SKIP_NS" ] && echo "Already installed, Subscription/OperatorGroup skipped in:$SKIP_NS"
kustomize build gitops/bootstrap/operators \
  | SKIP_NS="$SKIP_NS" python3 -c 'import os,sys,yaml; skip=os.environ["SKIP_NS"].split(); [print("---\n"+yaml.safe_dump(d)) for d in yaml.safe_load_all(sys.stdin) if d and not (d["kind"] in ("Subscription","OperatorGroup") and d["metadata"].get("namespace") in skip)]' \
  | oc apply -f -
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
oc -n models-as-a-service create secret generic maas-upstream-api-key --from-literal=api-key="$MAAS_API_KEY" --dry-run=client -o yaml | oc apply -f -
# MaaS API database (gitops/platform/rhoai/maas-db.yaml): password generated once, never printed
ns=redhat-ai-gateway-infra; oc get ns $ns >/dev/null 2>&1 || oc create ns $ns
if ! oc get secret maas-postgres -n $ns >/dev/null 2>&1; then
  pw=$(openssl rand -hex 16)
  oc -n $ns create secret generic maas-postgres --from-literal=user=maas --from-literal=password="$pw" >/dev/null
  oc -n $ns create secret generic maas-db-config --from-literal=DB_CONNECTION_URL="postgresql://maas:${pw}@maas-postgres.${ns}.svc:5432/maas?sslmode=disable" >/dev/null
  unset pw; echo "MaaS database secrets created"
fi

log "4/8 OpenShift AI components (DataScienceCluster patch)"
scripts/rhoai-enable.sh

log "5/8 Argo CD app-of-apps"
kustomize build gitops/bootstrap/apps | envsubst '$CLUSTER_DOMAIN $REPO_URL $REPO_REVISION $MAAS_ENDPOINT $MAAS_MODEL $MAAS_HOST $MAAS_PORT' | oc apply -f -

log "6/8 Images"
[ "${SKIP_BUILDS:-0}" = "1" ] || scripts/build-images.sh

log "6b/8 Authorino TLS (OpenShift AI MaaS needs it) and the secured agent's MaaS API key"
scripts/authorino-tls.sh || echo "WARN: Authorino TLS not applied (reverted); MaaS stays NotReady. See scripts/authorino-tls.sh"
for i in $(seq 1 40); do [ "$(oc get datasciencecluster -o jsonpath='{.items[0].status.conditions[?(@.type=="ModelsAsAServiceReady")].status}')" = True ] && break; echo "$(date +%T) waiting for ModelsAsAServiceReady ($i/40)"; sleep 30; done
scripts/maas-key.sh || echo "WARN: no MaaS key minted; parasol-secured keeps the upstream key"

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
