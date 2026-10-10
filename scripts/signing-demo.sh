#!/usr/bin/env bash
# Layer 6 demo: the admission policy refuses an UNSIGNED portal image and admits the Chains-SIGNED
# one. Usage: scripts/signing-demo.sh [namespace]   (default: parasol-admission-demo)
# The namespace is labelled policy.rhtas.com/include=true for the duration and test pods are removed.
set -euo pipefail
NS="${1:-parasol-admission-demo}"
REG="image-registry.openshift-image-registry.svc:5000/parasol-build/parasol-portal"

echo "== Namespace: $NS =="
oc get ns "$NS" >/dev/null 2>&1 || oc create ns "$NS"
oc label ns "$NS" policy.rhtas.com/include=true --overwrite
oc create rolebinding sign-demo-pull -n parasol-build --clusterrole=system:image-puller \
  --group="system:serviceaccounts:$NS" --dry-run=client -o yaml | oc apply -f - >/dev/null

UNSIGNED=$(oc get istag parasol-portal:latest -n parasol-build -o jsonpath='{.image.metadata.name}')
SIGNED=$(oc get istag parasol-portal:signed  -n parasol-build -o jsonpath='{.image.metadata.name}')

echo; echo "== 1) UNSIGNED image ($UNSIGNED) -> expect DENY =="
oc delete pod portal-unsigned -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
oc run portal-unsigned --image="$REG@$UNSIGNED" -n "$NS" || true

echo; echo "== 2) Chains-SIGNED image ($SIGNED) -> expect ADMIT =="
oc delete pod portal-signed -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
oc run portal-signed --image="$REG@$SIGNED" -n "$NS"
oc get pod portal-signed -n "$NS" -o wide

echo; echo "== cleanup =="
oc delete pod portal-signed portal-unsigned -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
echo "done"
