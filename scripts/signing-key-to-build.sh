#!/usr/bin/env bash
# Copy the cluster cosign signing key (the one Tekton Chains uses) into the parasol-build namespace
# as secret `cosign-signing-key`, so the pipeline's sign-images and generate-sbom tasks can
# cosign-sign the three images and attach the SBOM attestation. The private key must never be
# committed to Git, so this is a setup step (like bootstrap's other secret copies), run once.
# Idempotent. Usage: scripts/signing-key-to-build.sh
set -euo pipefail
SRC_NS=openshift-pipelines
SRC=signing-secrets
DST_NS=parasol-build
DST=cosign-signing-key

oc get ns "$DST_NS" >/dev/null 2>&1 || { echo "namespace $DST_NS not found"; exit 1; }
oc get secret "$SRC" -n "$SRC_NS" >/dev/null 2>&1 || { echo "source secret $SRC_NS/$SRC not found (Tekton Chains signing key)"; exit 1; }

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
oc create secret generic "$DST" -n "$DST_NS" \
  --from-literal=cosign.key="$(oc get secret "$SRC" -n "$SRC_NS" -o jsonpath='{.data.cosign\.key}' | base64 -d)" \
  --from-literal=cosign.password="$(oc get secret "$SRC" -n "$SRC_NS" -o jsonpath='{.data.cosign\.password}' | base64 -d)" \
  --from-literal=cosign.pub="$(oc get secret "$SRC" -n "$SRC_NS" -o jsonpath='{.data.cosign\.pub}' | base64 -d)" \
  --dry-run=client -o yaml > "$TMP"
oc apply -f "$TMP" >/dev/null
echo "applied secret $DST_NS/$DST (cosign.key, cosign.password, cosign.pub)"
