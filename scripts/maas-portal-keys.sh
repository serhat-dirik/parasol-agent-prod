#!/usr/bin/env bash
# maas-portal-keys.sh : mint the two OpenShift AI MaaS API keys the SECURED portal selects per request
# from the logged-in user's Keycloak group (Demo 3 per-user 429):
#   STAFF_MAAS_KEY        -> subscription parasol-stage        (200k tokens / 10m)  adjusters, claims-managers, developers
#   POLICYHOLDER_MAAS_KEY -> subscription parasol-policyholder ( 20k tokens / 10m)  group policyholders (tom.becker)
# Both keys belong to ServiceAccount parasol-model-client (group system:serviceaccounts:parasol-secured,
# which both subscriptions admit); the per-subscription token bucket is what isolates the 429. Stored in
# Secret maas-portal-keys in parasol-secured; the portal (Stream P) mounts it. Never prints a key.
set -euo pipefail
NS=parasol-secured
GW=https://maas-default-gateway-openshift-default.openshift-ingress.svc.cluster.local

mint() {  # $1 = subscription name ; echoes the key (sk-...)
  local sub="$1" tok
  tok=$(oc create token parasol-model-client -n "$NS" --duration=10m)
  oc exec -n "$NS" deploy/guardrails-proxy -- python3 -c '
import json, ssl, sys, urllib.request as u
ctx = ssl.create_default_context(cafile="/etc/service-ca/service-ca.crt")
body = {"name": "parasol-portal-" + sys.argv[3], "description": "secured portal " + sys.argv[3] + " tier",
        "expiresIn": "30d", "subscription": sys.argv[3]}
req = u.Request(sys.argv[1] + "/maas-api/v1/api-keys", json.dumps(body).encode(),
                {"Authorization": "Bearer " + sys.argv[2], "content-type": "application/json"})
print(json.load(u.urlopen(req, context=ctx, timeout=30))["key"])' "$GW" "$tok" "$sub"
}

staff=$(mint parasol-stage)
poly=$(mint parasol-policyholder)
[[ "$staff" == sk-* && "$poly" == sk-* ]] || { echo "MaaS did not return both keys"; exit 1; }
oc -n "$NS" create secret generic maas-portal-keys \
  --from-literal=STAFF_MAAS_KEY="$staff" \
  --from-literal=POLICYHOLDER_MAAS_KEY="$poly" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
unset staff poly
echo "Secret maas-portal-keys written in $NS (STAFF_MAAS_KEY=parasol-stage, POLICYHOLDER_MAAS_KEY=parasol-policyholder)"
