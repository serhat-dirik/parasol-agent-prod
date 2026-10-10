#!/usr/bin/env bash
# Register the Parasol claims-assistant (RegisteredModel + ModelVersions v1/v2 with the agent-eval
# result) in the RHOAI Model Registry parasol-model-registry. Idempotent (re-running refreshes
# metadata). Run as cluster-admin (or any identity that can create the SA/Job).
#
#   gitops/platform/model-registry/register.sh
#
# The same register-model.py is what the Tekton register-model-version gate step imports with
# --patch-eval to stamp a run's gate/score/mlflow-run-id onto the matching ModelVersion.
set -euo pipefail
NS=observability
DIR="$(cd "$(dirname "$0")" && pwd)"

oc apply -f "$DIR/rbac.yaml"
oc -n "$NS" delete configmap parasol-model-registrar --ignore-not-found
oc -n "$NS" create configmap parasol-model-registrar \
  --from-file=register-model.py="$DIR/register-model.py"
oc -n "$NS" delete job parasol-model-registrar --ignore-not-found
oc apply -f "$DIR/register-job.yaml"
oc -n "$NS" wait --for=condition=complete job/parasol-model-registrar --timeout=180s
oc -n "$NS" logs job/parasol-model-registrar
