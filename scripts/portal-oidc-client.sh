#!/usr/bin/env bash
# Idempotent: create/update the 'parasol-portal' confidential OIDC client in realm 'parasol'
# (quarkus-oidc web-app for the portal login), and mirror its secret into a k8s Secret in
# parasol-free and parasol-secured. The client secret is NEVER printed or committed.
# Direct grants are on for the scripted persona logins (scripts/token.sh): same token shape as a browser
# login, and the client is confidential, so it needs the secret that only the cluster holds.
# Usage: scripts/portal-oidc-client.sh   (oc login as admin; Keycloak admin login via scripts/keycloak-admin.sh)
set -euo pipefail

# shellcheck source=keycloak-admin.sh
. "$(dirname "$0")/keycloak-admin.sh"   # KC_USER / KC_PASS

DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
KC="https://sso.${DOMAIN}"
REALM=parasol
CLIENT_ID=parasol-portal
SECRET_NAME=parasol-portal-oidc

echo "keycloak=$KC realm=$REALM client=$CLIENT_ID"

TOKEN="$(curl -sk "$KC/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  --data-urlencode "username=$KC_USER" --data-urlencode "password=$KC_PASS" \
  | jq -r .access_token)"
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "failed to get admin token"; exit 1; }

REDIRECTS="$(jq -nc --arg d "$DOMAIN" '[
  "https://portal-free."+$d+"/*",
  "https://portal."+$d+"/*"
]')"
ORIGINS="$(jq -nc --arg d "$DOMAIN" '[
  "https://portal-free."+$d,
  "https://portal."+$d
]')"

CLIENT_JSON="$(jq -nc \
  --arg cid "$CLIENT_ID" \
  --argjson redirects "$REDIRECTS" \
  --argjson origins "$ORIGINS" \
  '{clientId:$cid, name:"Parasol claims portal (web-app)", enabled:true,
    protocol:"openid-connect", publicClient:false, standardFlowEnabled:true,
    directAccessGrantsEnabled:true, serviceAccountsEnabled:false,
    redirectUris:$redirects, webOrigins:$origins, fullScopeAllowed:true,
    attributes:{"post.logout.redirect.uris":"+"},
    defaultClientScopes:["roles","profile","email"],
    optionalClientScopes:["groups"]}')"

UUID="$(curl -sk "$KC/admin/realms/$REALM/clients?clientId=$CLIENT_ID" \
  -H "Authorization: Bearer $TOKEN" | jq -r '.[0].id // empty')"

if [ -z "$UUID" ]; then
  echo "creating client..."
  curl -sk -X POST "$KC/admin/realms/$REALM/clients" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "$CLIENT_JSON" -o /dev/null -w "create http=%{http_code}\n"
  UUID="$(curl -sk "$KC/admin/realms/$REALM/clients?clientId=$CLIENT_ID" \
    -H "Authorization: Bearer $TOKEN" | jq -r '.[0].id // empty')"
else
  echo "client exists ($UUID), updating config..."
  curl -sk -X PUT "$KC/admin/realms/$REALM/clients/$UUID" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "$CLIENT_JSON" -o /dev/null -w "update http=%{http_code}\n"
fi
[ -n "$UUID" ] || { echo "client uuid not found after create"; exit 1; }

SECRET="$(curl -sk "$KC/admin/realms/$REALM/clients/$UUID/client-secret" \
  -H "Authorization: Bearer $TOKEN" | jq -r '.value // empty')"
[ -n "$SECRET" ] || { echo "no client secret returned"; exit 1; }
echo "client secret retrieved (length ${#SECRET})"

AUTH_URL="$KC/realms/$REALM"
for NS in parasol-free parasol-secured; do
  oc create secret generic "$SECRET_NAME" -n "$NS" \
    --from-literal=client-id="$CLIENT_ID" \
    --from-literal=client-secret="$SECRET" \
    --from-literal=auth-server-url="$AUTH_URL" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  echo "secret $SECRET_NAME applied in $NS"
done
echo "DONE"
