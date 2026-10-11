#!/usr/bin/env bash
# maas-ext-model-secrets.sh : create the upstream API-key Secrets that the external models reference via
# credentialRef. Data key is "api-key" (the format the MaaS ExternalProvider expects). Keys come from the
# install contract env (bootstrap.sh): AGENT_KEY -> qwen3-14b, GUARD_KEY -> granite-guardian-3-1-8b.
# Values are never printed or committed.
#   Secret maas-upstream-qwen3-14b         -> qwen3-14b (the agent model both portals run)
#   Secret maas-upstream-granite-guardian  -> granite-guardian-3-1-8b (guard-tier detector)
set -euo pipefail
: "${AGENT_KEY:?set AGENT_KEY (or source scripts/load-credentials.sh)}"
: "${GUARD_KEY:?set GUARD_KEY (or source scripts/load-credentials.sh)}"
NS=models-as-a-service
oc -n "$NS" create secret generic maas-upstream-qwen3-14b \
  --from-literal=api-key="$AGENT_KEY" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc -n "$NS" create secret generic maas-upstream-granite-guardian \
  --from-literal=api-key="$GUARD_KEY" --dry-run=client -o yaml | oc apply -f - >/dev/null
# REQUIRED: the ai-gateway apikey-injection plugin only loads upstream-key Secrets carrying this label
# into its credential store; without it the gateway returns 500 "credentials not found in store".
oc -n "$NS" label secret maas-upstream-qwen3-14b maas-upstream-granite-guardian \
  inference.llm-d.ai/ipp-managed=true --overwrite >/dev/null
echo "upstream secrets written in $NS: maas-upstream-qwen3-14b, maas-upstream-granite-guardian"
