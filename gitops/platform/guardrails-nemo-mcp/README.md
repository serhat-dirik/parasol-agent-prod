# V1 — guardrails at the MCP gateway, the product way

Wave 2 / V1. Wires a NeMo topic rail the **product way** using the TrustyAI
operator's `NemoGuardrails` CR, and documents the `mcpGuardrailsMode` gateway
overlay. **Additive, isolated namespace `parasol-v1-guardrails`, NOT in Argo.**
The enforced wave-1 path (`guardrails-proxy` in `parasol-secured`) is untouched
and stays the demo's guardrails path until V1 is accepted.

## What V1 is (two halves)

The owner's backlog phrased V1 as "`mcpGuardrailsMode` + a NemoGuardrail CR
(Connectivity Link / MCP gateway native guardrails)". On the installed cluster
these are **TrustyAI/RHOAI** CRDs, not Kuadrant MCP-gateway fields:

- `nemoguardrails.trustyai.opendatahub.io` — a NeMo Guardrails server managed by
  the trustyai-service-operator (service `NEMO_GUARDRAILS`, RH image
  `odh-trustyai-nemo-guardrails-server-rhel9`).
- `mcpGuardrailsMode` — a boolean on `spec.components.trustyai` of the
  **shared `default-dsc`** ("enables the mcp-guardrails overlay"). The Kuadrant
  MCP-gateway CRDs (`mcpgatewayextensions`, `mcpserverregistrations`,
  `mcpvirtualservers`) carry **no** guardrails fields at all.

### Half 1 — NemoGuardrails CR (DONE, proven here, additive)

Operator-managed NeMo rail (vs S4's hand-rolled `python:3.11` + pip Deployment):

- `nemo-config.yaml` — ConfigMap `parasol`: `config.yaml` (self-check-input topic
  rail, `api_key_env_var: OPENAI_API_KEY`) + `rails.co` (required by the product
  entrypoint; the mount is read-only so the file must be provided).
- `nemoguardrail.yaml` — `NemoGuardrails/parasol-rail`. The RH product server is
  **env-driven** (`server/api.py::_inject_model`): main model = request `model`
  field, `MAIN_MODEL_ENGINE=openai`, `MAIN_MODEL_BASE_URL` + `OPENAI_API_KEY`
  from the out-of-band `maas-nemo` secret (MaaS **key 2**, copied from S4's ns,
  never in Git).
- `prove-job.yaml` — reproducible proof via the ClusterIP Service.

Proof:

```
oc apply -f nemo-config.yaml -f nemoguardrail.yaml        # operator builds Deployment+Service
oc -n parasol-v1-guardrails get nemoguardrails,deploy,svc # parasol-rail 1/1
oc delete job v1-rail-prove -n parasol-v1-guardrails --ignore-not-found
oc apply -f prove-job.yaml
oc logs -n parasol-v1-guardrails job/v1-rail-prove
# ON-TOPIC (claim CLM-1004)  -> PASSES, assistant answers
# OFF-TOPIC (joke + weather) -> BLOCKED: "I'm sorry, I can't respond to that."
# both responses carry "guardrails":{"config_id":"parasol"}
```

### Half 2 — mcpGuardrailsMode overlay (OWNER-GATED, where the product path stops)

`dsc-mcpguardrailsmode-OWNER-GATED.yaml` is the gateway-native wiring and is
**intentionally not applied** (and excluded from the kustomization). It flips a
cluster-shared, operator-reconciled flag on `default-dsc` that would
re-reconcile the existing `parasol-secured/guardrails` GuardrailsOrchestrator
(wave-1 namespace, already `phase=Error` on an unrelated ServiceMonitor RBAC
issue). That is outside V1's own-namespace/additive rule and is the same class
of shared-TrustyAI change the coordinator held for owner approval in P1-EVALHUB.
Enabling it needs an owner-approved maintenance window and a re-verify of Demo 1
beat 3 + Demo 2 beat 2 + `guardrails-proxy`. See the file header for the exact
steps.

## Substitute (unchanged)

Until the owner enables the overlay, the enforced guardrails path stays the
wave-1 `guardrails-proxy` + S4's NeMo server. V1 adds the product-managed NeMo
rail runtime and the exact, owner-gated gateway-wiring step.
