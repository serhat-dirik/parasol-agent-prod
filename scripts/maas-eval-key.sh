#!/usr/bin/env bash
# maas-eval-key.sh : mint the OpenShift AI MaaS API keys of the evaluation subscription parasol-eval
# (gitops/platform/rhoai/maas.yaml). The keys belong to the release pipeline's ServiceAccount (parasol-build/pipeline);
# each Secret holds endpoint, key and model:
#   parasol-build/maas-eval-agent-key   the agent model (AGENT_MODEL): the release eval generates answers with it
#   parasol-build/maas-eval-key         the judge (JUDGE_MODEL): the release gate's judge, through MaaS
#   observability/agenticops-judge-key  the judge again, own key: the AgenticOps sampled judge (CronJob)
# Idempotent: an existing Secret is kept (FORCE=1 mints new keys); a judge Secret that still points straight at the
# provider (written by scripts/maas-model-keys.sh before MaaS was ready) is replaced by a MaaS key.
# Runs the call from inside the cluster (the MaaS gateway is ClusterIP). Never prints a key.
set -euo pipefail
NS=parasol-build
GW=https://maas-default-gateway-openshift-default.openshift-ingress.svc.cluster.local
dns_name() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | cut -c1-63 | sed -E 's/^-+|-+$//g'; }
AGENT=$(dns_name "${AGENT_MODEL:-qwen3-14b}") JUDGE=$(dns_name "${JUDGE_MODEL:-gpt-oss-120b}")

# keep <ns> <secret>: true when the Secret exists, goes through MaaS and FORCE is not set
keep() {
  [ "${FORCE:-}" != 1 ] || return 1
  local ep; ep=$(oc get secret "$2" -n "$1" -o jsonpath='{.data.endpoint}' 2>/dev/null | base64 -d 2>/dev/null) || return 1
  [[ "$ep" == "$GW"/* ]]
}

# mint <ns> <secret> <model name> <key name> <description>: a parasol-eval key stored as endpoint/key/model
mint() {
  local ns=$1 secret=$2 model=$3 tok key
  if ! oc get ns "$ns" >/dev/null 2>&1; then echo "skip $ns/$secret (namespace absent)"; return 0; fi
  if keep "$ns" "$secret"; then echo "Secret $ns/$secret exists (FORCE=1 to mint a new key)"; return 0; fi
  tok=$(oc create token pipeline -n $NS --duration=10m)
  key=$(oc exec -n parasol-secured deploy/guardrails-proxy -- python3 -c '
import json, ssl, sys, urllib.request as u
ctx = ssl.create_default_context(cafile="/etc/service-ca/service-ca.crt")
body = {"name": sys.argv[3], "description": sys.argv[4], "expiresIn": "30d", "subscription": "parasol-eval"}
req = u.Request(sys.argv[1] + "/maas-api/v1/api-keys", json.dumps(body).encode(),
                {"Authorization": "Bearer " + sys.argv[2], "content-type": "application/json"})
print(json.load(u.urlopen(req, context=ctx, timeout=30))["key"])' "$GW" "$tok" "$4" "$5")
  unset tok
  [[ "$key" == sk-* ]] || { echo "MaaS did not return a key for $ns/$secret"; return 1; }
  oc -n "$ns" create secret generic "$secret" --from-literal=key="$key" --from-literal=model="$model" \
    --from-literal=endpoint="$GW/models-as-a-service/$model/v1" --dry-run=client -o yaml | oc apply -f - >/dev/null
  unset key
  echo "Secret $ns/$secret written (subscription parasol-eval, model $model)"
}

mint $NS maas-eval-agent-key "$AGENT" parasol-release-eval "release evaluation (agent-eval gate)"
mint $NS maas-eval-key "$JUDGE" parasol-release-judge "release evaluation judge"
mint observability agenticops-judge-key "$JUDGE" parasol-agenticops-judge "AgenticOps sampled judge"
