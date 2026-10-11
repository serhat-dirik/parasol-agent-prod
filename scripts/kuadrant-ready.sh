#!/usr/bin/env bash
# Kuadrant (RHCL) detects its dependencies (the Gateway API provider and the Limitador operator) once,
# at operator start. On a fresh cluster it usually starts before OpenShift's gateway controller and
# Limitador exist, then reports MissingDependency forever and no AuthPolicy is enforced (MaaS key
# minting gets a 500, the MCP gateway checks no identity). The fix is a fresh operator pod. OLM owns
# the Deployment and reverts `rollout restart`, so the pod is deleted instead.
set -uo pipefail
ns=kuadrant-system
ready() { [ "$(oc get kuadrant -n $ns -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ]; }
ready && { echo "Kuadrant Ready"; exit 0; }
# wait for what Kuadrant needs before restarting it, so one restart is enough
for i in $(seq 1 40); do
  [ -n "$(oc get gatewayclass -o name 2>/dev/null)" ] && oc get crd envoyfilters.networking.istio.io limitadors.limitador.kuadrant.io >/dev/null 2>&1 && break
  echo "$(date +%T) waiting for a GatewayClass, Istio and Limitador CRDs ($i/40)"; sleep 15
done
echo "Kuadrant not Ready: $(oc get kuadrant -n $ns -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].message}')"
echo "restarting the Kuadrant operator pod"
oc delete pod -n $ns -l app=kuadrant,control-plane=controller-manager --wait=false 2>/dev/null \
  || oc delete pod -n $ns $(oc get pods -n $ns -o name | grep kuadrant-operator-controller-manager) --wait=false
for i in $(seq 1 24); do ready && { echo "Kuadrant Ready"; exit 0; }; echo "$(date +%T) waiting for Kuadrant Ready ($i/24)"; sleep 10; done
echo "Kuadrant still not Ready"; exit 1
