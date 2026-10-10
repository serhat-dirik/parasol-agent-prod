#!/usr/bin/env bash
# Build the three images in-cluster from the local source (binary builds). Re-run after any code change.
set -euo pipefail
cd "$(dirname "$0")/.."
for i in $(seq 1 45); do oc get bc -n parasol-build parasol-agent >/dev/null 2>&1 && break; echo "$(date +%T) waiting for BuildConfigs from Argo ($i/45)"; sleep 20; done
timeout 900 oc start-build claims-db   -n parasol-build --from-dir=apps/mcp-servers/claims-db   --follow --wait &
timeout 900 oc start-build policy-docs -n parasol-build --from-dir=apps/mcp-servers/policy-docs --follow --wait &
timeout 900 oc start-build parasol-agent -n parasol-build --from-dir=apps/parasol-agent         --follow --wait &
timeout 1200 oc start-build parasol-portal -n parasol-build --from-dir=apps/parasol-portal/app --follow --wait &
wait
for ns in parasol-free parasol-secured; do oc rollout restart deploy -n $ns 2>/dev/null || true; done
