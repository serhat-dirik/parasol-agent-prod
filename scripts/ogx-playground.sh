#!/usr/bin/env bash
# Stand up the Parasol GenAI Studio playground (OGXServer / Llama Stack distribution).
# Idempotent. Requires: logged in as cluster-admin, credentials loaded, e.g.
#   CREDENTIALS_FILE=../credentials.txt source scripts/load-credentials.sh
# The MaaS key (LiteLLM virtual key 2, for eval/manual surfaces) is read from the
# credentials file and placed in a Secret; it is never committed.
set -euo pipefail
NS=parasol-ogx-playground
CRED="${CREDENTIALS_FILE:-../credentials.txt}"
KEY=$(awk '/^litellm_user2_virtual_key[[:space:]]*$/{getline; print; exit}' "$CRED" | tr -d '\n')
[ -n "$KEY" ] || { echo "ERR: litellm_user2_virtual_key not found in $CRED"; exit 1; }

oc apply -k gitops/platform/ogx/

# MaaS key Secret (keys: token + OPENAI_API_KEY, same value), watched by the operator.
oc create secret generic ogx-maas-key -n "$NS" \
  --from-literal=token="$KEY" --from-literal=OPENAI_API_KEY="$KEY" \
  --dry-run=client -o yaml | oc apply -f -
oc label secret ogx-maas-key -n "$NS" ogx.io/watch=true --overwrite

# Wait for the operator to generate the Deployment, then inject the API key env
# (overrideConfig mode does not wire secrets, so the key is supplied as env).
oc rollout status deploy/parasol-playground -n "$NS" --timeout=180s || true
oc set env deploy/parasol-playground -n "$NS" --from=secret/ogx-maas-key
oc rollout status deploy/parasol-playground -n "$NS" --timeout=180s
echo "Playground ready. RHOAI dashboard -> Gen AI studio -> Playground, project '$NS'."
