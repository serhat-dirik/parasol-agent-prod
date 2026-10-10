#!/usr/bin/env bash
# devportal-keyflow.sh — drive and verify the Connectivity Link developer-portal
# API-key approval flow end to end (request -> pending -> approve -> key works),
# entirely inside the isolated parasol-devportal namespace. Idempotent; re-runnable.
#
#   ./scripts/devportal-keyflow.sh [user] [key-value]
#
# Assumes the infra is applied (gitops/platform/devportal/{10,20,30,40}-*.yaml) and
# the developer-portal component is enabled on the Kuadrant CR:
#   oc patch kuadrant kuadrant -n kuadrant-system --type merge \
#     -p '{"spec":{"components":{"developerPortal":{"enabled":true}}}}'
set -uo pipefail
ns=parasol-devportal
user=${1:-rebecca}
key=${2:-${user}-demo-key-9f3a2}          # demo value only; NOT a real credential
name=${user}-claims-key
host=devportal-api.apps.cluster-znh6n.dyn.redhatworkshops.io
url=https://$host/get

say(){ printf '\n\033[1;33m== %s ==\033[0m\n' "$*"; }
code(){ curl -sk -o /dev/null -w '%{http_code}' "$@"; }

say "STEP 0: baseline — the key is not issued yet, calls are refused"
echo "no key   -> HTTP $(code "$url")        (expect 401; 500 == no key has ever been issued so Authorino has no ready config)"

say "STEP 1 (developer): request a key — create the key Secret + APIKey (manual product => Pending)"
oc create secret generic "$name" -n "$ns" --from-literal=api_key="$key" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
cat <<YAML | oc apply -f - >/dev/null
apiVersion: devportal.kuadrant.io/v1alpha1
kind: APIKey
metadata: {name: $name, namespace: $ns}
spec:
  apiProductRef: {name: claims-api, namespace: $ns}
  planTier: free
  requestedBy: {userId: $user, email: $user@parasol.example}
  useCase: Claims adjuster dashboard integration
  secretRef: {name: $name}
YAML
# Let the controller settle and create the canonical APIKeyRequest.
for i in $(seq 1 15); do
  st=$(oc get apikey "$name" -n "$ns" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null)
  [ "$st" = AwaitingApproval ] && break; sleep 2
done
echo "APIKey state: $(oc get apikey "$name" -n "$ns" -o jsonpath='{.status.conditions[0].type}/{.status.conditions[0].reason}')"
echo "pending key -> HTTP $(code -H "Authorization: APIKEY $key" "$url")   (key not yet active)"

say "STEP 2 (admin): approve — reference the auto-generated APIKeyRequest"
req=$(oc get apikeyrequest -n "$ns" \
  -o jsonpath="{range .items[?(@.spec.apiKeyRef.name=='$name')]}{.metadata.name}{'\n'}{end}" | grep -v "^$name$" | head -1)
echo "canonical request: $req"
cat <<YAML | oc apply -f - >/dev/null
apiVersion: devportal.kuadrant.io/v1alpha1
kind: APIKeyApproval
metadata: {name: $name, namespace: $ns}
spec:
  apiKeyRequestRef: {name: $req}
  approved: true
  reviewedBy: admin
  reviewedAt: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  reason: Approved
  message: Approved for the claims adjuster dashboard integration.
YAML
for i in $(seq 1 15); do
  [ "$(oc get apikey "$name" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Approved")].status}')" = True ] && break; sleep 2
done
echo "APIKey APPROVED: $(oc get apikey "$name" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Approved")].status}')"

say "STEP 3: the approved key now works"
ok=$(code -H "Authorization: APIKEY $key" "$url")
no=$(code "$url")
bad=$(code -H "Authorization: APIKEY wrong-$key" "$url")
echo "approved key -> HTTP $ok   (expect 200)"
echo "no key       -> HTTP $no   (expect 401)"
echo "wrong key    -> HTTP $bad  (expect 401)"

say "RESULT"
if [ "$ok" = 200 ] && [ "$no" = 401 ] && [ "$bad" = 401 ]; then
  echo "PASS: approved key admitted (200), unapproved/absent refused (401)."; exit 0
else
  echo "FAIL: ok=$ok no=$no bad=$bad"; exit 1
fi
