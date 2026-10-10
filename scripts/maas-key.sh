#!/usr/bin/env bash
# maas-key.sh : mint an OpenShift AI MaaS API key for the secured agent and store it as the agent's model
# key (Secret maas-credentials in parasol-secured). The key belongs to ServiceAccount parasol-model-client
# and is bound to subscription parasol-stage. The upstream (LiteLLM) key stays with MaaS only.
# Runs the call from inside the cluster (the MaaS gateway is ClusterIP). Never prints the key.
set -euo pipefail
NS=parasol-secured
GW=https://maas-default-gateway-openshift-default.openshift-ingress.svc.cluster.local
tok=$(oc create token parasol-model-client -n $NS --duration=10m)
key=$(oc exec -n $NS deploy/guardrails-proxy -- python3 -c '
import json, ssl, sys, urllib.request as u
ctx = ssl.create_default_context(cafile="/etc/service-ca/service-ca.crt")
body = {"name": "parasol-secured-agent", "description": "secured claims agent", "expiresIn": "30d", "subscription": "parasol-stage"}
req = u.Request(sys.argv[1] + "/maas-api/v1/api-keys", json.dumps(body).encode(),
                {"Authorization": "Bearer " + sys.argv[2], "content-type": "application/json"})
print(json.load(u.urlopen(req, context=ctx, timeout=30))["key"])' "$GW" "$tok")
unset tok
[[ "$key" == sk-* ]] || { echo "MaaS did not return a key"; exit 1; }
oc -n $NS create secret generic maas-credentials --from-literal=GENAI_API_KEY="$key" --dry-run=client -o yaml | oc apply -f - >/dev/null
unset key
oc rollout restart deploy/parasol-agent -n $NS >/dev/null
echo "MaaS key for parasol-secured stored in Secret maas-credentials (subscription parasol-stage); agent restarting"
