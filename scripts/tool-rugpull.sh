#!/usr/bin/env bash
# Showcase 7, the partner bank's exchange-rate service (currency-converter): set-up, the bank's release, onboarding.
# The demo itself is in the browser (portals, console, Argo CD); this only moves state.
#   release <version>   the bank publishes <version> as latest (oc tag in parasol-build, standing in for the bank's
#                       registry); the unsecured side (parasol-thirdparty) runs latest and restarts on it
#   onboard <version> [--wait]   run the onboarding pipeline for <version> (PipelineRun
#                       parasol-tool-onboarding-currency-converter-<version>); passed = built by Parasol, signed by Tekton Chains and promoted to
#                       parasol-secured, refused = nothing changes
#   plug | unplug       the team plugs the bank's service (as published) into the FREE assistant (Argo CD component
#                       plug-in-vendor-tool on env-free). Off by default, so the other showcases never see it.
#   bypass-test         try to run the bank's latest image in parasol-secured without onboarding (server-side dry
#                       run: admission answers, nothing changes)
#   status              what each side runs, what is plugged, the latest onboarding runs, the scanner's findings
#   reset               claims data back to seed, latest back to 1.4.2, unplug (scripts/reset.sh --keep-allowance)
set -euo pipefail
B=parasol-build
cd "$(dirname "$0")/.."

latest_version() { oc get istag currency-converter:latest -n $B -o jsonpath='{.image.dockerImageMetadata.Config.Labels.org\.opencontainers\.image\.version}' 2>/dev/null || echo none; }
secured_version() { oc get application env-secured-tools -n openshift-gitops -o jsonpath='{.metadata.annotations.parasol\.example/onboarded-version}' 2>/dev/null; }
free_portal_has_tool() {
  oc get deploy portal -n parasol-free -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' | grep -qw CURRENCY_CONVERTER_MCP_URL
}

# $1 = Application, $2 = component, $3 = add|remove. Keeps the other components. Prints "changed" when it changed.
components() {
  local cur new
  cur=$(oc get application "$1" -n openshift-gitops -o jsonpath='{.spec.source.kustomize.components}')
  new=$(python3 -c '
import json, sys
cur = json.loads(sys.argv[1] or "[]"); c = sys.argv[2]
new = [x for x in cur if x != c] + ([c] if sys.argv[3] == "add" else [])
print("" if new == cur else json.dumps({"spec": {"source": {"kustomize": {"components": new or None}}}}))' "$cur" "$2" "$3")
  [ -z "$new" ] && return 0
  oc patch application "$1" -n openshift-gitops --type merge -p "$new" >/dev/null
  oc annotate application "$1" -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  echo changed
}

onboard_status() {  # $1 = run name
  oc get pipelinerun "$1" -n $B -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || true
}

case "${1:-status}" in
  release)
    v="${2:?usage: $0 release <version>}"
    oc get istag "currency-converter:$v" -n $B >/dev/null
    oc tag "$B/currency-converter:$v" "$B/currency-converter:latest" >/dev/null
    oc rollout restart deploy/currency-converter -n parasol-thirdparty >/dev/null
    oc rollout status deploy/currency-converter -n parasol-thirdparty --timeout=180s >/dev/null
    echo " the bank's latest: $v; the unsecured side (parasol-thirdparty) runs it now"
    echo " the secured side still runs: $(secured_version || true) (only onboarding changes it)" ;;
  onboard)
    v="${2:?usage: $0 onboard <version> [--wait]}"
    name="parasol-tool-onboarding-currency-converter-${v//./-}"
    # foreground: the old run's TaskRuns (same names) must be gone before the new run creates its own
    oc delete pipelinerun "$name" -n $B --ignore-not-found --cascade=foreground --wait=true >/dev/null
    # the Tekton controller can still hold the deleted run: a run re-created at once under the same name inherits
    # its old status (start time, timeout). Give the informer time to drop it.
    sleep 20
    scripts/results-prune.sh $B "$name" || true   # archived same-name runs would show in the console's graph
    sed -e "s/^  generateName: parasol-tool-onboarding-$/  name: $name/" -e "s/value: \"1.4.2\"/value: \"$v\"/" \
      gitops/platform/pipeline/onboarding/pipelinerun-onboarding.yaml | oc create -f - >/dev/null
    echo " $name started (onboarding currency-converter $v)"
    [ "${3:-}" = --wait ] || exit 0
    for _ in $(seq 1 90); do
      st=$(onboard_status "$name"); case "$st" in Succeeded|Completed|Failed|PipelineRunTimeout|Cancelled|PipelineValidationFailed|CouldntGetTask|CouldntGetPipeline) break;; esac
      echo "$(date +%T) $name: ${st:-Pending}"; sleep 20
    done
    r() { oc get pipelinerun "$name" -n $B -o jsonpath="{.status.results[?(@.name==\"$1\")].value}"; }
    echo " $name: $(onboard_status "$name")  gate=$(r GATE) findings=$(r FINDINGS) promoted=$(r PROMOTED_DIGEST)"
    [ "$(r GATE)" = passed ] ;;
  plug|unplug)
    changed=$(components env-free plug-in-vendor-tool "$([ "$1" = plug ] && echo add || echo remove)")
    for _ in $(seq 1 36); do
      if [ "$1" = plug ]; then free_portal_has_tool && break; else free_portal_has_tool || break; fi
      sleep 5
    done
    [ -n "$changed" ] && oc rollout status deploy/portal -n parasol-free --timeout=300s >/dev/null
    echo " free assistant: the bank's service $([ "$1" = plug ] && echo "plugged in (runs $(latest_version))" || echo unplugged)" ;;
  bypass-test)
    ref=$(oc get istag currency-converter:latest -n $B -o jsonpath='{.image.dockerImageReference}')
    echo " running the bank's latest ($(latest_version), $ref) in parasol-secured without onboarding (dry run):"
    oc set image deploy/currency-converter -n parasol-secured "server=$ref" --dry-run=server 2>&1 | sed 's/^/   /' || true ;;
  status)
    echo " the bank's latest: $(latest_version)   unsecured side (parasol-thirdparty) runs latest"
    echo " secured side (parasol-secured): $(secured_version || true) $(oc get application env-secured-tools -n openshift-gitops -o jsonpath='{.metadata.annotations.parasol\.example/onboarded-digest}' 2>/dev/null)"
    echo " free assistant: $(free_portal_has_tool && echo plugged in || echo unplugged)"
    oc get pipelinerun -n $B -l tekton.dev/pipeline=parasol-tool-onboarding \
      -o custom-columns='ONBOARDING:.metadata.name,STATUS:.status.conditions[0].reason,GATE:.status.results[?(@.name=="GATE")].value,FINDINGS:.status.results[?(@.name=="FINDINGS")].value' 2>/dev/null || true
    oc logs -n mcp-system deploy/mcp-tool-scanner --tail=200 2>/dev/null | grep -E 'currency-converter' | tail -4 || true ;;
  reset)
    scripts/reset.sh --keep-allowance ;;
  *) echo "usage: $0 release <v>|onboard <v> [--wait]|plug|unplug|bypass-test|status|reset" >&2; exit 2 ;;
esac
