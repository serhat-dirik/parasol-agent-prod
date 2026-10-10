#!/usr/bin/env bash
# Create the out-of-band Secret maas-guardian in ns parasol-guardian for the Granite Guardian
# second-detector. Reads the MaaS base + a virtual key from the credentials file and never prints
# their values. NOT in Git (the Secret is created imperatively, like S4's maas-nemo).
#
#   GUARD TIER (real, when a guard-capable key exists):
#       GUARD_MODEL=granite-guardian-3-1-8b, key = the guard-tier virtual key, no GUARD_PROMPT.
#   STAND-IN (default here — no guard-capable key / no GPU on this lab):
#       GUARD_MODEL=llama-scout-17b + a guardian classifier prompt, key = evaluation key 2.
#
# Usage: scripts/guardian-key.sh            # stand-in (key 2 -> llama-scout)
#        GUARD_KEY_FIELD=litellm_userN_virtual_key scripts/guardian-key.sh   # a guard-capable key
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
