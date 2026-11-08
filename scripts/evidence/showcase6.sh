#!/usr/bin/env bash
# showcase6.sh <topic> : evidence of Showcase 6, the evaluation gate (read-only)
#   gate      both release runs: the evaluation verdict, the score, the agent version, promoted or not
#   prompt    the prompt the release pinned against the prompt the portal runs (also Showcase 1)
#   tiers     the MaaS subscriptions, the evaluation's own among them (showcase4.sh tiers)
. "$(dirname "$0")/lib.sh"

case "${1:-}" in
gate)
  title "The two release runs (parasol-build), from each run's own results"
  for c in production candidate-shortened; do
    run "oc get pipelinerun parasol-portal-release-$c -n parasol-build -o json" | python3 -c '
import sys, json
p = json.load(sys.stdin); r = {x["name"]: x["value"] for x in p.get("status", {}).get("results", [])}
sk = [t["name"] for t in p.get("status", {}).get("skippedTasks", [])]
print("  %-20s gate=%-6s score=%-5s agent=%-26s promote=%-7s image=%s promoted=%s mlflow_run=%s" % (sys.argv[1],
      r.get("EVAL_GATE", "?"), r.get("EVAL_SCORE", "?"), r.get("AGENT_VERSION", "-"), "skipped" if "promote" in sk else "ran",
      r.get("IMAGE_DIGEST", "-")[7:19], r.get("PROMOTED_DIGEST", "-")[7:19] or "-", r.get("MLFLOW_RUN_ID", "-")[:12]))' "$c" \
      || echo "  $c: no run (scripts/pipeline-runs.sh starts it)"
  done
  title "The bar (the golden set in Git)"
  run "python3 -c 'import json; d = json.load(open(\"gitops/platform/eval/mlflow-agent-eval/golden-set.json\")); print(\"  %d cases, pass at least %.2f with the platform\" % (len(d[\"cases\"]), d[\"gate_threshold\"]))'"
  title "The evaluation's own MaaS subscription (agent model, and the judge model when it is listed)"
  run "oc get maassubscription parasol-eval -n models-as-a-service -o jsonpath='{range .spec.modelRefs[*]}{\"  \"}{.name}{\"\\n\"}{end}' 2>/dev/null" \
    || echo "  (not readable here: OpenShift AI, Settings, MaaS governance)" ;;
prompt)
  title "The prompt the release pinned (Argo CD Application env-secured) and the prompt the secured portal runs"
  pin=$(run "oc get application env-secured -n openshift-gitops -o json" | python3 -c '
import sys, json; a = json.load(sys.stdin)["metadata"]["annotations"]
print(a.get("parasol.example/prompt-version", "-"), a.get("parasol.example/prompt-sha256", "-"))')
  cur=$(run "oc get cm agent-prompt-release -n parasol-secured -o json" | python3 -c '
import sys, json, hashlib; d = json.load(sys.stdin)["data"]
print(d.get("promptVersion", "-"), hashlib.sha256(d.get("systemPrompt", "").encode()).hexdigest())')
  echo "  pinned by the release:          $pin"
  echo "  running (agent-prompt-release): $cur"
  [ "${pin#* }" = "${cur#* }" ] && note "  same sha256: the portal runs exactly the text the gate evaluated." \
    || echo "  DIFFERENT: the running prompt is not the released one." ;;
tiers) exec "$EV/showcase4.sh" tiers ;;
*) usage ;;
esac
