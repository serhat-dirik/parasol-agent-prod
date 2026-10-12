#!/usr/bin/env bash
# Build the images in-cluster from the local source (binary builds). Re-run after any code change.
# parasol-free runs these :latest tags. The secured portal runs the pipeline-built, signed digest
# (scripts/pipeline-runs.sh); the first portal build is also kept as parasol-portal:unsigned, the image
# scripts/signing-demo.sh shows admission refusing.
set -euo pipefail
cd "$(dirname "$0")/.."
for i in $(seq 1 45); do oc get bc -n parasol-build parasol-agent >/dev/null 2>&1 && break; echo "$(date +%T) waiting for BuildConfigs from Argo ($i/45)"; sleep 20; done
timeout 900 oc start-build claims-db   -n parasol-build --from-dir=apps/mcp-servers/claims-db   --follow --wait &
timeout 900 oc start-build policy-docs -n parasol-build --from-dir=apps/mcp-servers/policy-docs --follow --wait &
timeout 900 oc start-build parasol-agent -n parasol-build --from-dir=apps/parasol-agent         --follow --wait &
timeout 1200 oc start-build parasol-portal -n parasol-build --from-dir=apps/parasol-portal/app --follow --wait &
timeout 900 oc start-build fraud-check -n parasol-build --from-dir=apps/mcp-servers/fraud-check --follow --wait &
fail=0; for j in $(jobs -p); do wait "$j" || fail=1; done
oc get istag parasol-portal:unsigned -n parasol-build >/dev/null 2>&1 || \
  oc tag parasol-build/parasol-portal:latest parasol-build/parasol-portal:unsigned || fail=1
oc rollout restart deploy -n parasol-free 2>/dev/null || true
# parasol-secured: admission resolved each :latest to a digest on the Deployment (Argo ignores that
# field), so a restart would keep the OLD image; point each workload at the digest just built.
for d in claims-db policy-docs parasol-agent fraud-check; do
  ref=$(oc get istag "${d}:latest" -n parasol-build -o jsonpath='{.image.dockerImageReference}' 2>/dev/null) || continue
  oc set image "deploy/$d" -n parasol-secured "$d=$ref" >/dev/null 2>&1 || true
done
[ $fail = 0 ] || { echo "a build failed: oc get builds -n parasol-build; re-run scripts/build-images.sh"; exit 1; }
