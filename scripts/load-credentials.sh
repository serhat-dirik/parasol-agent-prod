#!/usr/bin/env bash
# Source this: `source scripts/load-credentials.sh [path]`
# Reads the RHDP credentials file (key on one line, value on the next) and exports what the
# bootstrap and demo scripts need. The file itself stays outside the repository and is never printed.
f="${1:-${CREDENTIALS_FILE:-$(dirname "${BASH_SOURCE[0]:-$0}")/../../credentials.txt}}"
[ -r "$f" ] || { echo "credentials file not found: $f (set CREDENTIALS_FILE)"; return 1 2>/dev/null || exit 1; }
_cred() { awk -v k="$1" '$0==k {getline; print; exit}' "$f"; }
export OCP_API="$(_cred openshift_api_server_url)"
export OCP_ADMIN_USER="$(_cred openshift_cluster_admin_username)"
export OCP_ADMIN_PASSWORD="$(_cred openshift_cluster_admin_password)"
export MAAS_ENDPOINT="$(_cred litellm_api_base_url)"
export MAAS_API_KEY="$(_cred litellm_user1_virtual_key)"
export MAAS_MODEL="${MAAS_MODEL:-$(_cred litellm_available_models_list | cut -d, -f1)}"
export KEYCLOAK_ADMIN_URL="$(_cred keycloak_admin_console)"
export KEYCLOAK_ADMIN_USER="$(_cred keycloak_admin_user)"
export KEYCLOAK_ADMIN_PASSWORD="$(_cred keycloak_admin_password)"
unset -f _cred
# Per-model MaaS keys from the "MAAS keys" section: each curl sample pairs a model with its own
# Bearer key. Exported as MAAS_KEY_<MODEL>, mapped to the contract below. Values are never printed.
while IFS='=' read -r _v _k; do [ -n "$_v" ] && export "$_v=$_k"; done < <(python3 -I -c '
import re,sys
key=None
for line in open(sys.argv[1]):
    m=re.search(r"Bearer\s+(sk-[A-Za-z0-9_-]+)",line)
    if m: key=m.group(1)
    mm=re.search(r"\"model\"\s*:\s*\"([^\"]+)\"",line)
    if mm and key:
        print("MAAS_KEY_"+re.sub(r"[^A-Z0-9]","_",mm.group(1).upper())+"="+key); key=None
' "$f")
# PRIVATE LAB HELPER. The install contract is per model: <ROLE>_ENDPOINT + <ROLE>_KEY (see bootstrap.sh).
# On this lab every model sits behind the same LiteLLM base URL, so all endpoints are that URL; each key
# is the model's own key from the "MAAS keys" section. Llama-Guard is optional: its pair is exported only
# when its key is present.
export AGENT_MODEL="${AGENT_MODEL:-qwen3-14b}"
export AGENT_ENDPOINT="$MAAS_ENDPOINT"      AGENT_KEY="${MAAS_KEY_QWEN3_14B:-}"               # agent (both portals)
export GUARD_ENDPOINT="$MAAS_ENDPOINT"      GUARD_KEY="${MAAS_KEY_GRANITE_GUARDIAN_3_1_8B:-}" # granite-guardian detector
export JUDGE_ENDPOINT="$MAAS_ENDPOINT"      JUDGE_KEY="${MAAS_KEY_GPT_OSS_120B:-}"            # gpt-oss-120b eval judge
unset LLAMAGUARD_ENDPOINT LLAMAGUARD_KEY
[ -n "${MAAS_KEY_LLAMA_GUARD_3_1B:-}" ] && export LLAMAGUARD_ENDPOINT="$MAAS_ENDPOINT" LLAMAGUARD_KEY="$MAAS_KEY_LLAMA_GUARD_3_1B"
echo "loaded: api=$OCP_API maas=$MAAS_ENDPOINT agent=$AGENT_MODEL (secrets not shown)"
echo "model keys set: $(for v in AGENT_KEY GUARD_KEY JUDGE_KEY LLAMAGUARD_KEY; do [ -n "${!v:-}" ] && printf '%s ' "$v"; done)"
