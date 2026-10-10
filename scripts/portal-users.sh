#!/usr/bin/env bash
# Idempotent: add the 'policyholders' group and the 'tom.becker' policyholder user to realm 'parasol'
# (plan A7, the night-shift customer login). Policyholders get NO tool client-roles: a customer must not
# reach claims tools, so any tool call is a 403 by least privilege. Password equals the username.
# KeycloakRealmImport only creates; the realm already exists, so changes go through the admin REST API
# and are mirrored into gitops/platform/keycloak/realm-import.yaml.
set -euo pipefail

CRED="${CREDENTIALS_FILE:-$(dirname "$0")/../../credentials.txt}"
[ -r "$CRED" ] || { echo "credentials file not found: $CRED"; exit 1; }
_cred() { awk -v k="$1" '$0==k {getline; print; exit}' "$CRED"; }
KC_USER="$(_cred keycloak_admin_user)"
KC_PASS="$(_cred keycloak_admin_password)"

DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
KC="https://sso.${DOMAIN}"
REALM=parasol

TOKEN="$(curl -sk "$KC/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  --data-urlencode "username=$KC_USER" --data-urlencode "password=$KC_PASS" \
  | jq -r .access_token)"
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "failed to get admin token"; exit 1; }
AUTH=(-H "Authorization: Bearer $TOKEN")

# --- group: policyholders ---
GID="$(curl -sk "${AUTH[@]}" "$KC/admin/realms/$REALM/groups?search=policyholders" | jq -r '.[] | select(.name=="policyholders") | .id' | head -1)"
if [ -z "$GID" ]; then
  echo "creating group policyholders..."
  curl -sk "${AUTH[@]}" -X POST "$KC/admin/realms/$REALM/groups" \
    -H 'Content-Type: application/json' -d '{"name":"policyholders"}' \
    -o /dev/null -w "group http=%{http_code}\n"
  GID="$(curl -sk "${AUTH[@]}" "$KC/admin/realms/$REALM/groups?search=policyholders" | jq -r '.[] | select(.name=="policyholders") | .id' | head -1)"
else
  echo "group policyholders exists ($GID)"
fi

# --- user: tom.becker ---
UID_="$(curl -sk "${AUTH[@]}" "$KC/admin/realms/$REALM/users?username=tom.becker&exact=true" | jq -r '.[0].id // empty')"
if [ -z "$UID_" ]; then
  echo "creating user tom.becker..."
  curl -sk "${AUTH[@]}" -X POST "$KC/admin/realms/$REALM/users" -H 'Content-Type: application/json' -d '{
    "username":"tom.becker","enabled":true,"emailVerified":true,
    "firstName":"Tom","lastName":"Becker","email":"tom.becker@customer.example",
    "credentials":[{"type":"password","value":"tom.becker","temporary":false}],
    "requiredActions":[]}' -o /dev/null -w "user http=%{http_code}\n"
  UID_="$(curl -sk "${AUTH[@]}" "$KC/admin/realms/$REALM/users?username=tom.becker&exact=true" | jq -r '.[0].id // empty')"
else
  echo "user tom.becker exists ($UID_)"
fi
[ -n "$UID_" ] && [ -n "$GID" ] || { echo "missing uid/gid"; exit 1; }

echo "joining tom.becker to policyholders..."
curl -sk "${AUTH[@]}" -X PUT "$KC/admin/realms/$REALM/users/$UID_/groups/$GID" \
  -o /dev/null -w "join http=%{http_code}\n"
echo "DONE"
