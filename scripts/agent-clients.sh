#!/usr/bin/env bash
# Idempotent: the agents' own identities in realm 'parasol' (secured path).
#  - identity provider 'openshift-sa' (type Kubernetes): Keycloak trusts this cluster's service-account
#    tokens as client assertions (federated client authentication, no client secret anywhere)
#  - confidential clients parasol-claims-agent (the portal's claims assistant) and parasol-fraud-agent
#    (the fraud-check agent). Each authenticates with its pod's projected ServiceAccount token
#    (subject system:serviceaccount:parasol-secured:<sa>) and may only do standard token exchange:
#    it swaps the user's token for one with sub = the user, azp = the agent.
#  - the agent CEILING: fullScopeAllowed=false + client scope mappings, so an exchanged token carries
#    only the tool roles that are BOTH the user's AND inside the agent's scope
#  - audience mappers so a portal login token can be exchanged by the claims agent, and the claims
#    agent's token by the fraud agent (agent-to-agent)
#  - realm events on (TOKEN_EXCHANGE etc.), so Keycloak > Events shows user + client per exchange
#  - removes the retired 'parasol-agent' (password-grant service identity) and unused 'mcp-gateway' clients
# Mirrored into gitops/platform/keycloak/realm-import.yaml. Nothing secret is created or printed.
set -euo pipefail

# shellcheck source=keycloak-admin.sh
. "$(dirname "$0")/keycloak-admin.sh"   # KC_USER / KC_PASS

DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
KC="https://sso.${DOMAIN}"
API="$KC/admin/realms/parasol"
NS=parasol-secured
SA_ISSUER="$(oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}')"
SA_ISSUER="${SA_ISSUER:-https://kubernetes.default.svc}"

TOKEN="$(curl -sk "$KC/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  --data-urlencode "username=$KC_USER" --data-urlencode "password=$KC_PASS" | jq -r .access_token)"
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "failed to get admin token"; exit 1; }
AUTH=(-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json')
kc() { curl -sk "${AUTH[@]}" "$@"; }
cuuid() { kc -G "$API/clients" --data-urlencode "clientId=$1" | jq -r '.[0].id // empty'; }

# --- identity provider: this cluster's service accounts ---
IDP="$(jq -nc --arg iss "$SA_ISSUER" '{alias:"openshift-sa",displayName:"OpenShift service accounts",
  providerId:"kubernetes",enabled:true,hideOnLogin:true,config:{issuer:$iss}}')"
if kc -o /dev/null -w '%{http_code}' "$API/identity-provider/instances/openshift-sa" | grep -q 200; then
  kc -X PUT "$API/identity-provider/instances/openshift-sa" -d "$IDP" -o /dev/null -w "idp openshift-sa update http=%{http_code}\n"
else
  kc -X POST "$API/identity-provider/instances" -d "$IDP" -o /dev/null -w "idp openshift-sa create http=%{http_code}\n"
fi

# --- agent clients ---
agent() {  # $1 clientId  $2 service account  $3 display name
  local json uuid
  json="$(jq -nc --arg cid "$1" --arg name "$3" --arg sub "system:serviceaccount:$NS:$2" '{
    clientId:$cid, name:$name, enabled:true, protocol:"openid-connect", publicClient:false,
    clientAuthenticatorType:"federated-jwt", serviceAccountsEnabled:true,
    standardFlowEnabled:false, implicitFlowEnabled:false, directAccessGrantsEnabled:false,
    fullScopeAllowed:false,
    attributes:{"standard.token.exchange.enabled":"true",
      "jwt.credential.issuer":"openshift-sa", "jwt.credential.sub":$sub},
    defaultClientScopes:["basic","roles","profile"], optionalClientScopes:[]}')"
  uuid="$(cuuid "$1")"
  if [ -z "$uuid" ]; then
    kc -X POST "$API/clients" -d "$json" -o /dev/null -w "client $1 create http=%{http_code}\n"
  else
    kc -X PUT "$API/clients/$uuid" -d "$json" -o /dev/null -w "client $1 update http=%{http_code}\n"
  fi
}
agent parasol-claims-agent claims-agent "Parasol claims assistant (agent identity)"
agent parasol-fraud-agent fraud-agent "Parasol fraud-check agent (agent identity)"

# --- ceilings: exactly these tool roles, nothing else (extra mappings are removed) ---
ceiling() {  # $1 agent clientId  $2 tool clientId  rest = role names
  local agent="$1" tool="$2"; shift 2
  local au tu want have
  au="$(cuuid "$agent")"; tu="$(cuuid "$tool")"
  [ -n "$au" ] && [ -n "$tu" ] || { echo "client $agent or $tool not found"; exit 1; }
  have="$(kc "$API/clients/$au/scope-mappings/clients/$tu")"
  [ "$(echo "$have" | jq length)" = 0 ] || kc -X DELETE "$API/clients/$au/scope-mappings/clients/$tu" -d "$have" -o /dev/null
  [ $# -gt 0 ] || { echo "ceiling $agent -> $tool: none"; return; }
  want="$(for r in "$@"; do kc "$API/clients/$tu/roles/$(jq -rn --arg r "$r" '$r|@uri')"; done | jq -s -c .)"
  kc -X POST "$API/clients/$au/scope-mappings/clients/$tu" -d "$want" -o /dev/null \
    -w "ceiling $agent -> $tool: $* http=%{http_code}\n"
}
ceiling parasol-claims-agent parasol-secured/claims-db \
  tool:get_claim tool:list_claims_by_status tool:get_claim_history tool:get_claim_documents tool:approve_payout
ceiling parasol-claims-agent parasol-secured/policy-docs tool:search_policies tool:get_policy tool:list_policies
ceiling parasol-claims-agent parasol-secured/fraud-check tool:fraud_check
ceiling parasol-fraud-agent parasol-secured/claims-db tool:get_claim tool:get_claim_history tool:get_claim_documents
ceiling parasol-fraud-agent parasol-secured/policy-docs
ceiling parasol-fraud-agent parasol-secured/fraud-check

# --- audience mappers: who may exchange whose token ---
audience() {  # $1 client that issues/receives the token  $2 audience client added to it
  local u name
  u="$(cuuid "$1")"; name="audience-$2"
  [ -n "$u" ] || { echo "client $1 not found"; exit 1; }
  if kc "$API/clients/$u/protocol-mappers/models" | jq -e --arg n "$name" '.[]|select(.name==$n)' >/dev/null; then
    echo "mapper $1/$name exists"; return
  fi
  kc -X POST "$API/clients/$u/protocol-mappers/models" -d "$(jq -nc --arg n "$name" --arg a "$2" '{name:$n,
    protocol:"openid-connect",protocolMapper:"oidc-audience-mapper",
    config:{"included.client.audience":$a,"access.token.claim":"true","id.token.claim":"false","introspection.token.claim":"true"}}')" \
    -o /dev/null -w "mapper $1/$name http=%{http_code}\n"
}
audience parasol-portal parasol-claims-agent
audience parasol-claims-agent parasol-fraud-agent

# --- realm events: token exchanges (and logins) with user + client on Keycloak > Events ---
kc -X PUT "$API/events/config" -d '{"eventsEnabled":true,"eventsExpiration":604800,"eventsListeners":["jboss-logging"],
  "enabledEventTypes":["TOKEN_EXCHANGE","TOKEN_EXCHANGE_ERROR","LOGIN","LOGIN_ERROR","CODE_TO_TOKEN","CODE_TO_TOKEN_ERROR","CLIENT_LOGIN","CLIENT_LOGIN_ERROR","LOGOUT"],
  "adminEventsEnabled":false}' -o /dev/null -w "realm events http=%{http_code}\n"

# --- retired identities ---
for c in parasol-agent mcp-gateway; do
  u="$(cuuid "$c")"
  [ -z "$u" ] || kc -X DELETE "$API/clients/$u" -o /dev/null -w "delete client $c http=%{http_code}\n"
done
echo "DONE"
