#!/usr/bin/env bash
# Create the out-of-band Secret maas-guardian in ns parasol-guardian. It supplies the guard models' base
# URLs to the guardian-detector: GUARD_URL <- GUARD_ENDPOINT (granite-guardian) and, only when set,
# GUARD2_URL <- LLAMAGUARD_ENDPOINT (optional Llama-Guard). The keys the detector uses come from the
# per-model Secrets maas-key-granite-guardian / maas-key-llama-guard (scripts/maas-model-keys.sh);
# GUARD_KEY here is a legacy fallback copy of GUARD_KEY. Values are never printed. NOT in Git.
#
# Usage: scripts/guardian-key.sh   (with GUARD_ENDPOINT, GUARD_KEY [, LLAMAGUARD_ENDPOINT] exported)
set -euo pipefail
: "${GUARD_ENDPOINT:?set GUARD_ENDPOINT (or source scripts/load-credentials.sh)}"
: "${GUARD_KEY:?set GUARD_KEY (or source scripts/load-credentials.sh)}"
args=(--from-literal=GUARD_URL="$GUARD_ENDPOINT" --from-literal=GUARD_KEY="$GUARD_KEY")
[ -n "${LLAMAGUARD_ENDPOINT:-}" ] && args+=(--from-literal=GUARD2_URL="$LLAMAGUARD_ENDPOINT")
oc create secret generic maas-guardian -n parasol-guardian "${args[@]}" \
  --dry-run=client -o yaml | oc apply -f -
echo "secret maas-guardian applied (values not shown)"
