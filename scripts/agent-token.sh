#!/usr/bin/env bash
# agent-token.sh <user> [agent]  : print the token an agent would present for <user> at the MCP gateway:
# the user's login token (scripts/token.sh) exchanged at Keycloak by the agent (default claims-agent ->
# parasol-claims-agent; fraud-agent -> parasol-fraud-agent, chained through the claims agent as in
# production). The agent authenticates with a short-lived token of its ServiceAccount in parasol-secured,
# exactly like the pod does. sub = the user, azp = the agent, roles = the user's AND the agent's ceiling.
set -euo pipefail
u=${1:?user}; agent=${2:-claims-agent}
here="$(dirname "$0")"
KC=${KC_URL:-https://sso.apps.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')}
exchange() {  # exchange <service account> <subject token>
  local a; a=$(oc create token "$1" -n parasol-secured --audience="$KC/realms/parasol" --duration=10m)
  curl -sk -X POST "$KC/realms/parasol/protocol/openid-connect/token" \
    -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer --data-urlencode "client_assertion=$a" \
    --data-urlencode "subject_token=$2" -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
    | python3 -c 'import sys,json; r=json.load(sys.stdin); print(r["access_token"]) if "access_token" in r else sys.exit("exchange failed: %s" % r.get("error_description", r))'
}
t=$(exchange claims-agent "$("$here/token.sh" "$u")")
[ "$agent" = fraud-agent ] && t=$(exchange fraud-agent "$t")
echo "$t"
