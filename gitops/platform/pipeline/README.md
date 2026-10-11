# Secure supply-chain pipeline (layer 6: the lifecycle gate)

A Tekton pipeline in namespace `parasol-build` that **builds the Parasol portal from source**,
**scans** it, attaches a signed **SBOM**, runs the **agent evaluation gate**, **signs** it keyless
(Trusted Artifact Signer) and with the cluster key, checks the **Conforma** contract, and
**promotes** the signed digest by pinning it on the Argo CD Application `env-secured`
(`spec.source.kustomize.images`; no Git write, the repo is read-only for releases); Argo CD rolls the
secured portal to it and admission verifies the signature. Task names and order
mirror the Red Hat `tssc-sample-pipelines` reference; ACS/Quay/GitLab are not on this cluster, so
the scan is Trivy, the registry is the internal OpenShift registry and the SCM is GitHub.

The Tasks and the Pipeline are desired state, synced by the Argo CD Application
`platform-pipeline` (`gitops/bootstrap/apps/platform-pipeline.yaml`). PipelineRuns are events and
are created by hand from `pipelinerun.yaml`, which is not part of the synced kustomization.

```
init → clone-repository → build-container ─┬→ scan-image (Trivy) ──────────────────────────┐
                                           ├→ generate-sbom (syft CycloneDX, cosign attest)  │
                                           ├→ agent-eval (gate) → register-model-version    ├→ promote
                                           ├→ sign-images (cluster key) ─┐                  │  (pin on Argo app)
                                           └→ keyless-sign (TAS) ────────┴→ verify-enterprise-contract
finally: show-sbom, show-summary
```

`agent-eval` runs the MLflow evaluation of the claims assistant (agent model qwen3-14b, judge
gpt-oss-120b on its own key in secret `maas-eval-key`); below 19/20 the gate is `failed` and
`promote` is skipped. `verify-enterprise-contract` is the Conforma gate: the image must carry a valid
signature AND a signed SLSA provenance attestation (Tekton Chains). The SBOM ships as a signed
cosign attestation (`cosign verify-attestation --type cyclonedx`). `promote` merge-patches the
Application `openshift-gitops/env-secured` (`kustomize.images` = the signed digest, `kustomize.replicas`
portal=1; its other kustomize patches are untouched), records the prompt and model version as
annotations, then waits until Argo CD reports Synced/Healthy on that digest. The pipeline SA may only
get/patch that one Application (`promote-rbac.yaml`). The Git overlay holds a placeholder digest with
the portal at 0 replicas, so nothing is pulled or admitted before the first promote.

* `pipeline.yaml`, `tasks.yaml`, `keyless-sign-task.yaml` — Pipeline, Tasks, keyless signer SA
  (kustomize namespace `parasol-build`, synced by Argo CD).
* `promote-rbac.yaml` — Role/RoleBinding in `openshift-gitops`: the `pipeline` SA may get/patch
  the Application `env-secured` only.
* `pipelinerun.yaml` — a release run (`candidate=v1`); with `candidate=v2` the gate blocks promote.
* `eval/` — `ec-policy.rego` (the `ec-policy` ConfigMap) and the earlier 3-case golden set.
* Operators (RHTAS, policy-controller, SPIRE) are in `gitops/bootstrap/operators/supply-chain.yaml`;
  their operands, the cosign keypair and the admission policy are set up by `scripts/supply-chain.sh`.
* `admission/` — the policy-controller webhook (`policycontroller.yaml`), the key-based
  `clusterimagepolicy.yaml`, and `demo-unsigned-deploy.yaml`. The live policy trusts both the
  keyless identity and the cluster key (`gitops/platform/tas/clusterimagepolicy-keyless.yaml`).

## Signing

Tekton Chains (OpenShift Pipelines 1.24.1, OCI simplesigning) signs the image the
`build-container` task produces, using the cosign keypair in `openshift-pipelines/signing-secrets`.
The keypair was generated in-cluster (never left the cluster) with:

```
cosign generate-key-pair k8s://openshift-pipelines/signing-secrets   # run as a Job, COSIGN_PASSWORD set
```

`cosign.pub` is mirrored to configmap `parasol-build/cosign-pub` (used by `verify-signature`) and
embedded in the ClusterImagePolicy. The `keyless-sign` task adds the keyless signature: the pod
(SA `keyless-signer`, SPIFFE ID `spiffe://parasol-demo/ns/parasol-build/sa/keyless-signer`) fetches
a JWT-SVID from SPIRE, exchanges it at Fulcio for a short-lived certificate, signs, and records the
signature in Rekor (Trusted Artifact Signer, `gitops/platform/tas`). Admission accepts either
authority; the keyed one stays because Fulcio certificates expire and no trusted timestamp is wired.

## Admission (parasol-secured)

`ClusterImagePolicy parasol-portal-must-be-signed` requires a valid cosign signature from the
cluster key for any `…/parasol-build/parasol-portal**` image. The webhook enforces on namespaces
labelled `policy.rhtas.com/include=true`. `no-match-policy` is set to `allow` on
`config-policy-controller` so the *other* (not-yet-signed) workloads in `parasol-secured` are
untouched — only an unsigned **portal** is refused:

```
oc label namespace parasol-secured policy.rhtas.com/include=true --overwrite
# unsigned portal  -> admission webhook "policy.rhtas.com" denied the request ... no signatures found
# Chains-signed    -> admitted
```

### Cluster steps outside the synced manifests
`scripts/supply-chain.sh` (run by `bootstrap.sh`, idempotent) does them: the cosign keypair in
`openshift-pipelines/signing-secrets` (Job, password generated in-cluster) + Chains restart, its copy
`parasol-build/cosign-signing-key` and ConfigMap `cosign-pub`, `no-match-policy=allow`, the
TrustRoot/ClusterImagePolicy rendered from this cluster's TUF root and cosign key
(`gitops/platform/tas/clusterimagepolicy-keyless.yaml` is the template), and the
`policy.rhtas.com/include=true` label on `parasol-secured`. `scripts/pipeline-runs.sh` starts the
release runs (v1 promotes; v2 is blocked by the gate); `bootstrap.sh` runs it and waits for v1.
