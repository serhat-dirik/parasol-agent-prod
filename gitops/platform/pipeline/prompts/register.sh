#!/usr/bin/env bash
# Register the claims-assistant system prompt (v1 + v2) in the MLflow Prompt Registry,
# workspace parasol-secured. Idempotent: the Job runs with RESET=1 so v1/v2 numbering is
# always deterministic. Run as cluster-admin (or any identity that can create the Job/SA).
#
#   gitops/platform/pipeline/prompts/register.sh
#
# The same register-prompts.py is what the Tekton agent-eval gate imports to pin the two
# versions it evaluates; the promote task's commit references name@version.
set -euo pipefail
NS=observability
DIR="$(cd "$(dirname "$0")" && pwd)"

oc apply -f "$DIR/rbac.yaml"
oc -n "$NS" delete configmap parasol-prompt-registrar --ignore-not-found
oc -n "$NS" create configmap parasol-prompt-registrar \
  --from-file=register-prompts.py="$DIR/register-prompts.py" \
  --from-file=v1.txt="$DIR/v1.txt" \
  --from-file=v2.txt="$DIR/v2.txt"
oc -n "$NS" delete job parasol-prompt-registrar --ignore-not-found
oc apply -f "$DIR/register-job.yaml"
oc -n "$NS" wait --for=condition=complete job/parasol-prompt-registrar --timeout=180s
oc -n "$NS" logs job/parasol-prompt-registrar | grep -E 'registered|loaded'
