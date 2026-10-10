#!/usr/bin/env bash
# maas-ext-model-secrets.sh : create the upstream (LiteLLM) API-key Secrets that the granite ExternalModels
# reference via credentialRef. Data key is "api-key" (the format the MaaS ExternalProvider expects, same as
# maas-upstream-api-key). Keys come from the credentials file via load-credentials.sh (MAAS_KEY_STAGE =
# granite-4-0-h-tiny, MAAS_KEY_GUARD = granite-guardian-3-1-8b). Values are never printed or committed.
#   Secret maas-upstream-granite-tiny      -> granite-4-0-h-tiny
#   Secret maas-upstream-granite-guardian  -> granite-guardian-3-1-8b
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-/Users/hdirik/RHSA/RedHatSASupport/AgentsInProd/credentials.txt}" \
  source "$here/load-credentials.sh" >/dev/null
NS=models-as-a-service
[[ -n "${MAAS_KEY_STAGE:-}" && -n "${MAAS_KEY_GUARD:-}" ]] || { echo "missing per-model keys (MAAS_KEY_STAGE / MAAS_KEY_GUARD)"; exit 1; }
oc -n "$NS" create secret generic maas-upstream-granite-tiny \
  --from-literal=api-key="$MAAS_KEY_STAGE" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc -n "$NS" create secret generic maas-upstream-granite-guardian \
  --from-literal=api-key="$MAAS_KEY_GUARD" --dry-run=client -o yaml | oc apply -f - >/dev/null
echo "upstream secrets written in $NS: maas-upstream-granite-tiny, maas-upstream-granite-guardian"
