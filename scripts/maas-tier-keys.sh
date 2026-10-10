#!/usr/bin/env bash
# maas-tier-keys.sh : mint one OpenShift AI MaaS API key for each demo tier and store them as Secrets.
#   parasol-tier-stage  -> Secret maas-tier-keys  key STAGE_MAAS_KEY
#   parasol-tier-prod   -> Secret maas-tier-keys  key PROD_MAAS_KEY
#   parasol-tier-guard  -> Secret maas-tier-keys  key GUARD_MAAS_KEY  (+ standalone Secret maas-guard-key
#                          for stream P1-GUARDIAN; data key GENAI_API_KEY)
# All three back the one accessible ExternalModel llama-scout-17b (see gitops/platform/maas-tiers).
# Keys belong to ServiceAccount parasol-maas-tiers/maas-tier-client, whose group each tier subscription
# admits. The mint call runs from a throwaway pod in parasol-maas-tiers (the MaaS gateway is ClusterIP);
# keys are never printed, logged or committed. Idempotent: re-running mints fresh keys and overwrites.
set -euo pipefail
NS=parasol-maas-tiers
GW=https://maas-default-gateway-openshift-default.openshift-ingress.svc.cluster.local
IMG=registry.access.redhat.com/ubi9/python-311:latest

# Service-CA bundle for TLS to the gateway (injected by the service-ca operator).
oc -n "$NS" get configmap maas-tier-ca >/dev/null 2>&1 || \
  oc -n "$NS" create configmap maas-tier-ca >/dev/null
oc -n "$NS" annotate configmap maas-tier-ca service.beta.openshift.io/inject-cabundle=true --overwrite >/dev/null
# wait for the CA to be injected
for i in $(seq 1 30); do
  oc -n "$NS" get configmap maas-tier-ca -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null | grep -q BEGIN && break
  echo "waiting for service-ca injection ($i)"; sleep 2
done

tok=$(oc create token maas-tier-client -n "$NS" --duration=20m)

# One pod mints all three keys and prints "TIER=sk-..." lines (nothing else to stdout).
pod=maas-tier-mint-$RANDOM
oc -n "$NS" run "$pod" --image="$IMG" --restart=Never --quiet \
  --overrides='{"spec":{"volumes":[{"name":"ca","configMap":{"name":"maas-tier-ca"}}],"containers":[{"name":"'"$pod"'","image":"'"$IMG"'","command":["sleep","300"],"volumeMounts":[{"name":"ca","mountPath":"/etc/service-ca"}]}]}}' >/dev/null
oc -n "$NS" wait --for=condition=Ready pod/"$pod" --timeout=120s >/dev/null

out=$(oc -n "$NS" exec "$pod" -- env GW="$GW" TOK="$tok" python3 -c '
import json, os, ssl, urllib.request as u
ctx = ssl.create_default_context(cafile="/etc/service-ca/service-ca.crt")
gw, tok = os.environ["GW"], os.environ["TOK"]
tiers = {"STAGE": "parasol-tier-stage", "PROD": "parasol-tier-prod", "GUARD": "parasol-tier-guard"}
for label, sub in tiers.items():
    body = {"name": "parasol-"+sub, "description": "demo tier "+label.lower(),
            "expiresIn": "30d", "subscription": sub}
    req = u.Request(gw+"/maas-api/v1/api-keys", json.dumps(body).encode(),
                    {"Authorization": "Bearer "+tok, "content-type": "application/json"})
    print(label + "=" + json.load(u.urlopen(req, context=ctx, timeout=30))["key"])
')
oc -n "$NS" delete pod "$pod" --wait=false >/dev/null 2>&1 || true
unset tok

stage=$(printf '%s\n' "$out" | sed -n 's/^STAGE=//p')
prod=$(printf '%s\n' "$out" | sed -n 's/^PROD=//p')
guard=$(printf '%s\n' "$out" | sed -n 's/^GUARD=//p')
unset out
[[ "$stage" == sk-* && "$prod" == sk-* && "$guard" == sk-* ]] || { echo "MaaS did not return all three keys"; exit 1; }

oc -n "$NS" create secret generic maas-tier-keys \
  --from-literal=STAGE_MAAS_KEY="$stage" \
  --from-literal=PROD_MAAS_KEY="$prod" \
  --from-literal=GUARD_MAAS_KEY="$guard" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
# Standalone guard-key secret for stream P1-GUARDIAN (GENAI_API_KEY, the convention maas-credentials uses).
oc -n "$NS" create secret generic maas-guard-key \
  --from-literal=GENAI_API_KEY="$guard" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
unset stage prod guard
echo "Secrets written in $NS: maas-tier-keys (STAGE/PROD/GUARD_MAAS_KEY), maas-guard-key (GENAI_API_KEY)"
