# Secure supply-chain pipeline (layer 6: the lifecycle gate)

A Tekton pipeline in namespace `parasol-build` that builds the Parasol portal image, has
Tekton Chains **sign** it, **scans** it, runs a **lifecycle evaluation gate**, verifies the
**signature**, and **promotes** the signed digest into the secured (prod) overlay. Task names and
order mirror the Red Hat `tssc-sample-pipelines` reference so the console PipelineRun reads the
same; ACS/Quay/GitLab are not on this cluster, so the scan is Trivy, the registry is the internal
OpenShift registry, the SCM is GitHub `serhat-dirik/parasol-agent-prod`, and promotion is a commit
to the prod overlay in this repo.

```
init → clone-repository → build-container → scan-image → agent-eval ┐
                                          → verify-signature ────────┼→ promote
                                                                      ┘
finally: show-sbom, show-summary
```

* `pipeline.yaml`, `tasks.yaml` — the Pipeline and Tasks (kustomize: `parasol-build`).
* `pipelinerun.yaml` — launch a run: `oc create -n parasol-build -f pipelinerun.yaml`.
* `build/Containerfile` — provenance build context (re-wraps the published portal image so each
  promotion gets a fresh, signable digest fast; point `build-container` CONTEXT at
  `apps/parasol-portal/app` to build the portal from source instead).
* `eval/` — the lifecycle gate: `golden-set.json` (3 safety cases), `candidate-v{1,2}.json`,
  `score.py` (gates `promote` at the threshold; v2 passes, a v1-style regression is blocked).
* `operators/subscriptions.yaml` — RHTAS (Trusted Artifact Signer) + Sigstore policy-controller.
* `admission/` — the policy-controller webhook (`policycontroller.yaml`), the key-based
  `clusterimagepolicy.yaml`, and `demo-unsigned-deploy.yaml`.

## Signing

Tekton Chains (OpenShift Pipelines 1.24.1, OCI simplesigning) signs the image the
`build-container` task produces, using the cosign keypair in `openshift-pipelines/signing-secrets`.
The keypair was generated in-cluster (never left the cluster) with:

```
cosign generate-key-pair k8s://openshift-pipelines/signing-secrets   # run as a Job, COSIGN_PASSWORD set
```

`cosign.pub` is mirrored to configmap `parasol-build/cosign-pub` (used by `verify-signature`) and
embedded in the ClusterImagePolicy. Rekor/transparency is off (keypair mode). The RHTAS operator is
installed so keyless-with-Fulcio/Rekor is the production story on the slide; the working backend
here is the cluster keypair (the owner's documented fallback #1).

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
