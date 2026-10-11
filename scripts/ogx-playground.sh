#!/usr/bin/env bash
# Stand up the Parasol GenAI Studio playground (OGXServer / Llama Stack distribution) on the agent model.
# Idempotent. Requires: logged in as cluster-admin and the install contract exported
# (AGENT_ENDPOINT, AGENT_KEY, AGENT_MODEL), e.g. `source scripts/load-credentials.sh`.
# AGENT_KEY is placed in a Secret at run time; it is never committed.
set -euo pipefail
: "${AGENT_ENDPOINT:?export the install contract (AGENT_ENDPOINT, AGENT_KEY, AGENT_MODEL) or source scripts/load-credentials.sh}"
: "${AGENT_KEY:?export AGENT_KEY}"
export AGENT_MODEL="${AGENT_MODEL:-qwen3-14b}"
NS=parasol-ogx-playground

kustomize build gitops/platform/ogx/ | envsubst '$AGENT_ENDPOINT $AGENT_MODEL' | oc apply -f -

# API key Secret (keys: token + OPENAI_API_KEY, same value), watched by the operator.
oc create secret generic ogx-maas-key -n "$NS" \
  --from-literal=token="$AGENT_KEY" --from-literal=OPENAI_API_KEY="$AGENT_KEY" \
  --dry-run=client -o yaml | oc apply -f -
oc label secret ogx-maas-key -n "$NS" ogx.io/watch=true --overwrite

# Wait for the operator to generate the Deployment, then inject the API key env
# (overrideConfig mode does not wire secrets, so the key is supplied as env).
oc rollout status deploy/parasol-playground -n "$NS" --timeout=180s || true
oc set env deploy/parasol-playground -n "$NS" --from=secret/ogx-maas-key
# Env from a Secret is read at pod start: restart so a changed key or config is picked up.
oc rollout restart deploy/parasol-playground -n "$NS"
oc rollout status deploy/parasol-playground -n "$NS" --timeout=300s
echo "Playground ready on $AGENT_MODEL. RHOAI dashboard -> Gen AI studio -> Playground, project '$NS'."
