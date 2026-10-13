#!/usr/bin/env bash
# maas-eval-key.sh : mint the OpenShift AI MaaS API key the release evaluation generates answers with
# (qwen3-14b on subscription parasol-eval, gitops/platform/rhoai/maas.yaml). The key belongs to the release
# pipeline's ServiceAccount (parasol-build/pipeline) and is stored in Secret parasol-build/maas-eval-agent-key
# (endpoint, key, model) for the agent-eval Task and scripts/eval-seed.sh. Idempotent: an existing Secret is
# kept (FORCE=1 mints a new key). Runs the call from inside the cluster (the MaaS gateway is ClusterIP).
# Never prints the key.
set -euo pipefail
NS=parasol-build SECRET=maas-eval-agent-key
GW=https://maas-default-gateway-openshift-default.openshift-ingress.svc.cluster.local
MODEL=${AGENT_MODEL:-qwen3-14b}
if [ "${FORCE:-}" != 1 ] && oc get secret $SECRET -n $NS >/dev/null 2>&1; then
  echo "Secret $NS/$SECRET exists (FORCE=1 to mint a new key)"; exit 0
fi
tok=$(oc create token pipeline -n $NS --duration=10m)
key=$(oc exec -n parasol-secured deploy/guardrails-proxy -- python3 -c '
import json, ssl, sys, urllib.request as u
ctx = ssl.create_default_context(cafile="/etc/service-ca/service-ca.crt")
body = {"name": "parasol-release-eval", "description": "release evaluation (agent-eval gate)", "expiresIn": "30d",
        "subscription": "parasol-eval"}
req = u.Request(sys.argv[1] + "/maas-api/v1/api-keys", json.dumps(body).encode(),
                {"Authorization": "Bearer " + sys.argv[2], "content-type": "application/json"})
print(json.load(u.urlopen(req, context=ctx, timeout=30))["key"])' "$GW" "$tok")
unset tok
[[ "$key" == sk-* ]] || { echo "MaaS did not return a key"; exit 1; }
oc -n $NS create secret generic $SECRET --from-literal=key="$key" --from-literal=model="$MODEL" \
  --from-literal=endpoint="$GW/models-as-a-service/$MODEL/v1" --dry-run=client -o yaml | oc apply -f - >/dev/null
unset key
echo "Secret $NS/$SECRET written (subscription parasol-eval, model $MODEL)"
