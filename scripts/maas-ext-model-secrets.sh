#!/usr/bin/env bash
# maas-ext-model-secrets.sh : create the upstream API-key Secrets that the external models reference via
# credentialRef. Data key is "api-key" (the format the MaaS ExternalProvider expects). Keys come from the
# install contract env (bootstrap.sh): AGENT_KEY -> the agent model (AGENT_MODEL), GUARD_KEY -> the guard model
# (GUARD_MODEL). The Secret names are fixed role names: they do not change with the model.
# Values are never printed or committed.
#   Secret maas-upstream-qwen3-14b         -> AGENT_MODEL (the agent model both portals run; default qwen3-14b)
#   Secret maas-upstream-granite-guardian  -> GUARD_MODEL (guard-tier detector; default granite-guardian-3-1-8b)
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
