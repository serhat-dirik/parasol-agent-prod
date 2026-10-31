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

# Unsigned: the istag kept for this beat (no .sig artifact under either authority; :latest is signed
# now, so it cannot serve as the unsigned case). Signed: the digest the release promoted, read from
# the Argo CD Application env-secured (the pin is not in Git), else from the running secured portal.
UNSIGNED=$(oc get istag parasol-portal:unsigned -n parasol-build -o jsonpath='{.image.metadata.name}')
SIGNED=$(oc get applications.argoproj.io env-secured -n openshift-gitops \
  -o jsonpath='{.metadata.annotations.parasol\.example/promoted-digest}' 2>/dev/null || true)
[ -n "$SIGNED" ] || SIGNED=$(oc get deploy portal -n parasol-secured -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*@//')
case "$SIGNED" in sha256:*) ;; *) echo "no promoted portal digest yet (run scripts/pipeline-runs.sh)"; exit 1;; esac
if oc get istag "parasol-portal:${UNSIGNED/:/-}.sig" -n parasol-build >/dev/null 2>&1; then
  echo "parasol-portal:unsigned ($UNSIGNED) carries a signature; pick an unsigned image"; exit 1
fi

echo; echo "== 1) UNSIGNED image ($UNSIGNED) -> expect DENY =="
oc delete pod portal-unsigned -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
oc run portal-unsigned --image="$REG@$UNSIGNED" -n "$NS" || true

echo; echo "== 2) SIGNED image the release promoted ($SIGNED) -> expect ADMIT =="
oc delete pod portal-signed -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
oc run portal-signed --image="$REG@$SIGNED" -n "$NS"
oc get pod portal-signed -n "$NS" -o wide

echo; echo "== cleanup =="
oc delete pod portal-signed portal-unsigned -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
echo "done"
