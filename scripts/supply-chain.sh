#!/usr/bin/env bash
# Supply chain (guide 07): everything the signed pipeline and admission need besides the Argo-synced
# Pipeline/Tasks. Idempotent; each item prints "already present" or what it creates.
#   1 SPIRE (workload identity): the pipeline's keyless signer is a SPIFFE JWT-SVID
#   2 Trusted Artifact Signer (Fulcio trusts the SPIRE OIDC issuer, type spiffe), ClusterSPIFFEID for the signer
#   3 cosign keypair for Tekton Chains (openshift-pipelines/signing-secrets) + its copies in parasol-build
#   4 policy-controller (admission webhook), no-match-policy=allow
#   5 TrustRoot + ClusterImagePolicy rendered from THIS cluster's TUF root, OIDC issuer and cosign key
#   6 parasol-secured enforced (label policy.rhtas.com/include=true)
# Expected: SPIRE 2-5 min, Securesign 5-15 min. Re-run after a WARN; it resumes where it stopped.
set -euo pipefail
cd "$(dirname "$0")/.."
export CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')}"
D="apps.$CLUSTER_DOMAIN"
wait_for() {  # wait_for <tries> <sleep-s> <what> <command...>
  local n=$1 s=$2 what=$3 i; shift 3
  for i in $(seq 1 "$n"); do "$@" >/dev/null 2>&1 && return 0; echo "$(date +%T) waiting for $what ($i/$n)"; sleep "$s"; done
  echo "deadline: $what"; return 1
}

echo "== 1 SPIRE"
wait_for 40 15 "SPIRE CRDs" oc get crd zerotrustworkloadidentitymanagers.operator.openshift.io spireservers.operator.openshift.io
kustomize build gitops/platform/workload-identity | envsubst '$CLUSTER_DOMAIN' | oc apply -f -
wait_for 40 15 "SPIRE OIDC discovery (https://oidc-discovery.$D)" \
  sh -c "curl -skf https://oidc-discovery.$D/.well-known/openid-configuration"

echo "== 2 Trusted Artifact Signer"
wait_for 40 15 "Securesign CRD" oc get crd securesigns.rhtas.redhat.com
envsubst '$CLUSTER_DOMAIN' < gitops/platform/tas/securesign.yaml | oc apply -f -
oc apply -f gitops/platform/tas/clusterspiffeid-signer.yaml
oc wait securesign/securesign -n trusted-artifact-signer --for=condition=Ready --timeout=1350s

echo "== 3 cosign keypair (Tekton Chains)"
wait_for 40 15 "namespace openshift-pipelines" oc get ns openshift-pipelines
if [ -n "$(oc get secret signing-secrets -n openshift-pipelines -o jsonpath='{.data.cosign\.pub}' 2>/dev/null)" ]; then
  echo "signing-secrets: already present"
else
  echo "signing-secrets: generating the cluster keypair in-cluster (the private key never leaves the cluster)"
  oc -n openshift-pipelines get secret cosign-keygen-password >/dev/null 2>&1 || \
    oc -n openshift-pipelines create secret generic cosign-keygen-password --from-literal=password="$(openssl rand -hex 16)" >/dev/null
  oc delete job cosign-keygen -n openshift-pipelines --ignore-not-found >/dev/null
  oc apply -f - <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata: {name: cosign-keygen, namespace: openshift-pipelines}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: cosign-keygen, namespace: openshift-pipelines}
rules:
  - {apiGroups: [""], resources: [secrets], verbs: [get, create, update, patch, delete]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: cosign-keygen, namespace: openshift-pipelines}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: cosign-keygen}
subjects: [{kind: ServiceAccount, name: cosign-keygen, namespace: openshift-pipelines}]
---
apiVersion: batch/v1
kind: Job
metadata: {name: cosign-keygen, namespace: openshift-pipelines}
spec:
  backoffLimit: 2
  template:
    spec:
      serviceAccountName: cosign-keygen
      restartPolicy: Never
      containers:
        - name: keygen
          image: ghcr.io/sigstore/cosign/cosign:v2.4.3
          args: ["generate-key-pair", "k8s://openshift-pipelines/signing-secrets"]
          env:
            - name: COSIGN_PASSWORD
              valueFrom: {secretKeyRef: {name: cosign-keygen-password, key: password}}
YAML
  oc wait job/cosign-keygen -n openshift-pipelines --for=condition=complete --timeout=300s
  oc rollout restart deploy/tekton-chains-controller -n openshift-pipelines
fi
wait_for 40 15 "namespace parasol-build (Argo platform-builds)" oc get ns parasol-build
scripts/signing-key-to-build.sh
oc get secret signing-secrets -n openshift-pipelines -o jsonpath='{.data.cosign\.pub}' | base64 -d > /tmp/parasol-cosign.pub.$$
oc -n parasol-build create configmap cosign-pub --from-file=cosign.pub=/tmp/parasol-cosign.pub.$$ --dry-run=client -o yaml | oc apply -f - >/dev/null
echo "configmap parasol-build/cosign-pub applied"

echo "== 4 policy-controller (admission)"
wait_for 40 15 "PolicyController CRD" oc get crd policycontrollers.rhtas.charts.redhat.com
oc apply -f gitops/platform/pipeline/admission/policycontroller.yaml
wait_for 40 15 "policy-controller webhook" oc rollout status deploy/policy-controller-webhook -n policy-controller-operator --timeout=10s
wait_for 20 15 "ConfigMap config-policy-controller" oc get cm config-policy-controller -n policy-controller-operator
oc patch cm config-policy-controller -n policy-controller-operator --type merge -p '{"data":{"no-match-policy":"allow"}}'

echo "== 5 TrustRoot + ClusterImagePolicy for this cluster"
export TUF_URL="https://tuf-trusted-artifact-signer.$D" OIDC_ISSUER="https://oidc-discovery.$D"
wait_for 40 15 "TUF root at $TUF_URL/root.json" curl -skf "$TUF_URL/root.json"
TUF_ROOT_B64="$(curl -skf "$TUF_URL/root.json" | base64 | tr -d '\n')"
COSIGN_PUB="$(sed 's/^/          /' /tmp/parasol-cosign.pub.$$)"
export TUF_ROOT_B64 COSIGN_PUB
rm -f /tmp/parasol-cosign.pub.$$
envsubst '$TUF_URL $TUF_ROOT_B64 $OIDC_ISSUER $COSIGN_PUB' < gitops/platform/tas/clusterimagepolicy-keyless.yaml | oc apply -f -

echo "== 6 enforce on parasol-secured"
wait_for 40 15 "namespace parasol-secured (Argo env-secured)" oc get ns parasol-secured
oc label namespace parasol-secured policy.rhtas.com/include=true --overwrite
echo "supply chain ready: keyless (SPIFFE -> Fulcio -> Rekor) + cluster key; admission enforced on parasol-secured"
