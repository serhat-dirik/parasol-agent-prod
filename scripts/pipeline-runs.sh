#!/usr/bin/env bash
# The two release runs the guide shows (06/07), with fixed names:
#   parasol-portal-secure-build-v1  candidate v1: gate passes, the signed digest is promoted (a commit to
#                                   gitops/envs/secured/kustomization.yaml; Argo rolls the secured portal)
#   parasol-portal-secure-build-v2  candidate v2: gate fails at 17/20, promote is skipped
# v1 needs the GitHub token Secret parasol-build/gitops-auth-secret (the one manual install step):
#   read -s T && oc create secret generic gitops-auth-secret -n parasol-build --from-literal=token="$T" && unset T
# Without it v1 is not started (the secured portal stays on the previous pin). Idempotent: an existing run
# is kept, except a v1 that finished without a promotion commit, which is re-run once the token exists.
# Usage: scripts/pipeline-runs.sh [--wait]     (~20-30 min per run; both run in parallel)
set -euo pipefail
cd "$(dirname "$0")/.."
NS=parasol-build
run() {  # run <candidate>
  local name="parasol-portal-secure-build-$1" st
  st=$(oc get pipelinerun "$name" -n $NS -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || true)
  if [ -n "$st" ]; then
    if [ "$1" = v1 ] && [ "$st" != Running ] && [ "$st" != Started ] && \
       [ -z "$(oc get pipelinerun "$name" -n $NS -o jsonpath='{.status.results[?(@.name=="PROMOTION_COMMIT")].value}')" ]; then
      echo "$name finished ($st) without a promotion commit: re-running"
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
if oc get secret gitops-auth-secret -n $NS >/dev/null 2>&1; then
  run v1
else
  echo "NOT started: parasol-portal-secure-build-v1 needs the GitHub token Secret parasol-build/gitops-auth-secret:"
  echo "  read -s T && oc create secret generic gitops-auth-secret -n parasol-build --from-literal=token=\"\$T\" && unset T"
  echo "  then: scripts/pipeline-runs.sh"
fi
[ "${1:-}" = --wait ] || { echo "watch: oc get pipelinerun -n $NS -w   (console: Pipelines > parasol-build)"; exit 0; }
for i in $(seq 1 90); do   # deadline 45 min
  line=$(oc get pipelinerun -n $NS -l tekton.dev/pipeline=parasol-portal-secure-build \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[0].reason} {end}' 2>/dev/null)
  echo "$(date +%T) $line"
  case "$line" in *Running*|*Started*|*=\ *) sleep 30;; *) break;; esac
done
