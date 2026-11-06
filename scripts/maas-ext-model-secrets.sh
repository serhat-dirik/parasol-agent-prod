#!/usr/bin/env bash
# maas-ext-model-secrets.sh : create the upstream API-key Secrets that the external models reference via
# credentialRef. Data key is "api-key" (the format the MaaS ExternalProvider expects). Keys come from the
# install contract env (bootstrap.sh): AGENT_KEY -> the agent model (AGENT_MODEL), GUARD_KEY -> the guard model
# (GUARD_MODEL), JUDGE_KEY -> the evaluation judge (JUDGE_MODEL). The Secret names are fixed role names: they do
# not change with the model.
# Values are never printed or committed.
#   Secret maas-upstream-qwen3-14b         -> AGENT_MODEL (the agent model both portals run; default qwen3-14b)
#   Secret maas-upstream-granite-guardian  -> GUARD_MODEL (guard-tier detector; default granite-guardian-3-1-8b)
#   Secret maas-upstream-judge             -> JUDGE_MODEL (evaluation judge; default gpt-oss-120b; skipped without JUDGE_KEY)
set -euo pipefail
: "${AGENT_KEY:?set AGENT_KEY (or source scripts/load-credentials.sh)}"
: "${GUARD_KEY:?set GUARD_KEY (or source scripts/load-credentials.sh)}"
NS=models-as-a-service
oc -n "$NS" create secret generic maas-upstream-qwen3-14b \
  --from-literal=api-key="$AGENT_KEY" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc -n "$NS" create secret generic maas-upstream-granite-guardian \
  --from-literal=api-key="$GUARD_KEY" --dry-run=client -o yaml | oc apply -f - >/dev/null
names="maas-upstream-qwen3-14b maas-upstream-granite-guardian"
if [ -n "${JUDGE_KEY:-}" ]; then
  oc -n "$NS" create secret generic maas-upstream-judge \
    --from-literal=api-key="$JUDGE_KEY" --dry-run=client -o yaml | oc apply -f - >/dev/null
  names="$names maas-upstream-judge"
fi
# REQUIRED: the ai-gateway apikey-injection plugin only loads upstream-key Secrets carrying this label
# into its credential store; without it the gateway returns 500 "credentials not found in store".
oc -n "$NS" label secret $names inference.llm-d.ai/ipp-managed=true --overwrite >/dev/null
# An ExternalProvider created before its Secret stays Failed ("secret not found") until something requeues it;
# touch every provider so a re-run (or an upgrade that adds a model) heals that without manual steps.
for p in $(oc get externalprovider -n "$NS" -o name 2>/dev/null); do
  oc annotate -n "$NS" "$p" parasol.example/secrets-written="$(date +%s)" --overwrite >/dev/null
done
echo "upstream secrets written in $NS: $names"
