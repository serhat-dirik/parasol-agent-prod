#!/usr/bin/env bash
# maas-extproc-reload.sh : reload the MaaS ai-gateway payload-processing ext-procs so their apikey-injection
# credential store picks up upstream secrets for ExternalModels added after the ext-procs started.
# SYMPTOM this fixes: a newly-registered ExternalModel resolves (model-provider-resolver) but the gateway
# returns HTTP 500 with ext-proc log "credentials not found in store" (apikey-injection/plugin.go). The
# store is read at startup; new ExternalProvider secrets are not hot-reloaded. Rolling restart reloads it.
# Deployments have 1 replica with the default RollingUpdate (maxSurge 1), so a new pod comes up before the
# old is torn down -> near-zero downtime on the shared model path. Still a wave-1 data-path component, so
# run it deliberately and re-verify the secured model path afterwards.
set -euo pipefail
NS=openshift-ingress
oc rollout restart deploy/payload-processing deploy/payload-pre-processing -n "$NS"
oc rollout status deploy/payload-processing -n "$NS" --timeout=120s
oc rollout status deploy/payload-pre-processing -n "$NS" --timeout=120s
echo "payload-processing ext-procs reloaded"
