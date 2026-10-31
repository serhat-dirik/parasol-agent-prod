#!/usr/bin/env bash
# Platform kill switch ("off" = gateways off): take every secured agent off the air by scaling the two gateways it needs to zero.
#   mcp-gateway-openshift-default    (gateway-system)         every tool call (claims agent, fraud agent, REST agent)
#   model-gateway-openshift-default  (parasol-model-gateway)  every model call of the secured portal and agents
# The workloads keep running (pods Running and Ready); the secured assistant answers "offline". Nothing in
# Git changes and no manager owns spec.replicas: the Gateway controller leaves it to the HPA (min 2), and an
# HPA does not scale a Deployment that is at 0, so "off" stays off until "on".
# --all also scales openshift-ingress/maas-default-gateway-openshift-default: the cluster's Models-as-a-Service
# gateway, so EVERY MaaS consumer on the cluster (evaluations, other teams, the playground) loses the model.
# Admin workstation only (the Showroom Terminal may scale the two parasol gateways, not this one).
# Usage: scripts/kill-switch.sh off|on|status [--all]   (on always restores every gateway it finds at 0)
set -euo pipefail
GWS="gateway-system/mcp-gateway-openshift-default parasol-model-gateway/model-gateway-openshift-default"
[ "${2:-}" = --all ] && GWS="$GWS openshift-ingress/maas-default-gateway-openshift-default"

status() {
  for g in $GWS; do
    ns=${g%%/*} d=${g#*/}
    printf '%-58s replicas=%s ready=%s\n' "$g" \
      "$(oc get deploy "$d" -n "$ns" -o jsonpath='{.spec.replicas}')" \
      "$(oc get deploy "$d" -n "$ns" -o jsonpath='{.status.readyReplicas}')"
  done
}

case "${1:-status}" in
  off)
    for g in $GWS; do oc scale deploy "${g#*/}" -n "${g%%/*}" --replicas=0; done
    echo "Gateways scaled to 0: the secured assistant is offline. Restore with: scripts/kill-switch.sh on${2:+ $2}" ;;
  on)
    # always brings back all three (the MaaS gateway too, if an --all left it at 0 and we may read it)
    GWS="gateway-system/mcp-gateway-openshift-default parasol-model-gateway/model-gateway-openshift-default"
    oc get deploy maas-default-gateway-openshift-default -n openshift-ingress >/dev/null 2>&1 && \
      GWS="$GWS openshift-ingress/maas-default-gateway-openshift-default"
    for g in $GWS; do
      ns=${g%%/*} d=${g#*/}
      [ "$(oc get deploy "$d" -n "$ns" -o jsonpath='{.spec.replicas}')" = 0 ] || continue
      # back to the HPA floor; the HPA takes over again from there
      min="$(oc get hpa "$d" -n "$ns" -o jsonpath='{.spec.minReplicas}' 2>/dev/null || true)"
      oc scale deploy "$d" -n "$ns" --replicas="${min:-2}"
    done
    for g in $GWS; do oc rollout status deploy "${g#*/}" -n "${g%%/*}" --timeout=180s; done
    echo "Gateways back: the secured assistant is online." ;;
  status) ;;
  *) echo "usage: $0 off|on|status [--all]"; exit 2 ;;
esac
status
