#!/usr/bin/env bash
# Stream S2 red-team. Runs one bounded Garak red-team run IN-CLUSTER against the SECURED guardrails
# endpoint (eval-guardrails-proxy: production detector preset + llama-scout-17b), using MaaS KEY 2.
# No agent key, no storms: one bounded injection probe, one generation per prompt.
#
#   scripts/garak.sh [probe]        probe defaults to promptinject.HijackHateHumansMini
#
# Reads KEY 2 (litellm_user2_virtual_key) from the credentials file (CREDENTIALS_FILE or the default
# location) and puts it in Secret maas-eval-key; the key value is never printed or committed.
set -uo pipefail
# Bounded, injection-relevant probe (the active/reduced variant, not the 💤 Full one): no storms.
PROBE="${1:-promptinject.HijackHateHumans}"
NS=parasol-eval
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CRED="${CREDENTIALS_FILE:-}"
if [ -z "$CRED" ]; then
  for c in "$ROOT/../credentials.txt" "$ROOT/../../credentials.txt" "$ROOT/../../../credentials.txt" "$ROOT/../../../../credentials.txt"; do
    [ -r "$c" ] && { CRED="$c"; break; }
  done
fi
[ -r "$CRED" ] || { echo "credentials file not found (set CREDENTIALS_FILE)"; exit 1; }
KEY2="$(awk '$0=="litellm_user2_virtual_key"{getline;print;exit}' "$CRED")"
[ -n "$KEY2" ] || { echo "litellm_user2_virtual_key not found in $CRED"; exit 1; }

echo "== applying eval guardrails proxy (namespace $NS) =="
oc apply -f "$ROOT/gitops/platform/eval/eval-guardrails-proxy.yaml"
oc create secret generic maas-eval-key -n "$NS" --from-literal=key="$KEY2" \
  --dry-run=client -o yaml | oc apply -f -
oc rollout restart deploy/eval-guardrails-proxy -n "$NS" >/dev/null 2>&1 || true
oc rollout status deploy/eval-guardrails-proxy -n "$NS" --timeout=180s

echo "== launching Garak job (probe=$PROBE) =="
oc delete job garak -n "$NS" --ignore-not-found >/dev/null 2>&1
cat <<YAML | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: garak
  namespace: $NS
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1500
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: garak
          image: registry.access.redhat.com/ubi9/python-312:latest
          env:
            - {name: PROBE, value: "$PROBE"}
            - {name: HOME, value: /opt/app-root/src}
          command: ["bash","-lc"]
          args:
            - |
              set -e
              echo "[garak] installing (pip) ..."
              pip install --quiet --no-cache-dir "garak==0.12.0" 2>&1 | tail -2 || pip install --quiet --no-cache-dir garak 2>&1 | tail -2
              cat > /tmp/rest.json <<'JSON'
              {
                "rest": {
                  "RestGenerator": {
                    "name": "parasol-secured-guardrails",
                    "uri": "http://eval-guardrails-proxy.$NS.svc:8080/v1/chat/completions",
                    "method": "post",
                    "headers": {"Content-Type": "application/json", "Authorization": "Bearer eval"},
                    "req_template_json_object": {"model": "llama-scout-17b", "temperature": 0, "max_tokens": 128, "messages": [{"role": "user", "content": "\$INPUT"}]},
                    "response_json": true,
                    "response_json_field": "\$.choices[0].message.content"
                  }
                }
              }
              JSON
              echo "[garak] version:"; python -m garak --version || true
              echo "[garak] running probe \$PROBE ..."
              python -m garak -m rest -G /tmp/rest.json -p "\$PROBE" -g 1 \
                --report_prefix /tmp/parasol-garak 2>&1 | tee /tmp/garak.out
              echo "==== GARAK REPORT FILES ===="
              ls -la /tmp/parasol-garak* || true
              echo "==== GARAK DIGEST (eval summary lines) ===="
              grep -E "garak|probe|detector|passed|FAIL|PASS|hitrate|total|Run config" /tmp/garak.out | tail -40 || true
YAML

echo "== streaming Garak job logs (bounded) =="
for i in $(seq 1 60); do
  oc get pod -n "$NS" -l job-name=garak -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -qE 'Running|Succeeded|Failed' && break
  echo "  waiting for garak pod to start ($i)"; sleep 5
done
timeout 1400 oc logs -f job/garak -n "$NS" 2>/dev/null || true
echo "== final job status =="
oc get job garak -n "$NS" -o jsonpath='{.status}{"\n"}'
