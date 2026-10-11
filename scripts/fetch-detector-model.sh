#!/usr/bin/env bash
# Download protectai/deberta-v3-base-prompt-injection-v2 into the detector PVC with a one-off job.
set -euo pipefail
# A Job pod template is immutable: drop a previous (failed or stale) copy before applying.
oc delete job fetch-prompt-injection-model -n parasol-secured --ignore-not-found
# The PVC is ReadWriteOnce: if the detector predictor already mounts it, the job must run on that node
# (pods on one node share an RWO volume; on another node the attach fails with Multi-Attach).
node=$(oc get pods -n parasol-secured -o json | python3 -c 'import sys,json
for p in json.load(sys.stdin)["items"]:
    if p["status"].get("phase")=="Running" and any(v.get("persistentVolumeClaim",{}).get("claimName")=="prompt-injection-model" for v in p["spec"].get("volumes",[])):
        print(p["spec"]["nodeName"]); break')
pin=""; [ -n "$node" ] && pin="      nodeSelector: {kubernetes.io/hostname: $node}" && echo "detector PVC in use on $node: the fetch job runs there"
sed "s|^      #NODE_PIN#\$|$pin|" <<'YAML' | oc apply -n parasol-secured -f -
# parasol-secured is default-deny: this one-off job needs DNS and HTTPS to huggingface.co
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: fetch-detector-model-egress}
spec:
  podSelector:
    matchLabels: {job-name: fetch-prompt-injection-model}
  policyTypes: [Egress]
  egress:
    - ports: [{protocol: UDP, port: 5353}, {protocol: TCP, port: 5353}, {protocol: UDP, port: 53}, {protocol: TCP, port: 53}, {protocol: TCP, port: 443}]
---
apiVersion: batch/v1
kind: Job
metadata: {name: fetch-prompt-injection-model}
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      #NODE_PIN#
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
