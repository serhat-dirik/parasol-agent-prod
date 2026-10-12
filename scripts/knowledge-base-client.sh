#!/usr/bin/env bash
# Idempotent: the knowledge base as a resource server in realm 'parasol'. Client parasol-secured/knowledge-base
# with role tool:search_knowledge, granted to adjusters, claims-managers, contractors and developers. Which
# DOCUMENTS each of them may read is not decided here but by the groups claim inside the knowledge base
# (contractors only ever see public documents). Runs before scripts/agent-clients.sh, which puts the tool in
# the claims agent's ceiling. Mirrored into gitops/platform/keycloak/realm-import.yaml. Prints nothing secret.
set -euo pipefail

# shellcheck source=keycloak-admin.sh
. "$(dirname "$0")/keycloak-admin.sh"   # KC_USER / KC_PASS

DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
KC="https://sso.${DOMAIN}"
API="$KC/admin/realms/parasol"
CLIENT=parasol-secured/knowledge-base
ROLE=tool:search_knowledge

TOKEN="$(curl -sk "$KC/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  --data-urlencode "username=$KC_USER" --data-urlencode "password=$KC_PASS" | jq -r .access_token)"
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "failed to get admin token"; exit 1; }
AUTH=(-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json')
kc() { curl -sk "${AUTH[@]}" "$@"; }
cuuid() { kc -G "$API/clients" --data-urlencode "clientId=$1" | jq -r '.[0].id // empty'; }

CU="$(cuuid "$CLIENT")"
if [ -z "$CU" ]; then
  kc -X POST "$API/clients" -d "$(jq -nc --arg c "$CLIENT" '{clientId:$c, name:"knowledge base (resource server)",
    publicClient:true, standardFlowEnabled:false, directAccessGrantsEnabled:false, protocol:"openid-connect",
    enabled:true, fullScopeAllowed:true, defaultClientScopes:["roles"]}')" -o /dev/null -w "client $CLIENT create http=%{http_code}\n"
  CU="$(cuuid "$CLIENT")"
fi
[ -n "$CU" ] || { echo "client $CLIENT missing"; exit 1; }
kc -o /dev/null -w '%{http_code}' "$API/clients/$CU/roles/$(jq -rn --arg r "$ROLE" '$r|@uri')" | grep -q 200 || \
  kc -X POST "$API/clients/$CU/roles" -d "{\"name\":\"$ROLE\",\"clientRole\":true}" -o /dev/null -w "role $ROLE create http=%{http_code}\n"
R="$(kc "$API/clients/$CU/roles/$(jq -rn --arg r "$ROLE" '$r|@uri')")"
for g in adjusters claims-managers contractors developers; do
  gid="$(kc -G "$API/groups" --data-urlencode "search=$g" | jq -r --arg g "$g" '.[] | select(.name==$g) | .id' | head -1)"
  [ -n "$gid" ] || { echo "group $g not found"; exit 1; }
  kc -X POST "$API/groups/$gid/role-mappings/clients/$CU" -d "[$R]" -o /dev/null -w "grant $ROLE to $g http=%{http_code}\n"
done
echo "DONE"
