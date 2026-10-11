#!/usr/bin/env bash
# One-shot, repeatable bootstrap of the "AI Agents: from localhost to production" demo on a fresh
# OpenShift 4.22 cluster (with or without OpenShift AI, GitOps or Keycloak already installed: every
# prerequisite is detected and installed only if missing). Idempotent: run it again after a failure or a WARN.
# Expected total: 75-120 min on a bare cluster (operators 10-15, OpenShift AI components 15-40,
# image builds 10, Trusted Artifact Signer 10-15, golden-set eval 10-20; release pipeline runs continue
# in the background another 20-30 min).
#
# Each model may come from a DIFFERENT OpenAI-compatible endpoint (base URL ending in /v1) with its own key.
# Required env:
#   AGENT_ENDPOINT, AGENT_KEY   the agent model both portals run (AGENT_MODEL)
#   GUARD_ENDPOINT, GUARD_KEY   granite-guardian-3-1-8b: guard-tier detector + playground external model
#   JUDGE_ENDPOINT, JUDGE_KEY   gpt-oss-120b: evaluation judge
# Optional env:
#   AGENT_MODEL     upstream model id of the agent (default qwen3-14b)
#   LLAMAGUARD_ENDPOINT, LLAMAGUARD_KEY   Llama-Guard-3-1B, optional 3rd detector (skipped if unset)
#   REPO_URL        Git URL Argo CD syncs from (default: this repo's origin)
#   REPO_REVISION   branch/tag (default: main)
#   RHOAI_CHANNEL / RHOAI_CSV   OpenShift AI channel / pinned CSV (default stable-3.x / rhods-operator.3.5.1)
#   SKIP_BUILDS=1   do not start image builds;  SKIP_SEED=1  skip the demo data (scripts/seed-demo.sh)
# The one manual step (the release pipeline's promote pushes to Git with your GitHub token):
#   read -s T && oc create secret generic gitops-auth-secret -n parasol-build --from-literal=token="$T" && unset T
set -euo pipefail
cd "$(dirname "$0")"

missing=""
for v in AGENT_ENDPOINT AGENT_KEY GUARD_ENDPOINT GUARD_KEY JUDGE_ENDPOINT JUDGE_KEY; do
  [ -n "${!v:-}" ] || missing="$missing $v"
done
[ -z "$missing" ] || { echo "bootstrap.sh: missing required env:$missing (each model needs <ROLE>_ENDPOINT and <ROLE>_KEY; see the header of bootstrap.sh)" >&2; exit 1; }
for t in oc kustomize envsubst openssl python3 curl jq; do command -v $t >/dev/null || { echo "bootstrap.sh: $t is required" >&2; exit 1; }; done
python3 -c 'import yaml' 2>/dev/null || { echo "bootstrap.sh: python3 needs PyYAML" >&2; exit 1; }
export AGENT_MODEL="${AGENT_MODEL:-qwen3-14b}"
export REPO_URL="${REPO_URL:-$(git remote get-url origin 2>/dev/null || echo https://github.com/CHANGEME/parasol-agent-prod.git)}"
export REPO_REVISION="${REPO_REVISION:-main}"
export CLUSTER_DOMAIN="$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')"
host() { echo "$1" | sed -E 's#https?://([^/:]+).*#\1#'; }
port() { local p; p="$(echo "$1" | sed -nE 's#https?://[^/:]+:([0-9]+).*#\1#p')"; echo "${p:-443}"; }
export AGENT_HOST="$(host "$AGENT_ENDPOINT")" AGENT_PORT="$(port "$AGENT_ENDPOINT")" GUARD_HOST="$(host "$GUARD_ENDPOINT")"
# In-cluster calls to the public *.apps hosts leave through the ingress address: the platform's ingress
# VIP where there is one (bare metal, vSphere, ...), otherwise any address on 443 (cloud load balancers).
ip=$(oc get infrastructure cluster -o json | python3 -c 'import json,sys
ps=json.load(sys.stdin)["status"].get("platformStatus",{})
print(next((v["ingressIPs"][0] for v in ps.values() if isinstance(v,dict) and v.get("ingressIPs")),""))')
export INGRESS_CIDR="${INGRESS_CIDR:-${ip:+$ip/32}}"; export INGRESS_CIDR="${INGRESS_CIDR:-0.0.0.0/0}"

log(){ printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
WARNS=""
warn(){ printf '\033[1;33mWARN: %s\033[0m\n  re-run: %s\n' "$1" "$2"; WARNS="$WARNS\n  - $1: $2"; }
APPS_ENV='$CLUSTER_DOMAIN $REPO_URL $REPO_REVISION $AGENT_ENDPOINT $AGENT_MODEL $AGENT_HOST $AGENT_PORT $INGRESS_CIDR'

log "Cluster $CLUSTER_DOMAIN (ingress $INGRESS_CIDR), repo $REPO_URL@$REPO_REVISION, agent $AGENT_MODEL@$AGENT_HOST, guard @$GUARD_HOST"

log "1/12 OpenShift GitOps"
if oc get deploy openshift-gitops-server -n openshift-gitops >/dev/null 2>&1; then
  echo "already installed: OpenShift GitOps"
else
  echo "installing: OpenShift GitOps"
  oc apply -f - <<'YAML'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata: {name: openshift-gitops-operator, namespace: openshift-operators}
spec: {channel: latest, installPlanApproval: Automatic, name: openshift-gitops-operator, source: redhat-operators, sourceNamespace: openshift-marketplace}
YAML
  for i in $(seq 1 45); do oc get deploy openshift-gitops-server -n openshift-gitops >/dev/null 2>&1 && break; echo "$(date +%T) waiting for GitOps operator ($i/45)"; sleep 20; done
fi
oc rollout status deploy/openshift-gitops-server -n openshift-gitops --timeout=600s
oc adm policy add-cluster-role-to-user cluster-admin -z openshift-gitops-argocd-application-controller -n openshift-gitops >/dev/null

log "2/12 Operators (each: already installed, or installing) and wait for all CSVs"
kustomize build gitops/bootstrap/operators | scripts/ensure-operators.py \
  || { echo "An operator did not reach Succeeded (see FAILED above). Fix or wait, then re-run ./bootstrap.sh"; exit 1; }

log "3/12 Secrets that never go to Git"
for ns in parasol-free parasol-secured parasol-build parasol-eval models-as-a-service redhat-ai-gateway-infra; do
  oc get ns $ns >/dev/null 2>&1 || oc create ns $ns >/dev/null
done
scripts/gen-trusted-keys.sh
for ns in parasol-free parasol-secured; do   # parasol-secured's is replaced by a MaaS key in step 8
  oc -n $ns create secret generic maas-credentials --from-literal=GENAI_API_KEY="$AGENT_KEY" --dry-run=client -o yaml | oc apply -f - >/dev/null
done
oc -n parasol-secured create secret generic agent-service-identity --from-literal=username=dev --from-literal=password=dev --dry-run=client -o yaml | oc apply -f - >/dev/null
scripts/maas-ext-model-secrets.sh   # upstream keys: qwen3-14b <- AGENT_KEY, granite-guardian <- GUARD_KEY
ns=redhat-ai-gateway-infra   # MaaS API database (gitops/platform/rhoai/maas-db.yaml): password generated once, never printed
if ! oc get secret maas-postgres -n $ns >/dev/null 2>&1; then
  pw=$(openssl rand -hex 16)
  oc -n $ns create secret generic maas-postgres --from-literal=user=maas --from-literal=password="$pw" >/dev/null
  oc -n $ns create secret generic maas-db-config --from-literal=DB_CONNECTION_URL="postgresql://maas:${pw}@maas-postgres.${ns}.svc:5432/maas?sslmode=disable" >/dev/null
  unset pw; echo "MaaS database secrets created"
fi

log "4/12 Keycloak instance"
KC_APP=0
if oc get application platform-keycloak-instance -n openshift-gitops >/dev/null 2>&1; then
  echo "already installed: Keycloak (this demo's instance, Argo platform-keycloak-instance)"; KC_APP=1
elif [ -n "$(oc get keycloaks.k8s.keycloak.org -n keycloak -o name 2>/dev/null)" ]; then
  echo "already installed: Keycloak ($(oc get keycloaks.k8s.keycloak.org -n keycloak -o name | head -1)), realm parasol is imported into it"
  [ -n "$(oc get keycloaks.k8s.keycloak.org keycloak -n keycloak -o name 2>/dev/null)" ] || \
    warn "the lab Keycloak in namespace keycloak is not named 'keycloak' (realm-import keycloakCRName)" "edit gitops/platform/keycloak/realm-import.yaml"
else
  echo "installing: Keycloak (gitops/platform/keycloak-instance) at https://sso.apps.$CLUSTER_DOMAIN"; KC_APP=1
  oc get ns keycloak >/dev/null 2>&1 || oc create ns keycloak >/dev/null
  oc get secret keycloak-db -n keycloak >/dev/null 2>&1 || \
    oc -n keycloak create secret generic keycloak-db --from-literal=username=keycloak --from-literal=password="$(openssl rand -hex 16)" >/dev/null
fi

log "5/12 OpenShift AI platform (DSCInitialization, DataScienceCluster, dashboard config)"
scripts/rhoai-enable.sh || warn "OpenShift AI platform objects not complete" scripts/rhoai-enable.sh

log "6/12 Argo CD app-of-apps"
kustomize build gitops/bootstrap/apps | envsubst "$APPS_ENV" | oc apply -f -
[ $KC_APP = 1 ] && envsubst "$APPS_ENV" < gitops/bootstrap/optional/platform-keycloak-instance.yaml | oc apply -f -

log "7/12 Images (built from this checkout; the secured portal is built by the release pipeline)"
if [ "${SKIP_BUILDS:-0}" = 1 ]; then echo "SKIP_BUILDS=1"
else scripts/build-images.sh || warn "an image build failed" scripts/build-images.sh; fi

log "8/12 MaaS: Authorino TLS, tiers, keys"
for i in $(seq 1 40); do oc rollout status deploy/guardrails-proxy -n parasol-secured --timeout=5s >/dev/null 2>&1 && break
  echo "$(date +%T) waiting for guardrails-proxy (Argo platform-guardrails) ($i/40)"; sleep 15; done
scripts/kuadrant-ready.sh || warn "Kuadrant not Ready: no AuthPolicy is enforced (MaaS keys fail with 500)" scripts/kuadrant-ready.sh
scripts/authorino-tls.sh || warn "Authorino TLS not applied (reverted); MaaS stays NotReady" scripts/authorino-tls.sh
for i in $(seq 1 60); do [ "$(oc get datasciencecluster -o jsonpath='{.items[0].status.conditions[?(@.type=="ModelsAsAServiceReady")].status}')" = True ] && break; echo "$(date +%T) waiting for ModelsAsAServiceReady ($i/60)"; sleep 30; done
kustomize build gitops/platform/maas-tiers | envsubst '$GUARD_HOST' | oc apply -f - \
  || warn "MaaS tiers not applied (MaaS CRDs not ready?)" "./bootstrap.sh"
scripts/maas-key.sh || warn "no MaaS key minted; parasol-secured keeps the upstream key" scripts/maas-key.sh
scripts/maas-portal-keys.sh || warn "secured portal per-group MaaS keys (STAFF/CONTRACTOR) missing; the secured portal cannot start" scripts/maas-portal-keys.sh
scripts/maas-model-keys.sh || warn "per-model Secrets not all created" scripts/maas-model-keys.sh

log "9/12 Keycloak realm and portal login client"
for i in $(seq 1 60); do curl -skf "https://sso.apps.$CLUSTER_DOMAIN/realms/parasol" >/dev/null && break
  echo "$(date +%T) waiting for realm parasol at https://sso.apps.$CLUSTER_DOMAIN ($i/60)"; sleep 15; done
scripts/portal-oidc-client.sh || warn "portal OIDC client Secret missing; both portals cannot start" scripts/portal-oidc-client.sh
scripts/portal-users.sh >/dev/null || warn "contractor group/user not ensured" scripts/portal-users.sh

log "10/12 Prompt-injection detector model"
scripts/fetch-detector-model.sh || warn "detector model fetch failed (the regex detector still works)" scripts/fetch-detector-model.sh

log "11/12 Supply chain (SPIRE, Trusted Artifact Signer, cosign key, admission)"
scripts/supply-chain.sh || warn "supply chain incomplete" scripts/supply-chain.sh

log "12/12 Demo data, consoles, status"
if [ "${SKIP_SEED:-0}" = 1 ]; then echo "SKIP_SEED=1"
else scripts/seed-demo.sh || warn "demo data incomplete (the lines above name each step)" scripts/seed-demo.sh; fi
scripts/showroom-framing.sh || warn "console framing headers not applied; Showroom console tabs stay blank" scripts/showroom-framing.sh
scripts/console-plugins.sh || warn "console plugins not enabled; the PipelineRun graph will be missing" scripts/console-plugins.sh
scripts/status.sh || true

[ -n "$WARNS" ] && printf '\n\033[1;33mFinished with warnings (each line: what, then the command to re-run):\033[0m%b\n' "$WARNS"
cat <<MSG

Showroom guide: https://showroom-parasol-showroom.apps.$CLUSTER_DOMAIN
MSG
if ! oc get secret gitops-auth-secret -n parasol-build >/dev/null 2>&1; then cat <<'MSG'

ONE MANUAL STEP LEFT: the secured portal runs only the image the release pipeline signs and promotes,
and promotion is a commit to this repo. Give the pipeline a GitHub token (contents:write on the repo):
  read -s T && oc create secret generic gitops-auth-secret -n parasol-build --from-literal=token="$T" && unset T
then start the promoted release run (~25 min, then Argo rolls the secured portal):
  scripts/pipeline-runs.sh --wait
MSG
fi
