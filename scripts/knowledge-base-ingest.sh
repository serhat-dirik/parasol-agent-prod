#!/usr/bin/env bash
# knowledge-base-ingest.sh [namespace...]  (default: parasol-free parasol-secured)
# Embeds the knowledge-base documents (baked into the knowledge-base image) and loads them into that
# environment's pgvector database: a Job on the same image, as the database superuser. Idempotent and
# re-runnable: schema/roles/policy are created if missing, every chunk is replaced. parasol-secured turns
# row-level security on (KB_SECURED=true); parasol-free leaves it off (the uncontrolled baseline).
set -euo pipefail
NSS=("$@"); [ ${#NSS[@]} -gt 0 ] || NSS=(parasol-free parasol-secured)
IMG=$(oc get istag knowledge-base:latest -n parasol-build -o jsonpath='{.image.dockerImageReference}')
[ -n "$IMG" ] || { echo "no knowledge-base image yet: scripts/build-images.sh"; exit 1; }
fail=0
for ns in "${NSS[@]}"; do
  secured=false; [ "$ns" = parasol-secured ] && secured=true
  for i in $(seq 1 40); do
    oc rollout status deploy/knowledge-base-db -n "$ns" --timeout=5s >/dev/null 2>&1 && break
    echo "$(date +%T) waiting for knowledge-base-db in $ns ($i/40)"; sleep 15
  done
  oc delete job knowledge-base-ingest -n "$ns" --ignore-not-found --wait=true >/dev/null
  oc apply -n "$ns" -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: knowledge-base-ingest
  labels: {app: knowledge-base-ingest}
spec:
  backoffLimit: 3
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels: {app: knowledge-base-ingest}
    spec:
      restartPolicy: OnFailure
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: ingest
          image: $IMG
          command: [python3, ingest.py]
          env:
            - name: KB_ADMIN_PASSWORD
              valueFrom: {secretKeyRef: {name: knowledge-base-db, key: admin-password}}
            - name: KB_APP_PASSWORD
              valueFrom: {secretKeyRef: {name: knowledge-base-db, key: app-password}}
            - {name: KB_ADMIN_DSN, value: "host=knowledge-base-db dbname=kb user=postgres password=\$(KB_ADMIN_PASSWORD)"}
            - {name: KB_SECURED, value: "$secured"}
          resources:
            requests: {cpu: 200m, memory: 768Mi}
            limits: {cpu: "1", memory: 1536Mi}
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
YAML
  if oc wait job/knowledge-base-ingest -n "$ns" --for=condition=Complete --timeout=600s >/dev/null; then
    oc logs job/knowledge-base-ingest -n "$ns" | grep '^ingested' | sed "s/^/$ns: /"
  else
    echo "$ns: ingestion did not complete: oc logs job/knowledge-base-ingest -n $ns"; fail=1
  fi
done
exit $fail
