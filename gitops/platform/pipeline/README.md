# Secure supply-chain pipeline (layer 6: the lifecycle gate)

A Tekton pipeline in namespace `parasol-build` that **builds the Parasol portal from source**,
**scans** it, attaches a signed **SBOM**, runs the **agent evaluation gate**, **signs** it keyless
(Trusted Artifact Signer) and with the cluster key, checks the **Conforma** contract, and
**promotes** the signed digest by committing the pin into `gitops/envs/secured/kustomization.yaml`;
Argo CD rolls the secured portal to it and admission verifies the signature. Task names and order
mirror the Red Hat `tssc-sample-pipelines` reference; ACS/Quay/GitLab are not on this cluster, so
the scan is Trivy, the registry is the internal OpenShift registry and the SCM is GitHub.

The Tasks and the Pipeline are desired state, synced by the Argo CD Application
`platform-pipeline` (`gitops/bootstrap/apps/platform-pipeline.yaml`). PipelineRuns are events and
are created by hand from `pipelinerun.yaml`, which is not part of the synced kustomization.

```
init → clone-repository → build-container ─┬→ scan-image (Trivy) ──────────────────────────┐
                                           ├→ generate-sbom (syft CycloneDX, cosign attest)  │
                                           ├→ agent-eval (gate) → register-model-version    ├→ promote
                                           ├→ sign-images (cluster key) ─┐                  │  (commit pin)
                                           └→ keyless-sign (TAS) ────────┴→ verify-enterprise-contract
finally: show-sbom, show-summary
```

`agent-eval` runs the MLflow evaluation of the claims assistant (agent model qwen3-14b, judge
gpt-oss-120b on its own key in secret `maas-eval-key`); below 19/20 the gate is `failed` and
`promote` is skipped. `verify-enterprise-contract` is the Conforma gate: the image must carry a valid
signature AND a signed SLSA provenance attestation (Tekton Chains). The SBOM ships as a signed
cosign attestation (`cosign verify-attestation --type cyclonedx`). `promote` needs a GitHub token in
secret `gitops-auth-secret` (key `token`, contents:write on this repository; never in Git); without
it the run prints the pin diff and pushes nothing.

* `pipeline.yaml`, `tasks.yaml`, `keyless-sign-task.yaml` — Pipeline, Tasks, keyless signer SA
  (kustomize namespace `parasol-build`, synced by Argo CD).
* `pipelinerun.yaml` — a release run (`candidate=v1`); with `candidate=v2` the gate blocks promote.
* `eval/` — `ec-policy.rego` (the `ec-policy` ConfigMap) and the earlier 3-case golden set.
* `operators/subscriptions.yaml` — RHTAS (Trusted Artifact Signer) + Sigstore policy-controller.
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

### Manual cluster steps not in git-synced manifests
* generate the cosign keypair into `signing-secrets` (Job above) and restart `tekton-chains-controller`;
* `oc patch cm config-policy-controller -n policy-controller-operator --type merge -p '{"data":{"no-match-policy":"allow"}}'`;
* the webhook's service-CA trust (`SSL_CERT_FILE` + `config-service-cabundle` mount) is carried in
  `policycontroller.yaml` so it survives operator reconciles.
