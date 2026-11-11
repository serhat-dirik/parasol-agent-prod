#!/usr/bin/env bash
# The two release runs the guide shows (06/07), with fixed names:
#   parasol-portal-release-production           the production prompt (gitops/envs/secured/system-prompt.txt,
#                                               registered as alias production): gate passes; promote pins
#                                               that prompt (ConfigMap agent-prompt-release) and the signed
#                                               digest on the Argo CD Application env-secured (no Git write)
#   parasol-portal-release-candidate-shortened  the shortened candidate prompt (prompt alias candidate):
#                                               gate fails (below 0.95), promote is skipped
# Idempotent: an existing run is kept, except a production run that did not promote what env-secured pins
# (not Succeeded, no PROMOTED_DIGEST, or a digest other than the pin): that one is re-run.
# Usage: [RERUN=1] scripts/pipeline-runs.sh [--wait]     (~20-30 min per run; both run in parallel)
#   RERUN=1 re-runs both (after a change to the eval, the golden set or the pipeline)
#   --wait  waits for both runs and exits non-zero unless the production run promoted.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=parasol-build
run() {  # run <candidate> <prompt alias> <prompt file in the repo>
  local name="parasol-portal-release-$1" st stale="" d pin
  st=$(oc get pipelinerun "$name" -n $NS -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || true)
  if [ -n "$st" ]; then
    case "$st" in Running|Started) echo "$name is running"; return 0;; esac
    if [ "${RERUN:-0}" = 1 ]; then stale="RERUN=1"
    elif [ "$1" = production ]; then
      # promoted means: Succeeded, a PROMOTED_DIGEST, and that digest is what env-secured actually pins
      # (a run that adopted an old run's TaskRuns can time out at once and still carry a stale digest)
      d=$(oc get pipelinerun "$name" -n $NS -o jsonpath='{.status.results[?(@.name=="PROMOTED_DIGEST")].value}')
      pin=$(oc get application env-secured -n openshift-gitops -o jsonpath='{.spec.source.kustomize.images}' 2>/dev/null || true)
      if [ "$st" != Succeeded ] || [ -z "$d" ]; then stale="finished ($st) without promoting"
      elif [[ "$pin" != *"@$d"* ]]; then stale="promoted $d but env-secured pins ${pin:-nothing}"; fi
    fi
    [ -n "$stale" ] || { echo "$name already exists ($st)"; return 0; }
    echo "$name: $stale: re-running"
    oc delete pipelinerun "$name" -n $NS --wait=true >/dev/null
    # the re-run gets the SAME TaskRun and workspace PVC names: wait until the old ones are gone, or the
    # new run adopts stale TaskRuns ("completed without ancestors") / loses its PVC to the GC
    for i in $(seq 1 24); do
      [ -z "$(oc get taskrun -n $NS -l tekton.dev/pipelineRun="$name" -o name)" ] || { sleep 5; continue; }
      oc get pvc -n $NS -o json | python3 -c 'import json,sys; n=sys.argv[1]
sys.exit(any(o.get("name")==n for p in json.load(sys.stdin)["items"] for o in p["metadata"].get("ownerReferences",[])))' "$name" && break
      sleep 5
    done
    [ -z "$(oc get taskrun -n $NS -l tekton.dev/pipelineRun="$name" -o name)" ] || {
      echo "$name: old TaskRuns still present after 2 min; not starting (re-run this script)"; return 1; }
    sleep 20   # the controller may still hold the deleted run; a same-name run created at once inherits its status
    scripts/results-prune.sh $NS "$name" || true   # archived same-name runs would show in the console's graph
  fi
  python3 -c 'import yaml,sys
d=yaml.safe_load(open("gitops/platform/pipeline/pipelinerun.yaml"))
d["metadata"].pop("generateName"); d["metadata"]["name"]=sys.argv[1]
d["spec"]["params"]=[{"name":"candidate","value":sys.argv[2]},{"name":"prompt-ref","value":"parasol-claims-assistant-system-prompt@"+sys.argv[3]},
  {"name":"prompt-file","value":"source/"+sys.argv[4]}]
print(yaml.safe_dump(d))' "$name" "$1" "$2" "$3" | oc create -f - >/dev/null
  echo "$name started (candidate $1)"
}
oc get pipeline parasol-portal-secure-build -n $NS >/dev/null || { echo "Pipeline not synced yet (Argo platform-pipeline)"; exit 1; }
run candidate-shortened candidate gitops/platform/pipeline/prompts/v2.txt
run production production gitops/envs/secured/system-prompt.txt
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
