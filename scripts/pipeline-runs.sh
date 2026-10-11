#!/usr/bin/env bash
# The two release runs the guide shows (06/07), with fixed names:
#   parasol-portal-secure-build-v1  candidate v1: gate passes; promote pins the signed digest on the Argo CD
#                                   Application env-secured (no Git write) and Argo rolls the secured portal
#   parasol-portal-secure-build-v2  candidate v2: gate fails at 17/20, promote is skipped
# Idempotent: an existing run is kept, except a v1 that finished without promoting, which is re-run.
# Usage: scripts/pipeline-runs.sh [--wait]     (~20-30 min per run; both run in parallel)
#   --wait  waits for both runs and exits non-zero unless v1 promoted.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=parasol-build
run() {  # run <candidate>
  local name="parasol-portal-secure-build-$1" st
  st=$(oc get pipelinerun "$name" -n $NS -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || true)
  if [ -n "$st" ]; then
    if [ "$1" = v1 ] && [ "$st" != Running ] && [ "$st" != Started ] && \
       [ -z "$(oc get pipelinerun "$name" -n $NS -o jsonpath='{.status.results[?(@.name=="PROMOTED_DIGEST")].value}')" ]; then
      echo "$name finished ($st) without promoting: re-running"
      oc delete pipelinerun "$name" -n $NS --wait=true >/dev/null
    else
      echo "$name already exists ($st)"; return 0
    fi
  fi
  python3 -c 'import yaml,sys
d=yaml.safe_load(open("gitops/platform/pipeline/pipelinerun.yaml"))
d["metadata"].pop("generateName"); d["metadata"]["name"]=sys.argv[1]
d["spec"]["params"]=[{"name":"candidate","value":sys.argv[2]},{"name":"prompt-ref","value":"parasol-claims-assistant-system-prompt@"+sys.argv[2][1:]}]
print(yaml.safe_dump(d))' "$name" "$1" | oc create -f - >/dev/null
  echo "$name started (candidate $1)"
}
oc get pipeline parasol-portal-secure-build -n $NS >/dev/null || { echo "Pipeline not synced yet (Argo platform-pipeline)"; exit 1; }
run v2
run v1
[ "${1:-}" = --wait ] || { echo "watch: oc get pipelinerun -n $NS -w   (console: Pipelines > parasol-build)"; exit 0; }
for i in $(seq 1 90); do   # deadline 45 min
  line=$(oc get pipelinerun -n $NS -l tekton.dev/pipeline=parasol-portal-secure-build \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[0].reason} {end}' 2>/dev/null)
  echo "$(date +%T) $line"
  case "$line" in *Running*|*Started*|*=\ *) sleep 30;; *) break;; esac
done
d=$(oc get pipelinerun parasol-portal-secure-build-v1 -n $NS -o jsonpath='{.status.results[?(@.name=="PROMOTED_DIGEST")].value}' 2>/dev/null)
[ -n "$d" ] || { echo "v1 did not promote (console: Pipelines > parasol-build > parasol-portal-secure-build-v1)"; exit 1; }
echo "v1 promoted $d: $(oc get application env-secured -n openshift-gitops -o jsonpath='{.status.sync.status}/{.status.health.status}')"
