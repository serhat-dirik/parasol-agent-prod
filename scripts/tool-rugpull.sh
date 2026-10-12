#!/usr/bin/env bash
# Scenario 6, "the poisoned tool": set-up and reset for the vendor MCP server currency-converter
# (parasol-thirdparty). The demo itself is in the browser (portals, console, Argo CD); this only flips state.
#   plug        someone plugs the vendor tool into the FREE assistant (Argo CD component plug-in-vendor-tool
#               on env-free; the free portal restarts). Off by default, so Scenarios 1-5 never see it.
#   unplug      take it out of the free assistant again
#   on          the vendor's server starts serving the poisoned description (same name, same version 1.4.2)
#   off         back to the clean description
#   register    switch on the governed registration on the secured MCP gateway (Argo CD component
#               register-currency-converter on env-secured; the reviewed change, no Git write)
#   unregister  switch it off again
#   status      what is plugged, registered and served, and the scanner's latest findings
#   reset       claims data back to seed, then off + unplug + unregister (scripts/reset.sh --keep-allowance)
set -euo pipefail
NS=parasol-thirdparty
cd "$(dirname "$0")/.."

restart() {
  oc delete pod -n "$NS" -l app=currency-converter --wait=false >/dev/null
  sleep 2
  oc rollout status deploy/currency-converter -n "$NS" --timeout=120s >/dev/null
  echo " currency-converter: description=$(oc get configmap currency-converter-release -n "$NS" -o jsonpath='{.data.description}' 2>/dev/null || true)"
}

# $1 = Application, $2 = component, $3 = add|remove. Keeps the other components (e.g. kill-switch).
# Prints "changed" when the list changed.
components() {
  local cur new
  cur=$(oc get application "$1" -n openshift-gitops -o jsonpath='{.spec.source.kustomize.components}')
  new=$(python3 -c '
import json, sys
cur = json.loads(sys.argv[1] or "[]"); c = sys.argv[2]
new = [x for x in cur if x != c] + ([c] if sys.argv[3] == "add" else [])
print("" if new == cur else json.dumps({"spec": {"source": {"kustomize": {"components": new or None}}}}))' "$cur" "$2" "$3")
  [ -z "$new" ] && return 0
  oc patch application "$1" -n openshift-gitops --type merge -p "$new" >/dev/null
  oc annotate application "$1" -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  echo changed
}

free_portal_has_tool() {
  oc get deploy portal -n parasol-free -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' | grep -qw FRAUD_CHECK_MCP_URL
}

case "${1:-status}" in
  plug|unplug)
    changed=$(components env-free plug-in-vendor-tool "$([ "$1" = plug ] && echo add || echo remove)")
    for _ in $(seq 1 36); do
      if [ "$1" = plug ]; then free_portal_has_tool && break; else free_portal_has_tool || break; fi
      sleep 5
    done
    [ -n "$changed" ] && oc rollout status deploy/portal -n parasol-free --timeout=300s >/dev/null
    echo " free assistant: vendor tool $([ "$1" = plug ] && echo plugged in || echo unplugged)" ;;
  on)
    oc create configmap currency-converter-release -n "$NS" --from-literal=description=poisoned \
      --dry-run=client -o yaml | oc apply -f - >/dev/null
    restart ;;
  off)
    oc delete configmap currency-converter-release -n "$NS" --ignore-not-found >/dev/null
    restart ;;
  register)
    components env-secured register-currency-converter add >/dev/null
    for _ in $(seq 1 30); do
      oc get mcpserverregistration currency-converter -n parasol-secured >/dev/null 2>&1 && break; sleep 5
    done
    oc get mcpserverregistration -n parasol-secured ;;
  unregister)
    components env-secured register-currency-converter remove >/dev/null
    for _ in $(seq 1 30); do
      oc get mcpserverregistration currency-converter -n parasol-secured >/dev/null 2>&1 || break; sleep 5
    done
    echo " secured gateway: currency-converter not registered" ;;
  status)
    echo " description: $(oc get configmap currency-converter-release -n "$NS" -o jsonpath='{.data.description}' 2>/dev/null || echo clean)"
    echo " free assistant: $(free_portal_has_tool && echo plugged in || echo unplugged)"
    echo " env-secured components: $(oc get application env-secured -n openshift-gitops -o jsonpath='{.spec.source.kustomize.components}')"
    oc get mcpserverregistration -n parasol-secured
    oc logs -n mcp-system deploy/mcp-tool-scanner --tail=200 | grep -E 'currency-converter' | tail -8 ;;
  reset)
    scripts/reset.sh --keep-allowance ;;
  *) echo "usage: $0 plug|unplug|on|off|register|unregister|status|reset" >&2; exit 2 ;;
esac
