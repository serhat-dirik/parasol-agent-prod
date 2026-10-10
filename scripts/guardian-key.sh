#!/usr/bin/env bash
# Create the out-of-band Secret maas-guardian in ns parasol-guardian. It supplies the MaaS base URL
# (GUARD_URL) to the guardian-detector. The REAL guard-tier API keys come from P1-MAAS-TIERS's own
# Secrets (maas-key-granite-guardian, maas-key-llama-guard, data key GENAI_API_KEY) — this script does
# NOT mint those. GUARD_KEY here is a legacy fallback key (only used if those per-model Secrets are
# absent) and is never printed. NOT in Git (created imperatively, like S4's maas-nemo).
#
# Usage: scripts/guardian-key.sh
set -euo pipefail
f="${CREDENTIALS_FILE:-/Users/hdirik/RHSA/RedHatSASupport/AgentsInProd/credentials.txt}"
cred() { awk -v k="$1" '$0==k {getline; print; exit}' "$f"; }
BASE="$(cred litellm_api_base_url)"
KEY="$(cred "${GUARD_KEY_FIELD:-litellm_user2_virtual_key}")"
oc create secret generic maas-guardian -n parasol-guardian \
  --from-literal=GUARD_URL="$BASE" \
  --from-literal=GUARD_KEY="$KEY" \
  --dry-run=client -o yaml | oc apply -f -
echo "secret maas-guardian applied (values not shown)"
