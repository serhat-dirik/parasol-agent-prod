#!/usr/bin/env bash
# Supply chain (guide 07): everything the signed pipeline and admission need besides the Argo-synced
# Pipeline/Tasks. Idempotent; each item prints "already present" or what it creates.
#   1 SPIRE (workload identity): Tekton Chains' signing identity is a SPIFFE JWT-SVID
#   2 Trusted Artifact Signer (Fulcio trusts the SPIRE OIDC issuer, type spiffe, client ID sigstore) and the static
#     SPIRE entry for the Chains controller (SPIRE skips openshift-* namespaces otherwise)
#   3 Tekton Chains signs keyless: Fulcio certificate, Rekor entries, TUF trust root (TektonConfig spec.chain); the
#     TAS addresses for verify-conforma (ConfigMap parasol-build/tas-trust)
#   4 policy-controller (admission webhook), no-match-policy=allow
#   5 TrustRoot + ClusterImagePolicy rendered from THIS cluster's TUF root, Fulcio, Rekor and OIDC issuer
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
oc apply -f gitops/platform/tas/chains-spiffe-entry.yaml
oc wait securesign/securesign -n trusted-artifact-signer --for=condition=Ready --timeout=1350s
FULCIO_URL="https://fulcio-server-trusted-artifact-signer.$D" REKOR_URL="https://rekor-server-trusted-artifact-signer.$D"
TUF_URL="https://tuf-trusted-artifact-signer.$D" OIDC_ISSUER="https://oidc-discovery.$D"
export FULCIO_URL REKOR_URL TUF_URL OIDC_ISSUER

echo "== 3 Tekton Chains: keyless signing with Trusted Artifact Signer"
wait_for 40 15 "TektonConfig config" oc get tektonconfig config
# The Chains controller gets the SPIFFE Workload API socket; Fulcio turns its JWT-SVID into a 10-minute certificate.
oc patch tektonconfig config --type merge -p "{\"spec\":{\"chain\":{
  \"signers.x509.fulcio.enabled\": true,
  \"signers.x509.fulcio.address\": \"$FULCIO_URL\",
  \"signers.x509.fulcio.issuer\": \"$OIDC_ISSUER\",
  \"signers.x509.fulcio.provider\": \"spiffe\",
  \"signers.x509.tuf.mirror.url\": \"$TUF_URL\",
  \"transparency.enabled\": \"true\",
  \"transparency.url\": \"$REKOR_URL\",
  \"options\": {\"deployments\": {\"tekton-chains-controller\": {\"spec\": {\"template\": {\"spec\": {
    \"containers\": [{\"name\": \"tekton-chains-controller\",
      \"env\": [{\"name\": \"SPIFFE_ENDPOINT_SOCKET\", \"value\": \"/spiffe-workload-api/spire-agent.sock\"}],
      \"volumeMounts\": [{\"name\": \"spiffe-workload-api\", \"mountPath\": \"/spiffe-workload-api\", \"readOnly\": true}]}],
    \"volumes\": [{\"name\": \"spiffe-workload-api\", \"csi\": {\"driver\": \"csi.spiffe.io\", \"readOnly\": true}}]}}}}}}}}}"
wait_for 20 15 "Chains controller with the SPIFFE socket" sh -c \
  "oc get deploy tekton-chains-controller -n openshift-pipelines -o jsonpath='{.spec.template.spec.volumes[*].name}' | grep -q spiffe-workload-api"
oc rollout status deploy/tekton-chains-controller -n openshift-pipelines --timeout=300s
wait_for 40 15 "namespace parasol-build (Argo platform-builds)" oc get ns parasol-build
oc -n parasol-build create configmap tas-trust --from-literal=TUF_URL="$TUF_URL" --from-literal=REKOR_URL="$REKOR_URL" \
  --from-literal=OIDC_ISSUER="$OIDC_ISSUER" \
  --from-literal=SIGNER_IDENTITY=spiffe://parasol-demo/ns/openshift-pipelines/sa/tekton-chains-controller \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
echo "configmap parasol-build/tas-trust applied"
# Earlier installs: no key signs anything any more (Chains ignores signing-secrets once Fulcio is on).
oc delete secret cosign-signing-key parasol-onboarding-key onboarding-keygen-password -n parasol-build --ignore-not-found >/dev/null
oc delete configmap cosign-pub -n parasol-build --ignore-not-found >/dev/null
oc delete clusterspiffeid parasol-build-signer --ignore-not-found >/dev/null

echo "== 4 policy-controller (admission)"
wait_for 40 15 "PolicyController CRD" oc get crd policycontrollers.rhtas.charts.redhat.com
oc apply -f gitops/platform/pipeline/admission/policycontroller.yaml
wait_for 40 15 "policy-controller webhook" oc rollout status deploy/policy-controller-webhook -n policy-controller-operator --timeout=10s
wait_for 20 15 "ConfigMap config-policy-controller" oc get cm config-policy-controller -n policy-controller-operator
oc patch cm config-policy-controller -n policy-controller-operator --type merge -p '{"data":{"no-match-policy":"allow"}}'

echo "== 5 TrustRoot + ClusterImagePolicy for this cluster"
wait_for 40 15 "TUF root at $TUF_URL/root.json" curl -skf "$TUF_URL/root.json"
TUF_ROOT_B64="$(curl -skf "$TUF_URL/root.json" | base64 | tr -d '\n')"
export TUF_ROOT_B64
envsubst '$TUF_URL $TUF_ROOT_B64 $FULCIO_URL $REKOR_URL $OIDC_ISSUER' < gitops/platform/tas/clusterimagepolicy-keyless.yaml | oc apply -f -

echo "== 6 enforce on parasol-secured"
wait_for 40 15 "namespace parasol-secured (Argo env-secured)" oc get ns parasol-secured
oc label namespace parasol-secured policy.rhtas.com/include=true --overwrite
echo "supply chain ready: Tekton Chains signs keyless (SPIFFE -> Fulcio -> Rekor); admission enforced on parasol-secured"
