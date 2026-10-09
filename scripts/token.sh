#!/usr/bin/env bash
# token.sh <user>  : print a Keycloak access token for a demo user (password = username)
set -euo pipefail
u=${1:?user}; p=${2:-$1}
KC=${KC_URL:-https://sso.apps.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')}
curl -sk -X POST "$KC/realms/parasol/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=parasol-agent -d username="$u" -d password="$p" -d scope=openid \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])'
