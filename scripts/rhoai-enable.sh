#!/usr/bin/env bash
# OpenShift AI platform objects, detect-or-create (idempotent):
#   DSCInitialization  the operator creates default-dsci itself; created here only if it never appears
#   DataScienceCluster created as default-dsc from gitops/platform/rhoai/dsc-patch.yaml if absent, else patched
#   OdhDashboardConfig patched (gitops/platform/rhoai/dashboard-patch.yaml); rhods-dashboard restarted when
#                      the patch changed something (disableLMEval etc. are read at dashboard start)
# Components take 15-40 min after this; bootstrap does not block on them. Watch with:
#   oc get datasciencecluster default-dsc -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}'
set -euo pipefail
cd "$(dirname "$0")/.."
json() { python3 -c 'import yaml,json,sys; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' "$1"; }
storage_version() { oc get crd "$1" -o jsonpath='{.spec.versions[?(@.storage==true)].name}' 2>/dev/null; }

for i in $(seq 1 40); do   # CRDs arrive with the operator CSV
  [ -n "$(storage_version datascienceclusters.datasciencecluster.opendatahub.io)" ] && \
  [ -n "$(storage_version dscinitializations.dscinitialization.opendatahub.io)" ] && break
  echo "$(date +%T) waiting for the OpenShift AI CRDs ($i/40)"; sleep 15
done

for i in $(seq 1 20); do [ -n "$(oc get dscinitialization -o name 2>/dev/null)" ] && break
  echo "$(date +%T) waiting for the operator's DSCInitialization ($i/20)"; sleep 15; done
if [ -n "$(oc get dscinitialization -o name 2>/dev/null)" ]; then
  echo "DSCInitialization: already present ($(oc get dscinitialization -o name | head -1))"
else
  echo "DSCInitialization: creating default-dsci"
  oc apply -f - <<YAML
apiVersion: dscinitialization.opendatahub.io/$(storage_version dscinitializations.dscinitialization.opendatahub.io)
kind: DSCInitialization
metadata: {name: default-dsci}
spec:
  applicationsNamespace: redhat-ods-applications
  monitoring: {managementState: Managed, namespace: redhat-ods-monitoring, metrics: {}}
YAML
fi

dsc=$(oc get datasciencecluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$dsc" ]; then
  echo "DataScienceCluster: already present ($dsc), patching components"
  oc patch datasciencecluster "$dsc" --type merge -p "$(json gitops/platform/rhoai/dsc-patch.yaml)"
else
  echo "DataScienceCluster: creating default-dsc"
  python3 -c 'import yaml,json,sys
d=yaml.safe_load(open("gitops/platform/rhoai/dsc-patch.yaml"))
d.update({"apiVersion":"datasciencecluster.opendatahub.io/"+sys.argv[1],"kind":"DataScienceCluster","metadata":{"name":"default-dsc"}})
print(json.dumps(d))' "$(storage_version datascienceclusters.datasciencecluster.opendatahub.io)" | oc apply -f -
  dsc=default-dsc
fi

for i in $(seq 1 40); do oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications >/dev/null 2>&1 && break
  echo "$(date +%T) waiting for the dashboard config ($i/40)"; sleep 15; done
out=$(oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type merge -p "$(json gitops/platform/rhoai/dashboard-patch.yaml)")
echo "$out"
case "$out" in *"(no change)"*) ;; *) oc rollout restart deploy/rhods-dashboard -n redhat-ods-applications 2>/dev/null \
  && echo "rhods-dashboard restarted to load the dashboard config" || true;; esac
echo "DSC $dsc; ModelsAsAServiceReady=$(oc get datasciencecluster "$dsc" -o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}')"
