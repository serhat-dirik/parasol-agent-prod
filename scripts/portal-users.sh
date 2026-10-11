#!/usr/bin/env bash
# Idempotent: add the 'contractors' group and the 'nina.contractor' user to realm 'parasol' (the
# night-shift login: an outsourced contractor on the employee claims portal). Contractors get READ-ONLY
# claim and policy tools; no approve_payout and no fraud_check, so those are a 403 by least privilege.
# Password equals the username. Also removes the retired 'tom.becker' user and 'policyholders' group.
# KeycloakRealmImport only creates; the realm already exists, so changes go through the admin REST API
# and are mirrored into gitops/platform/keycloak/realm-import.yaml.
set -euo pipefail

# shellcheck source=keycloak-admin.sh
. "$(dirname "$0")/keycloak-admin.sh"   # KC_USER / KC_PASS

DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
KC="https://sso.${DOMAIN}"
REALM=parasol
API="$KC/admin/realms/$REALM"

TOKEN="$(curl -sk "$KC/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  --data-urlencode "username=$KC_USER" --data-urlencode "password=$KC_PASS" \
  | jq -r .access_token)"
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "failed to get admin token"; exit 1; }
AUTH=(-H "Authorization: Bearer $TOKEN")

group_id() { curl -sk "${AUTH[@]}" -G "$API/groups" --data-urlencode "search=$1" | jq -r ".[] | select(.name==\"$1\") | .id" | head -1; }
user_id()  { curl -sk "${AUTH[@]}" "$API/users?username=$1&exact=true" | jq -r '.[0].id // empty'; }

# --- retire the old policyholder persona ---
OLD_UID="$(user_id tom.becker)"
[ -z "$OLD_UID" ] || curl -sk "${AUTH[@]}" -X DELETE "$API/users/$OLD_UID" -o /dev/null -w "delete user tom.becker http=%{http_code}\n"
OLD_GID="$(group_id policyholders)"
[ -z "$OLD_GID" ] || curl -sk "${AUTH[@]}" -X DELETE "$API/groups/$OLD_GID" -o /dev/null -w "delete group policyholders http=%{http_code}\n"

# --- group: contractors ---
GID="$(group_id contractors)"
if [ -z "$GID" ]; then
  curl -sk "${AUTH[@]}" -X POST "$API/groups" -H 'Content-Type: application/json' -d '{"name":"contractors"}' \
    -o /dev/null -w "create group contractors http=%{http_code}\n"
  GID="$(group_id contractors)"
else
  echo "group contractors exists ($GID)"
fi
[ -n "$GID" ] || { echo "missing group id"; exit 1; }

# --- read-only client roles for contractors ---
grant() {  # $1 = clientId, rest = role names
  local client="$1"; shift
  local cuuid roles
  cuuid="$(curl -sk "${AUTH[@]}" -G "$API/clients" --data-urlencode "clientId=$client" | jq -r '.[0].id // empty')"
  [ -n "$cuuid" ] || { echo "client $client not found"; exit 1; }
  roles="$(for r in "$@"; do curl -sk "${AUTH[@]}" "$API/clients/$cuuid/roles/$(jq -rn --arg r "$r" '$r|@uri')"; done | jq -s -c .)"
  curl -sk "${AUTH[@]}" -X POST "$API/groups/$GID/role-mappings/clients/$cuuid" -H 'Content-Type: application/json' \
    -d "$roles" -o /dev/null -w "grant $client http=%{http_code}\n"
}
grant parasol-secured/claims-db tool:get_claim tool:list_claims_by_status tool:get_claim_history tool:get_claim_documents
grant parasol-secured/policy-docs tool:search_policies tool:get_policy tool:list_policies
grant mcp-gateway impersonator

# --- user: nina.contractor ---
UID_="$(user_id nina.contractor)"
if [ -z "$UID_" ]; then
  curl -sk "${AUTH[@]}" -X POST "$API/users" -H 'Content-Type: application/json' -d '{
    "username":"nina.contractor","enabled":true,"emailVerified":true,
    "firstName":"Nina","lastName":"Patel","email":"nina.contractor@parasol.example",
    "credentials":[{"type":"password","value":"nina.contractor","temporary":false}],
    "requiredActions":[]}' -o /dev/null -w "create user nina.contractor http=%{http_code}\n"
  UID_="$(user_id nina.contractor)"
else
  echo "user nina.contractor exists ($UID_)"
fi
[ -n "$UID_" ] || { echo "missing user id"; exit 1; }

curl -sk "${AUTH[@]}" -X PUT "$API/users/$UID_/groups/$GID" -o /dev/null -w "join nina.contractor to contractors http=%{http_code}\n"
echo "DONE"
