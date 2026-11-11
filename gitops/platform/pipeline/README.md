# Secure supply-chain pipeline (layer 6: the lifecycle gate)

A Tekton pipeline in namespace `parasol-build` that **builds the Parasol portal from source**,
**scans** it, generates an **SBOM**, runs the **agent evaluation gate**, checks the **Conforma** contract, and
**promotes** the signed digest by pinning it on the Argo CD Application `env-secured`
(`spec.source.kustomize.images`; no Git write, the repo is read-only for releases); Argo CD rolls the
secured portal to it and admission verifies the signature. Signing is not a pipeline step: Tekton Chains, a
controller outside the pipeline, signs the image `build-container` produced and its SLSA provenance, keyless through
Trusted Artifact Signer (SLSA Build L3: the build platform signs, not the build; no step holds a signing key). Task names and order
mirror the Red Hat `tssc-sample-pipelines` reference; `git-clone` and `buildah` are the Tasks OpenShift Pipelines
ships (cluster resolver, namespace `openshift-pipelines`). ACS/Quay/GitLab are not on this cluster, so
the scan is Trivy, the registry is the internal OpenShift registry and the SCM is GitHub.

The Tasks and the Pipeline are desired state, synced by the Argo CD Application
`platform-pipeline` (`gitops/bootstrap/apps/platform-pipeline.yaml`). PipelineRuns are events and
are created by hand from `pipelinerun.yaml`, which is not part of the synced kustomization.

```
init → clone-repository → build-container ─┬→ scan-image (Trivy) ─────────────────────────────────────────┐
                                           ├→ agent-eval (gate) → register-agent-version                   ├→ promote
                                           ├→ generate-sbom (syft, sha256 as a result)                     │  (pin on Argo app)
                                           └→ verify-conforma (Conforma) ──────────────────────────────────┘
finally: show-sbom, show-summary
Tekton Chains (outside the pipeline): signs the build-container image and its SLSA provenance, keyless.
```

`agent-eval` first registers the prompt the release ships (`prompt-file` in the cloned repo, e.g.
`gitops/envs/secured/system-prompt.txt`, becomes the registry version the `prompt-ref` alias points to; an
identical text reuses its version; the registry is append-only), then runs the MLflow evaluation of the claims
assistant with that prompt, generating every golden-set answer live (agent model qwen3-14b through OpenShift AI MaaS
on the eval's own subscription `parasol-eval`, key in secret `maas-eval-agent-key`; stub tools from `fixtures.json`, so
no live data is read and nothing is written; 3 attempts per case, majority). Each case runs with the platform (the
secured model path through the guardrails proxy, the persona's gateway tool list, the claims-db record rule, the
MCP gateway's NeMo check on claims-db results, the portal's correction note: what the gate scores) and model alone (for comparison; a case only the platform saves names
the control on the run as `platform_control`). The gate also fails when the model alone loses a case of the last released production: a shared case its
model alone passed on every attempt and now passes on none (a count misses a prompt that trades cases). `promote` writes
the released run's model-alone count as annotation `parasol.example/model-only-baseline` (+ `-run`) on `env-secured`, next to the pinned
digest, and mirrors it as tag `released=true` on the MLflow run; a missing or disagreeing record fails the gate
closed; before any promote the seed's production run is the bar. A prompt that got weaker fails even when the
platform still masks it. The comparison uses only the cases both golden-set versions share (same id and fingerprint); the judge is
`JUDGE_MODEL` (default gpt-oss-120b) on its own key in secret `maas-eval-key` (data keys endpoint, key, model). Below the 0.95 pass-rate gate the gate is `failed` and `promote` is skipped. `verify-conforma` is the Conforma gate (`ec validate image`, policy `eval/ec-policy.rego`): the image
signature and the SLSA provenance verify against Tekton Chains' keyless identity (Fulcio certificate, Rekor entries),
the provenance states that the expected pipeline task built the image (`build-container` of
`parasol-portal-secure-build` for the portal, `build-onboarded-image` of `parasol-tool-onboarding` for vendor tools),
and the image is pinned by digest; a violation fails the task and promote is skipped. The SBOM's sha256 is a
`generate-sbom` result (`SBOM_SHA256`), so it is part of the PipelineRun provenance Chains signs. `promote` pins the released prompt
(ConfigMap `parasol-secured/agent-prompt-release`: the registered text the gate evaluated and its registry
version; the portal reads only this, so a Git edit of the prompt waits for a release; admission policy
`parasol-released-prompt-writer` refuses any other writer, cluster admins included, and alert
`ParasolReleasedPromptChangeRefused` fires on a refusal), then merge-patches the
Application `openshift-gitops/env-secured` (`kustomize.images` = the signed digest, `kustomize.replicas`
portal=1; its other kustomize patches are untouched), records the prompt and model version as
annotations, then waits until Argo CD reports Synced/Healthy on that digest. The pipeline SA may only
get/patch that one Application (`promote-rbac.yaml`). The Git overlay holds a placeholder digest with
the portal at 0 replicas, so nothing is pulled or admitted before the first promote.

* `pipeline.yaml`, `tasks.yaml` — Pipeline and Tasks (kustomize namespace `parasol-build`, synced by Argo CD).
* `promote-rbac.yaml` — Role/RoleBinding in `openshift-gitops`: the `pipeline` SA may get/patch
  the Application `env-secured` only.
* `pipelinerun.yaml` — a release run (`candidate=production`); with `candidate=candidate-shortened` (prompt
  alias `candidate`) the gate blocks promote.
* `eval/` — `ec-policy.rego` (the `ec-policy` ConfigMap).
* Operators (RHTAS, policy-controller, SPIRE) are in `gitops/bootstrap/operators/supply-chain.yaml`;
  their operands, Chains' keyless configuration and the admission policy are set up by `scripts/supply-chain.sh`.
* `admission/` — the policy-controller webhook (`policycontroller.yaml`), the key-based
  `clusterimagepolicy.yaml`, and `demo-unsigned-deploy.yaml`. The live policies trust only Tekton Chains' keyless
  identity with its Rekor entry (`gitops/platform/tas/clusterimagepolicy-keyless.yaml`).
* `onboarding/` — Showcase 7's vendor-image onboarding pipeline; after its checks pass it builds Parasol's image
  `FROM` the vendor digest (with the check report and labels), which Chains signs like any build.

## Signing

One signer: Tekton Chains (OpenShift Pipelines 1.24, OCI simplesigning, in-toto SLSA provenance), keyless through
Trusted Artifact Signer (`gitops/platform/tas`). When a TaskRun reports `IMAGE_URL`/`IMAGE_DIGEST`, the Chains controller
fetches a JWT-SVID from SPIRE (audience `sigstore`) as
`spiffe://parasol-demo/ns/openshift-pipelines/sa/tekton-chains-controller` (static entry `chains-spiffe-entry.yaml`:
SPIRE skips `openshift-*` namespaces otherwise), exchanges it at Fulcio for a 10-minute certificate, signs the image and
the provenance with a throwaway key, stores both next to the image and records both in Rekor. TektonConfig
`spec.chain` holds the Fulcio, Rekor and TUF addresses and the SPIFFE socket mount; `scripts/supply-chain.sh` sets
them. Chains ignores `openshift-pipelines/signing-secrets` once Fulcio is enabled. Verifiers (Conforma, the policy
controller, `cosign verify`) need only public material: the TUF trust root and the expected identity; Rekor's entry
time proves the signature was made while the certificate was valid.

## Admission (parasol-secured)

`ClusterImagePolicy parasol-portal-must-be-signed` requires Tekton Chains' keyless signature (Fulcio certificate for
its SPIFFE identity, Rekor entry) for any `…/parasol-build/parasol-portal**` image; `parasol-vendor-tools-must-be-onboarded`
requires the same for `…/currency-converter**`. The webhook enforces on namespaces
labelled `policy.rhtas.com/include=true`. `no-match-policy` is set to `allow` on
`config-policy-controller` so the *other* (not-yet-signed) workloads in `parasol-secured` are
untouched — only an unsigned **portal** is refused:

```
oc label namespace parasol-secured policy.rhtas.com/include=true --overwrite
# unsigned portal  -> admission webhook "policy.rhtas.com" denied the request ... no signatures found
# Chains-signed    -> admitted
```

### Cluster steps outside the synced manifests
`scripts/supply-chain.sh` (run by `bootstrap.sh`, idempotent) does them: Securesign (Fulcio trusts SPIRE, client ID
`sigstore`), the static SPIRE entry for Chains, Chains' keyless settings in TektonConfig, ConfigMap
`parasol-build/tas-trust` (TAS addresses and the signer identity for `verify-conforma`), `no-match-policy=allow`, the
TrustRoot/ClusterImagePolicies rendered from this cluster's TUF root, Fulcio, Rekor and OIDC issuer
(`gitops/platform/tas/clusterimagepolicy-keyless.yaml` is the template), and the
`policy.rhtas.com/include=true` label on `parasol-secured`. `scripts/pipeline-runs.sh` starts the
release runs (`parasol-portal-release-production` promotes; `parasol-portal-release-candidate-shortened` is
blocked by the gate); `bootstrap.sh` runs it and waits for the production run.
