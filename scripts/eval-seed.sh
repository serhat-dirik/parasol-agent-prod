#!/usr/bin/env bash
# Scenario 4 data: the golden-set evaluation of prompt v1 (20/20 PASS) and v2 (17/20 BLOCK) in MLflow
# experiment parasol-agent-eval (workspace parasol-secured), each case judged by the JUDGE model.
# Runs gitops/platform/eval/mlflow-agent-eval/agent_eval.py once as a Job in parasol-build (SA pipeline,
# the identity the Tekton agent-eval gate uses; judge endpoint + key from Secret maas-eval-key).
# Idempotent: a completed Job is reused, never re-run (delete job/parasol-eval-seed to force a fresh run).
# Prints "MLFLOW_EXPERIMENT_ID=.. RUN_ID_V1=.. RUN_ID_V2=.." for the Model Registry registration.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=parasol-build JOB=parasol-eval-seed SRC=gitops/platform/eval/mlflow-agent-eval

oc apply -f "$SRC/rbac.yaml" >/dev/null   # pipeline SA: mlflow edit/view in parasol-secured
if [ "$(oc get job $JOB -n $NS -o jsonpath='{.status.succeeded}' 2>/dev/null)" != 1 ]; then
  oc delete job $JOB -n $NS --ignore-not-found >/dev/null
  oc -n $NS create configmap parasol-eval-seed --from-file="$SRC/agent_eval.py" \
    --from-file="$SRC/golden-set-20.json" --from-file="$SRC/candidates.json" --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc apply -f - >/dev/null <<'YAML'
apiVersion: batch/v1
kind: Job
metadata: {name: parasol-eval-seed, namespace: parasol-build}
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: pipeline
      containers:
        - name: eval
          image: registry.access.redhat.com/ubi9/python-311:latest
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -eu
              pip install --quiet --no-cache-dir "mlflow==3.4.0" openai requests >/tmp/pip.log 2>&1 || cat /tmp/pip.log
              mkdir -p /tmp/e && cp /src/* /tmp/e/
              if [ -f /maas/endpoint ]; then export MAAS_ENDPOINT_FILE=/maas/endpoint MAAS_EVAL_KEY_FILE=/maas/key; else export NO_JUDGE=1; fi
              python3 /tmp/e/agent_eval.py --run --versions v1,v2 --no-fail
          env:
            - {name: MLFLOW_TRACKING_URI, value: "https://mlflow.redhat-ods-applications.svc:8443/mlflow"}
            - {name: MLFLOW_WORKSPACE, value: parasol-secured}
            - {name: MLFLOW_EXPERIMENT, value: parasol-agent-eval}
            - {name: MLFLOW_TRACKING_INSECURE_TLS, value: "true"}
            - {name: TOKEN_FILE, value: /var/run/secrets/kubernetes.io/serviceaccount/token}
            - {name: HOME, value: /tmp}
          volumeMounts:
            - {name: src, mountPath: /src}
            - {name: maas, mountPath: /maas, readOnly: true}
          resources:
            requests: {cpu: 200m, memory: 512Mi}
            limits: {cpu: "1", memory: 2Gi}
      volumes:
        - {name: src, configMap: {name: parasol-eval-seed}}
        - {name: maas, secret: {secretName: maas-eval-key, optional: true}}
YAML
  echo "eval seed job started (pip install + 40 judged cases, ~10-20 min)"
  for i in $(seq 1 60); do   # deadline 30 min
    [ "$(oc get job $JOB -n $NS -o jsonpath='{.status.succeeded}')" = 1 ] && break
    [ "$(oc get job $JOB -n $NS -o jsonpath='{.status.failed}')" = 2 ] && { oc logs job/$JOB -n $NS --tail=30; exit 1; }
    echo "$(date +%T) eval seed: $(oc logs job/$JOB -n $NS 2>/dev/null | wc -l | tr -d ' ') log lines ($i/60)"
    sleep 30
  done
fi
summary=$(oc logs job/$JOB -n $NS 2>/dev/null | sed -n 's/^SUMMARY //p' | tail -1)
[ -n "$summary" ] || { echo "no SUMMARY in job/$JOB log (still running or failed): oc logs job/$JOB -n $NS"; exit 1; }
printf '%s' "$summary" | python3 -c '
import json, re, sys
s = json.load(sys.stdin)
v1, v2 = s["v1"], s["v2"]
exp = re.search(r"/experiments/([^/]+)/", v1["run_url"]).group(1)
print("MLFLOW_EXPERIMENT_ID=%s RUN_ID_V1=%s RUN_ID_V2=%s" % (exp, v1["run_id"], v2["run_id"]))
print("# v1 %d/20 gate=%s, v2 %d/20 gate=%s" % (v1["passes"], v1["gate_pass"], v2["passes"], v2["gate_pass"]), file=sys.stderr)'
