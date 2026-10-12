#!/usr/bin/env bash
# Build the images in-cluster from the local source (binary builds). Re-run after any code change.
# parasol-free runs these :latest tags. The secured portal runs the pipeline-built, signed digest
# (scripts/pipeline-runs.sh); the first portal build is also kept as parasol-portal:unsigned, the image
# scripts/signing-demo.sh shows admission refusing.
# Usage: scripts/build-images.sh [image ...]   (default: all; e.g. scripts/build-images.sh claims-db)
set -euo pipefail
cd "$(dirname "$0")/.."
for i in $(seq 1 45); do oc get bc -n parasol-build parasol-agent >/dev/null 2>&1 && break; echo "$(date +%T) waiting for BuildConfigs from Argo ($i/45)"; sleep 20; done
want=" ${*:-claims-db policy-docs parasol-agent parasol-portal fraud-check knowledge-base} "
build() {  # build <name> <source dir> <timeout s>
  case "$want" in *" $1 "*) timeout "$3" oc start-build "$1" -n parasol-build --from-dir="$2" --follow --wait;; esac
}
build claims-db apps/mcp-servers/claims-db 900 &
build policy-docs apps/mcp-servers/policy-docs 900 &
build parasol-agent apps/parasol-agent 900 &
build parasol-portal apps/parasol-portal/app 1200 &
build fraud-check apps/mcp-servers/fraud-check 900 &
build knowledge-base apps/mcp-servers/knowledge-base 1500 &
fail=0; for j in $(jobs -p); do wait "$j" || fail=1; done
oc get istag parasol-portal:unsigned -n parasol-build >/dev/null 2>&1 || \
  oc tag parasol-build/parasol-portal:latest parasol-build/parasol-portal:unsigned || fail=1
for d in $want; do oc rollout restart "deploy/${d/parasol-portal/portal}" -n parasol-free 2>/dev/null || true; done
# parasol-secured: admission resolved each :latest to a digest on the Deployment (Argo ignores that
# field), so a restart would keep the OLD image; point each workload at the digest just built.
for d in claims-db policy-docs parasol-agent fraud-check knowledge-base; do
  case "$want" in *" $d "*) ;; *) continue;; esac
  ref=$(oc get istag "${d}:latest" -n parasol-build -o jsonpath='{.image.dockerImageReference}' 2>/dev/null) || continue
  oc set image "deploy/$d" -n parasol-secured "$d=$ref" >/dev/null 2>&1 || true
done
[ $fail = 0 ] || { echo "a build failed: oc get builds -n parasol-build; re-run scripts/build-images.sh"; exit 1; }
