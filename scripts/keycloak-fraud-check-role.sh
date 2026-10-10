#!/usr/bin/env bash
# V3: add the fraud-check resource-server client + tool:fraud_check role to realm 'parasol' and grant it
# to the adjusters and claims-managers groups (rebecca, marcus). Policyholders (tom.becker) get nothing,
# so a customer calling fraud_check is a 403 by least privilege - the same per-identity authz as every
# other MCP tool. KeycloakRealmImport only creates; the realm already exists, so this runs against the
# admin REST API. Mirrored into gitops/platform/keycloak/realm-import.yaml. Idempotent.
set -euo pipefail

CRED="${CREDENTIALS_FILE:-$(dirname "$0")/../../credentials.txt}"
[ -r "$CRED" ] || { echo "credentials file not found: $CRED"; exit 1; }
_cred() { awk -v k="$1" '$0==k {getline; print; exit}' "$CRED"; }
KC_USER="$(_cred keycloak_admin_user)"
KC_PASS="$(_cred keycloak_admin_password)"

DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
KC="https://sso.${DOMAIN}"
REALM=parasol
CLIENT_ID="parasol-secured/fraud-check"
ROLE="tool:fraud_check"

TOKEN="$(curl -sk "$KC/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  --data-urlencode "username=$KC_USER" --data-urlencode "password=$KC_PASS" \
  | jq -r .access_token)"
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "failed to get admin token"; exit 1; }
AUTH=(-H "Authorization: Bearer $TOKEN")

# --- client: parasol-secured/fraud-check ---
CUUID="$(curl -sk "${AUTH[@]}" -G "$KC/admin/realms/$REALM/clients" --data-urlencode "clientId=$CLIENT_ID" | jq -r '.[0].id // empty')"
if [ -z "$CUUID" ]; then
  echo "creating client $CLIENT_ID..."
  curl -sk "${AUTH[@]}" -X POST "$KC/admin/realms/$REALM/clients" -H 'Content-Type: application/json' -d "{
    \"clientId\":\"$CLIENT_ID\",\"name\":\"fraud-check agent (resource server)\",
    \"publicClient\":true,\"standardFlowEnabled\":false,\"directAccessGrantsEnabled\":false,
    \"protocol\":\"openid-connect\",\"enabled\":true,\"fullScopeAllowed\":true}" \
    -o /dev/null -w "client http=%{http_code}\n"
  CUUID="$(curl -sk "${AUTH[@]}" -G "$KC/admin/realms/$REALM/clients" --data-urlencode "clientId=$CLIENT_ID" | jq -r '.[0].id // empty')"
else
  echo "client $CLIENT_ID exists ($CUUID)"
fi
[ -n "$CUUID" ] || { echo "missing client uuid"; exit 1; }

# --- client role: tool:fraud_check ---
if ! curl -sk "${AUTH[@]}" "$KC/admin/realms/$REALM/clients/$CUUID/roles/$ROLE" | jq -e '.name' >/dev/null 2>&1; then
  echo "creating role $ROLE..."
  curl -sk "${AUTH[@]}" -X POST "$KC/admin/realms/$REALM/clients/$CUUID/roles" \
    -H 'Content-Type: application/json' -d "{\"name\":\"$ROLE\",\"clientRole\":true}" \
    -o /dev/null -w "role http=%{http_code}\n"
else
  echo "role $ROLE exists"
fi
ROLE_JSON="$(curl -sk "${AUTH[@]}" "$KC/admin/realms/$REALM/clients/$CUUID/roles/$ROLE")"
RID="$(echo "$ROLE_JSON" | jq -r '.id')"
[ -n "$RID" ] && [ "$RID" != null ] || { echo "missing role id"; exit 1; }

# --- grant the role to groups adjusters + claims-managers ---
grant() {
  local gname="$1"
  local gid
  gid="$(curl -sk "${AUTH[@]}" -G "$KC/admin/realms/$REALM/groups" --data-urlencode "search=$gname" | jq -r ".[] | select(.name==\"$gname\") | .id" | head -1)"
  [ -n "$gid" ] || { echo "group $gname not found"; exit 1; }
  echo "granting $ROLE to group $gname ($gid)..."
  curl -sk "${AUTH[@]}" -X POST "$KC/admin/realms/$REALM/groups/$gid/role-mappings/clients/$CUUID" \
    -H 'Content-Type: application/json' -d "[{\"id\":\"$RID\",\"name\":\"$ROLE\",\"clientRole\":true,\"containerId\":\"$CUUID\"}]" \
    -o /dev/null -w "grant $gname http=%{http_code}\n"
}
grant adjusters
grant claims-managers
echo "DONE"
