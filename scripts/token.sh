#!/usr/bin/env bash
# token.sh <user>  : print a Keycloak access token for a demo user (password = username), the same
# token the portal gets at login (client parasol-portal, azp=parasol-portal). At the MCP gateway it is
# refused as "not via an approved agent": only an agent's on-behalf-of token gets through.
# The portal client's secret is read from the cluster (Secret parasol-portal-oidc), never printed.
set -euo pipefail
u=${1:?user}; p=${2:-$1}
KC=${KC_URL:-https://sso.apps.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')}
secret=$(oc get secret parasol-portal-oidc -n parasol-secured -o jsonpath='{.data.client-secret}' | base64 -d)
curl -sk -X POST "$KC/realms/parasol/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=parasol-portal --data-urlencode "client_secret=$secret" \
  -d username="$u" -d password="$p" -d scope=openid \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])'
