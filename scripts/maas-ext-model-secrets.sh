#!/usr/bin/env bash
# maas-ext-model-secrets.sh : create the upstream (LiteLLM) API-key Secrets that the external models
# reference via credentialRef. Data key is "api-key" (the format the MaaS ExternalProvider expects, same as
# maas-upstream-api-key). Keys come from the credentials file via load-credentials.sh (MAAS_KEY_QWEN3_14B =
# qwen3-14b, MAAS_KEY_GUARD = granite-guardian-3-1-8b). Values are never printed or committed.
#   Secret maas-upstream-qwen3-14b         -> qwen3-14b (the agent model both portals run)
#   Secret maas-upstream-granite-guardian  -> granite-guardian-3-1-8b (guard-tier detector)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-/Users/hdirik/RHSA/RedHatSASupport/AgentsInProd/credentials.txt}" \
  source "$here/load-credentials.sh" >/dev/null
NS=models-as-a-service
[[ -n "${MAAS_KEY_QWEN3_14B:-}" && -n "${MAAS_KEY_GUARD:-}" ]] || { echo "missing per-model keys (MAAS_KEY_QWEN3_14B / MAAS_KEY_GUARD)"; exit 1; }
oc -n "$NS" create secret generic maas-upstream-qwen3-14b \
  --from-literal=api-key="$MAAS_KEY_QWEN3_14B" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc -n "$NS" create secret generic maas-upstream-granite-guardian \
  --from-literal=api-key="$MAAS_KEY_GUARD" --dry-run=client -o yaml | oc apply -f - >/dev/null
# REQUIRED: the ai-gateway apikey-injection plugin only loads upstream-key Secrets carrying this label
# into its credential store; without it the gateway returns 500 "credentials not found in store".
oc -n "$NS" label secret maas-upstream-qwen3-14b maas-upstream-granite-guardian \
  inference.llm-d.ai/ipp-managed=true --overwrite >/dev/null
echo "upstream secrets written in $NS: maas-upstream-qwen3-14b, maas-upstream-granite-guardian"
