#!/usr/bin/env bash
# Agent kill switch: disable one agent the way you disable a user. Switches the agent's Keycloak client in
# realm parasol (Clients > parasol-<agent> > Enabled) off or on. While it is off, Keycloak refuses the agent's
# client authentication (401 invalid_client), so it can no longer exchange anyone's token: no tool call for
# any user. The claims portal checks this at the start of every chat turn and answers "This assistant has
# been disabled by an operator." without asking the model. Other agents and every user keep working.
#   claims-agent  parasol-claims-agent  the portal's claims assistant (and the REST agent)
#   fraud-agent   parasol-fraud-agent   the fraud-check agent behind the fraud_check tool
# Signs in as the parasol realm administrator (admin, realm parasol only; never the master admin). Override
# with PARASOL_REALM_ADMIN / PARASOL_REALM_ADMIN_PASS.
# Usage: scripts/agent-switch.sh claims-agent|fraud-agent off|on|status
set -euo pipefail
case "${1:-}" in claims-agent|fraud-agent) ;; *) echo "usage: $0 claims-agent|fraud-agent off|on|status"; exit 2;; esac
CLIENT="parasol-$1" SA="system:serviceaccount:parasol-secured:$1"
KC=${KC_URL:-https://sso.apps.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')}
API="$KC/admin/realms/parasol"
TOKEN="$(curl -sk "$KC/realms/parasol/protocol/openid-connect/token" -d grant_type=password -d client_id=admin-cli \
  --data-urlencode "username=${PARASOL_REALM_ADMIN:-admin}" --data-urlencode "password=${PARASOL_REALM_ADMIN_PASS:-admin}" \
  | jq -r '.access_token // empty')"
[ -n "$TOKEN" ] || { echo "realm parasol admin login failed"; exit 1; }
kc() { curl -sk -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' "$@"; }
ID="$(kc -G "$API/clients" --data-urlencode "clientId=$CLIENT" | jq -r '.[0].id // empty')"
[ -n "$ID" ] || { echo "client $CLIENT not found"; exit 1; }

case "${2:-status}" in
  off|on)
    want=$([ "$2" = on ] && echo true || echo false)
    kc "$API/clients/$ID" | jq -c --argjson e "$want" '.enabled=$e' | kc -X PUT "$API/clients/$ID" -d @- -o /dev/null -w "$CLIENT enabled=$want http=%{http_code}\n" ;;
  status) ;;
  *) echo "usage: $0 claims-agent|fraud-agent off|on|status"; exit 2 ;;
esac
echo "$CLIENT enabled=$(kc "$API/clients/$ID" | jq -r .enabled)"
# who was refused: a disabled client is "not found" to Keycloak; the event names the agent's ServiceAccount
echo "recent refusals (Keycloak > Events, CLIENT_LOGIN_ERROR / TOKEN_EXCHANGE_ERROR):"
kc "$API/events?max=200&type=CLIENT_LOGIN_ERROR&type=TOKEN_EXCHANGE_ERROR" | jq -r --arg c "$CLIENT" --arg s "$SA" '
  [.[] | select(.clientId==$c or .details.client_assertion_sub==$s)][:5][]
  | "  \(.time/1000|todate) \(.type) error=\(.error) grant=\(.details.grant_type // "-") sa=\(.details.client_assertion_sub // "-")"'
