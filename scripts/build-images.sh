#!/usr/bin/env bash
# Build the three images in-cluster from the local source (binary builds). Re-run after any code change.
set -euo pipefail
cd "$(dirname "$0")/.."
until oc get bc -n parasol-build parasol-agent >/dev/null 2>&1; do echo "waiting for BuildConfigs (Argo)..."; sleep 10; done
oc start-build claims-db   -n parasol-build --from-dir=apps/mcp-servers/claims-db   --follow --wait &
oc start-build policy-docs -n parasol-build --from-dir=apps/mcp-servers/policy-docs --follow --wait &
oc start-build parasol-agent -n parasol-build --from-dir=apps/parasol-agent         --follow --wait &
wait
for ns in parasol-free parasol-secured; do oc rollout restart deploy -n $ns 2>/dev/null || true; done
