#!/usr/bin/env bash
# token.sh <user>  : print a Keycloak access token for a demo user (password = username), logged in
# headlessly through the public client parasol-demo-cli (password grant only; the portal client
# parasol-portal is browser-only). At the MCP gateway this token is refused as "not via an approved
# agent" (azp=parasol-demo-cli): only an agent's on-behalf-of token gets through (scripts/agent-token.sh).
# Scope groups: the token names the user's groups, like a portal login does.
set -euo pipefail
u=${1:?user}; p=${2:-$1}
KC=${KC_URL:-https://sso.apps.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')}
curl -sk -X POST "$KC/realms/parasol/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=parasol-demo-cli \
  -d username="$u" --data-urlencode "password=$p" -d "scope=openid groups" \
  | python3 -c 'import sys,json; r=json.load(sys.stdin); print(r["access_token"]) if "access_token" in r else sys.exit("login failed: %s" % r.get("error_description", r))'
