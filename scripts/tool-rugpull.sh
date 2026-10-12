#!/usr/bin/env bash
# Scenario 6, "the poisoned tool": set-up and reset for the vendor MCP server currency-converter
# (parasol-thirdparty). The demo itself is in the browser (portals, console, Argo CD); this only flips state.
#   on          the vendor's server starts serving the poisoned description (same name, same version 1.4.2)
#   off         back to the clean description
#   register    switch on the governed registration on the secured MCP gateway (Argo CD component
#               register-currency-converter on env-secured; the reviewed change, no Git write)
#   unregister  switch it off again
#   status      description in use, registration, the scanner's latest findings
#   reset       off + unregister + claims data back to seed (scripts/reset.sh --keep-allowance)
set -euo pipefail
NS=parasol-thirdparty
cd "$(dirname "$0")/.."

restart() {
  oc delete pod -n "$NS" -l app=currency-converter --wait=false >/dev/null
  sleep 2
  oc rollout status deploy/currency-converter -n "$NS" --timeout=120s >/dev/null
  echo " currency-converter: description=$(oc get configmap currency-converter-release -n "$NS" -o jsonpath='{.data.description}' 2>/dev/null || true)"
}

components() {  # $1 = add|remove: edit env-secured spec.source.kustomize.components, keep the others (kill-switch)
  local cur new
  cur=$(oc get application env-secured -n openshift-gitops -o jsonpath='{.spec.source.kustomize.components}')
  new=$(python3 -c '
import json, sys
cur = json.loads(sys.argv[1] or "[]"); c = "register-currency-converter"
cur = [x for x in cur if x != c] + ([c] if sys.argv[2] == "add" else [])
print(json.dumps({"spec": {"source": {"kustomize": {"components": cur or None}}}}))' "$cur" "$1")
  oc patch application env-secured -n openshift-gitops --type merge -p "$new" >/dev/null
  oc annotate application env-secured -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite >/dev/null
}

case "${1:-status}" in
  on)
    oc create configmap currency-converter-release -n "$NS" --from-literal=description=poisoned \
      --dry-run=client -o yaml | oc apply -f - >/dev/null
    restart ;;
  off)
    oc delete configmap currency-converter-release -n "$NS" --ignore-not-found >/dev/null
    restart ;;
  register)
    components add
    for _ in $(seq 1 30); do
      oc get mcpserverregistration currency-converter -n parasol-secured >/dev/null 2>&1 && break; sleep 5
    done
    oc get mcpserverregistration -n parasol-secured ;;
  unregister)
    components remove
    for _ in $(seq 1 30); do
      oc get mcpserverregistration currency-converter -n parasol-secured >/dev/null 2>&1 || break; sleep 5
    done
    echo " registration removed" ;;
  status)
    echo " description: $(oc get configmap currency-converter-release -n "$NS" -o jsonpath='{.data.description}' 2>/dev/null || echo clean)"
    echo " env-secured components: $(oc get application env-secured -n openshift-gitops -o jsonpath='{.spec.source.kustomize.components}')"
    oc get mcpserverregistration -n parasol-secured
    oc logs -n mcp-system deploy/mcp-tool-scanner --tail=200 | grep -E 'currency-converter' | tail -8 ;;
  reset)
    "$0" off
    "$0" unregister
    scripts/reset.sh --keep-allowance ;;
  *) echo "usage: $0 on|off|register|unregister|status|reset" >&2; exit 2 ;;
esac
