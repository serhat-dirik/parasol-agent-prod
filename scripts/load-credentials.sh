#!/usr/bin/env bash
# Source this: `source scripts/load-credentials.sh [path]`
# Reads the RHDP credentials file (key on one line, value on the next) and exports what the
# bootstrap and demo scripts need. The file itself stays outside the repository and is never printed.
f="${1:-${CREDENTIALS_FILE:-$(dirname "${BASH_SOURCE[0]}")/../../credentials.txt}}"
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
echo "loaded: api=$OCP_API maas=$MAAS_ENDPOINT model=$MAAS_MODEL (secrets not shown)"
