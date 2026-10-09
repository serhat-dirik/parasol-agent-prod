#!/usr/bin/env bash
# Patch the existing DataScienceCluster and dashboard config with the components the demo needs.
set -euo pipefail
cd "$(dirname "$0")/.."
for i in $(seq 1 40); do [ -n "$(oc get datasciencecluster -A -o name 2>/dev/null)" ] && break; echo "$(date +%T) waiting for DataScienceCluster ($i/40)"; sleep 15; done
dsc=$(oc get datasciencecluster -A -o jsonpath='{.items[0].metadata.name}')
echo "patching DataScienceCluster/$dsc"
oc patch datasciencecluster "$dsc" --type merge -p "$(python3 -c 'import yaml,json,sys; print(json.dumps(yaml.safe_load(open("gitops/platform/rhoai/dsc-patch.yaml"))))')"
for i in $(seq 1 40); do oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications >/dev/null 2>&1 && break; echo "$(date +%T) waiting for dashboard config ($i/40)"; sleep 15; done
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type merge -p "$(python3 -c 'import yaml,json; print(json.dumps(yaml.safe_load(open("gitops/platform/rhoai/dashboard-patch.yaml"))))')"
# Components take 15-40 min after the patch; do not block bootstrap on them. Watch with:
#   oc get datasciencecluster -o jsonpath='{range .items[0].status.conditions[*]}{.type}={.status} {end}'
echo "DSC patched; ModelsAsAServiceReady=$(oc get datasciencecluster "$dsc" -o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}')"
