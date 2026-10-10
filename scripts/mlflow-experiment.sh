#!/usr/bin/env bash
# Ensure the MLflow experiment the OTel collector exports chat traces into exists.
# MLflow 3.x workspaces have no default experiment, so a fresh parasol-secured workspace needs one
# created before the collector's spans can land (otherwise /v1/traces 404s on experiment lookup).
# On a fresh workspace the first experiment gets id "1", which is what otel-collector.yaml references.
# Idempotent: re-running prints the existing id. Run after the MLflow instance is Available.
set -euo pipefail
NS=${MLFLOW_NS:-parasol-secured}
NAME=${EXPERIMENT_NAME:-parasol-portal-chat}
BASE=https://mlflow.redhat-ods-applications.svc:8443
TOK=$(oc create token otel-collector -n observability)
hdr=(-H "Authorization: Bearer $TOK" -H "x-mlflow-workspace: $NS" -H "Content-Type: application/json")

# curl runs from a short-lived pod in observability (in-cluster TLS + DNS to the MLflow service).
POD=mlflow-setup
oc -n observability delete pod "$POD" --ignore-not-found >/dev/null 2>&1 || true
oc -n observability run "$POD" --image=registry.access.redhat.com/ubi9/ubi-minimal:latest --restart=Never --command -- sleep 120 >/dev/null
oc -n observability wait --for=condition=Ready "pod/$POD" --timeout=90s >/dev/null
run(){ oc -n observability exec "$POD" -- "$@"; }

existing=$(run curl -sk "${hdr[@]}" -X POST -d '{"max_results":100}' \
  "$BASE/mlflow/api/2.0/mlflow/experiments/search" 2>/dev/null || true)
id=$(printf '%s' "$existing" | python3 -c 'import sys,json
d=json.load(sys.stdin); n=sys.argv[1]
print(next((e["experiment_id"] for e in d.get("experiments",[]) if e.get("name")==n),""))' "$NAME" 2>/dev/null || true)

if [ -z "$id" ]; then
  created=$(run curl -sk "${hdr[@]}" -X POST -d "{\"name\":\"$NAME\"}" \
    "$BASE/mlflow/api/2.0/mlflow/experiments/create" 2>/dev/null)
  id=$(printf '%s' "$created" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("experiment_id",""))' 2>/dev/null || true)
  echo "created experiment '$NAME' id=$id in workspace $NS"
else
  echo "experiment '$NAME' already exists id=$id in workspace $NS"
fi
oc -n observability delete pod "$POD" --ignore-not-found >/dev/null 2>&1 || true
[ "$id" = "1" ] || echo "WARNING: experiment id is '$id', not 1 - update x-mlflow-experiment-id in gitops/platform/observability/otel-collector.yaml"
