# NeMo Guardrails topic rail (additive)

Additive dialog/topic rail built with NVIDIA NeMo Guardrails, standing beside the
gateway as a second guardrail surface. It is **independent of and does not
replace** the production `guardrails-proxy` in `parasol-secured`, which remains
the demo's enforced guardrails path. NeMo is NOT in the enforced request path.

## What it is

- Isolated namespace `parasol-guardrails-nemo` (nothing else touched).
- A NeMo config (`configmap.yaml`) with an **input rail** (`self check input`)
  that calls the lab MaaS model `llama-scout-17b` to classify whether a message
  is on-topic for the Parasol claims assistant; off-topic / role-change messages
  are blocked before they reach the model.
- `deployment.yaml` runs a long-running `nemoguardrails server` (Deployment +
  Service `nemo-guardrails:8000`, OpenAI-compatible endpoint, config id
  `parasol`). This is the productionized form.
- `job.yaml` is the one-off variant (same config) that runs the two cases and
  exits, kept as a quick self-test.

## Secret (not in Git)

Created out-of-band at run time (MaaS key 2, never committed):

    oc create secret generic maas-nemo -n parasol-guardrails-nemo \
      --from-literal=OPENAI_API_KEY=<litellm_user2_virtual_key> \
      --from-literal=OPENAI_API_BASE=https://maas-rhdp.apps.maas.redhatworkshops.io/v1

## Run

    oc apply -f namespace.yaml -f configmap.yaml
    # create the secret above
    oc apply -f deployment.yaml          # long-running server + Service
    # or the one-off self-test:
    oc apply -f job.yaml
    oc logs -n parasol-guardrails-nemo job/nemo-rail-demo

## Prove the rail through the running server

OpenAI-compatible call to the Service (config id `parasol`); off-topic is
blocked, on-topic passes:

    POST http://nemo-guardrails.parasol-guardrails-nemo.svc:8000/v1/chat/completions
    {"config_id":"parasol","messages":[{"role":"user","content":"<message>"}]}

## Production note

The rail runs as a `nemoguardrails server` Service beside the MCP gateway. For a
real deployment, bake a prebuilt image (no pip-at-start) and chain it *after* the
guardrails-proxy. It is additive and never in the enforced wave-1 request path.
