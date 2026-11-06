#!/usr/bin/env bash
# Layered kill switch. Each level stops a wider circle and is undone by "on"; nothing in Git changes.
#   user <name>          one person: the user is disabled in Keycloak realm parasol and signed out. No login,
#                        no token exchange, so no tool call on their behalf; everyone else keeps working.
#                        "user --all on" re-enables every disabled user of the realm (reset.sh).
#   agent <agent>        one agent (claims-agent|fraud-agent): its Keycloak client is disabled
#                        (scripts/agent-switch.sh); every user keeps working with the other agents.
#   tier <subscription>  one MaaS subscription (e.g. parasol-contractor): its owner groups are moved into the
#                        annotation parasol.example/kill-switch-owner and replaced by a group nobody is in, so
#                        every key minted for it is refused (403) within about 60 s (the gateway's
#                        subscription cache). Keys are bound to one subscription: no fallback to another, and
#                        no other subscription changes. "on" puts the saved groups back.
#   parasol              every Parasol MaaS subscription (models-as-a-service/parasol-*), same mechanism.
#   break-glass          the MCP gateway (gateway-system) and the cluster's MaaS gateway (openshift-ingress)
#                        scaled to 0: no tool call and no model call for ANY consumer on the cluster.
# Guarantees kept from the gateway switch: workloads keep running (pods Running and Ready) and the secured
# assistant answers that it is offline; no manager owns spec.replicas (the Gateway controller leaves it to
# the HPA, and an HPA does not scale a Deployment at 0), so "off" stays off until "on"; "on" brings a
# gateway back only if it is at 0, to the HPA floor, then the HPA takes over. Argo CD does not undo a tier
# switch: platform-rhoai ignores /spec/owner of MaaSSubscriptions (the tier keys' subscriptions are not
# Argo's). Every switch is idempotent.
# Keycloak: signs in as the parasol realm administrator (realm parasol only; never the master admin),
# override with PARASOL_REALM_ADMIN / PARASOL_REALM_ADMIN_PASS. The Showroom Terminal may switch agents
# and scale the MCP gateway; the MaaS gateway and subscriptions are admin-workstation actions.
# Usage: scripts/kill-switch.sh user <name>|agent <agent>|tier <subscription>|parasol|break-glass off|on|status
#        scripts/kill-switch.sh status   (every level)
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
MNS=models-as-a-service ANN=parasol.example/kill-switch-owner SENTINEL=parasol-kill-switch-off
GWS="gateway-system/mcp-gateway-openshift-default openshift-ingress/maas-default-gateway-openshift-default"
usage() {
  echo "usage: $0 user <name>|agent <agent>|tier <subscription>|parasol|break-glass off|on|status"
  echo "       $0 status   (every level)"; exit 2
}

# --- Keycloak (user level) ---
kc_login() {
  [ -n "${API:-}" ] && return 0
  local kc="${KC_URL:-https://sso.apps.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')}"
  API="$kc/admin/realms/parasol"
  TOKEN="$(curl -sk "$kc/realms/parasol/protocol/openid-connect/token" -d grant_type=password -d client_id=admin-cli \
    --data-urlencode "username=${PARASOL_REALM_ADMIN:-admin}" --data-urlencode "password=${PARASOL_REALM_ADMIN_PASS:-admin}" \
    | jq -r '.access_token // empty')"
  [ -n "$TOKEN" ] || { echo "realm parasol admin login failed"; API=; return 1; }
}
kc() { curl -sk -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' "$@"; }
user_set() {  # <id> <true|false>
  kc "$API/users/$1" | jq -c --argjson e "$2" '.enabled=$e' | kc -X PUT "$API/users/$1" -d @- -o /dev/null -w '%{http_code}'
}
users_disabled() { kc "$API/users?enabled=false&briefRepresentation=true&max=500" | jq -r '.[] | select(.enabled==false) | .username'; }
user_level() {  # <name> <action>
  kc_login || exit 1
  if [ "$1" = --all ]; then
    [ "$2" = on ] || usage
    for u in $(users_disabled); do "$0" user "$u" on; done
    echo "users disabled: $(users_disabled | tr '\n' ' ')"; return
  fi
  local id; id="$(kc -G "$API/users" --data-urlencode "username=$1" -d exact=true | jq -r '.[0].id // empty')"
  [ -n "$id" ] || { echo "user $1 not found in realm parasol"; exit 1; }
  case "$2" in
    off) echo "user $1 enabled=false http=$(user_set "$id" false)"
         kc -X POST "$API/users/$id/logout" -o /dev/null -w "user $1 signed out http=%{http_code}\n" ;;
    on)  echo "user $1 enabled=true http=$(user_set "$id" true)" ;;
    status) ;;
    *) usage ;;
  esac
  echo "user $1 enabled=$(kc "$API/users/$id" | jq -r .enabled)"
}

# --- MaaS subscriptions (tier, parasol levels) ---
sub_status() {
  local saved; saved="$(oc get maassubscription "$1" -n $MNS -o jsonpath="{.metadata.annotations.${ANN//./\\.}}" 2>/dev/null)"
  if [ -n "$saved" ]; then printf '%-28s OFF (saved owner %s)\n' "$1" "$saved"
  else printf '%-28s on  owner %s\n' "$1" "$(oc get maassubscription "$1" -n $MNS -o jsonpath='{.spec.owner}')"; fi
}
sub_switch() {  # <subscription> <off|on>
  oc get maassubscription "$1" -n $MNS >/dev/null || return 1
  local saved; saved="$(oc get maassubscription "$1" -n $MNS -o jsonpath="{.metadata.annotations.${ANN//./\\.}}")"
  if [ "$2" = off ] && [ -z "$saved" ]; then
    oc annotate maassubscription "$1" -n $MNS "$ANN=$(oc get maassubscription "$1" -n $MNS -o jsonpath='{.spec.owner}')" >/dev/null &&
      oc patch maassubscription "$1" -n $MNS --type merge \
        -p "{\"spec\":{\"owner\":{\"groups\":[{\"name\":\"$SENTINEL\"}],\"users\":null}}}" >/dev/null
  elif [ "$2" = on ] && [ -n "$saved" ]; then
    oc patch maassubscription "$1" -n $MNS --type merge -p "{\"spec\":{\"owner\":$saved}}" >/dev/null &&
      oc annotate maassubscription "$1" -n $MNS "$ANN-" >/dev/null
  fi
}
parasol_subs() { oc get maassubscription -n $MNS -o name | sed 's|.*/||' | grep '^parasol-'; }
subs_level() {  # <action> <subscription...>
  local a="$1"; shift
  case "$a" in off|on) for s in "$@"; do sub_switch "$s" "$a" || echo "$s: switch $a failed"; done ;; status) ;; *) usage ;; esac
  for s in "$@"; do sub_status "$s"; done
  [ "$a" = status ] || echo "takes effect within about 60 s (the MaaS gateway caches each subscription check for 60 s)"
}

# --- break glass ---
gw_status() {
  for g in $GWS; do
    printf '%-58s replicas=%s ready=%s\n' "$g" \
      "$(oc get deploy "${g#*/}" -n "${g%%/*}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '?')" \
      "$(oc get deploy "${g#*/}" -n "${g%%/*}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  done
}
break_glass() {
  case "$1" in
    off)
      for g in $GWS; do oc scale deploy "${g#*/}" -n "${g%%/*}" --replicas=0 || echo "$g: scale refused"; done
      echo "Break glass: MCP and MaaS gateways at 0, no agent on the cluster can call a tool or a model." ;;
    on)
      for g in $GWS; do
        ns=${g%%/*} d=${g#*/}
        [ "$(oc get deploy "$d" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null)" = 0 ] || continue
        min="$(oc get hpa "$d" -n "$ns" -o jsonpath='{.spec.minReplicas}' 2>/dev/null || true)"
        oc scale deploy "$d" -n "$ns" --replicas="${min:-2}" && oc rollout status deploy "$d" -n "$ns" --timeout=180s
      done ;;
    status) ;;
    *) usage ;;
  esac
  gw_status
}

case "${1:-status}" in
  user)    [ -n "${2:-}" ] || usage; user_level "$2" "${3:-status}" ;;
  agent)   [ -n "${2:-}" ] || usage; exec "$D/agent-switch.sh" "$2" "${3:-status}" ;;
  tier)    [ -n "${2:-}" ] || usage; subs_level "${3:-status}" "$2" ;;
  parasol) subs_level "${2:-status}" $(parasol_subs) ;;
  break-glass) break_glass "${2:-status}" ;;
  status)
    echo "== users (realm parasol, disabled)"
    if kc_login >/dev/null; then u="$(users_disabled)"; echo "  ${u:-none}" | tr '\n' ' '; echo
    else echo "  unknown: realm parasol admin login failed"; fi
    echo "== agents"
    for a in claims-agent fraud-agent; do "$D/agent-switch.sh" $a status 2>&1 | head -1 | sed 's/^/  /'; done
    echo "== MaaS subscriptions (tier / parasol)"
    for s in $(parasol_subs); do sub_status "$s" | sed 's/^/  /'; done
    echo "== break glass"
    gw_status | sed 's/^/  /' ;;
  *) usage ;;
esac
