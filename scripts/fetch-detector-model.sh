#!/usr/bin/env bash
# Download protectai/deberta-v3-base-prompt-injection-v2 into the detector PVC with a one-off job.
set -euo pipefail
# A Job pod template is immutable: drop a previous (failed or stale) copy before applying.
oc delete job fetch-prompt-injection-model -n parasol-secured --ignore-not-found
oc apply -n parasol-secured -f - <<'YAML'
apiVersion: batch/v1
kind: Job
metadata: {name: fetch-prompt-injection-model}
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: fetch
          image: registry.access.redhat.com/ubi9/python-312:latest
          command: ["/bin/bash","-c"]
          args:
            - pip install -q huggingface_hub && python -c "from huggingface_hub import snapshot_download; snapshot_download('protectai/deberta-v3-base-prompt-injection-v2', local_dir='/mnt/models/prompt-injection')" && ls -la /mnt/models/prompt-injection
          resources:   # parasol-secured has a ResourceQuota: pods without requests/limits are rejected
            requests: {cpu: 250m, memory: 512Mi}
            limits: {cpu: "1", memory: 2Gi}
          volumeMounts: [{name: models, mountPath: /mnt/models}]
      volumes:
        - name: models
          persistentVolumeClaim: {claimName: prompt-injection-model}
YAML
oc wait --for=condition=complete job/fetch-prompt-injection-model -n parasol-secured --timeout=1350s
