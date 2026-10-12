#!/usr/bin/env bash
# The two release runs the guide shows (06/07), with fixed names:
#   parasol-portal-release-production           the production prompt (prompt alias production): gate
#                                               passes; promote pins the signed digest on the Argo CD
#                                               Application env-secured (no Git write) and Argo rolls it out
#   parasol-portal-release-candidate-shortened  the shortened candidate prompt (prompt alias candidate):
#                                               gate fails at 17/20, promote is skipped
# Idempotent: an existing run is kept, except a production run that finished without promoting (re-run).
# Usage: scripts/pipeline-runs.sh [--wait]     (~20-30 min per run; both run in parallel)
#   --wait  waits for both runs and exits non-zero unless the production run promoted.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=parasol-build
run() {  # run <candidate> <prompt alias>
  local name="parasol-portal-release-$1" st
  st=$(oc get pipelinerun "$name" -n $NS -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || true)
  if [ -n "$st" ]; then
    if [ "$1" = production ] && [ "$st" != Running ] && [ "$st" != Started ] && \
       [ -z "$(oc get pipelinerun "$name" -n $NS -o jsonpath='{.status.results[?(@.name=="PROMOTED_DIGEST")].value}')" ]; then
      echo "$name finished ($st) without promoting: re-running"
      oc delete pipelinerun "$name" -n $NS --wait=true >/dev/null
      # the re-run gets the SAME TaskRun and workspace PVC names: wait until the old ones are gone, or the
      # new run adopts stale TaskRuns ("completed without ancestors") / loses its PVC to the GC
      for i in $(seq 1 24); do
        [ -z "$(oc get taskrun -n $NS -l tekton.dev/pipelineRun="$name" -o name)" ] || { sleep 5; continue; }
        oc get pvc -n $NS -o json | python3 -c 'import json,sys; n=sys.argv[1]
sys.exit(any(o.get("name")==n for p in json.load(sys.stdin)["items"] for o in p["metadata"].get("ownerReferences",[])))' "$name" && break
        sleep 5
      done
    else
      echo "$name already exists ($st)"; return 0
    fi
  fi
  python3 -c 'import yaml,sys
d=yaml.safe_load(open("gitops/platform/pipeline/pipelinerun.yaml"))
d["metadata"].pop("generateName"); d["metadata"]["name"]=sys.argv[1]
d["spec"]["params"]=[{"name":"candidate","value":sys.argv[2]},{"name":"prompt-ref","value":"parasol-claims-assistant-system-prompt@"+sys.argv[3]}]
print(yaml.safe_dump(d))' "$name" "$1" "$2" | oc create -f - >/dev/null
  echo "$name started (candidate $1)"
}
oc get pipeline parasol-portal-secure-build -n $NS >/dev/null || { echo "Pipeline not synced yet (Argo platform-pipeline)"; exit 1; }
run candidate-shortened candidate
run production production
[ "${1:-}" = --wait ] || { echo "watch: oc get pipelinerun -n $NS -w   (console: Pipelines > parasol-build)"; exit 0; }
for i in $(seq 1 90); do   # deadline 45 min
  line=$(oc get pipelinerun -n $NS -l tekton.dev/pipeline=parasol-portal-secure-build \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[0].reason} {end}' 2>/dev/null)
  echo "$(date +%T) $line"
  case "$line" in *Running*|*Started*|*=\ *) sleep 30;; *) break;; esac
done
d=$(oc get pipelinerun parasol-portal-release-production -n $NS -o jsonpath='{.status.results[?(@.name=="PROMOTED_DIGEST")].value}' 2>/dev/null)
[ -n "$d" ] || { echo "production did not promote (console: Pipelines > parasol-build > parasol-portal-release-production)"; exit 1; }
echo "production promoted $d: $(oc get application env-secured -n openshift-gitops -o jsonpath='{.status.sync.status}/{.status.health.status}')"
