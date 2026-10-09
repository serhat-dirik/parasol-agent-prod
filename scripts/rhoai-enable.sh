#!/usr/bin/env bash
# Patch the existing DataScienceCluster and dashboard config with the components the demo needs.
set -euo pipefail
cd "$(dirname "$0")/.."
until oc get datasciencecluster -A -o name 2>/dev/null | grep -q .; do echo "waiting for DataScienceCluster..."; sleep 15; done
dsc=$(oc get datasciencecluster -A -o jsonpath='{.items[0].metadata.name}')
echo "patching DataScienceCluster/$dsc"
oc patch datasciencecluster "$dsc" --type merge -p "$(python3 -c 'import yaml,json,sys; print(json.dumps(yaml.safe_load(open("gitops/platform/rhoai/dsc-patch.yaml"))))')"
until oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications >/dev/null 2>&1; do echo "waiting for dashboard config..."; sleep 15; done
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type merge -p "$(python3 -c 'import yaml,json; print(json.dumps(yaml.safe_load(open("gitops/platform/rhoai/dashboard-patch.yaml"))))')"
echo "waiting for ModelsAsAServiceReady..."
for i in $(seq 1 60); do
  oc get datasciencecluster "$dsc" -o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}' 2>/dev/null | grep -q True && { echo "MaaS ready"; break; }
  sleep 15
done
