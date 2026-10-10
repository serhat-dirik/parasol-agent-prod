# NeMo Guardrails topic rail (Technology Preview, additive)

Additive dialog/topic rail built with NVIDIA NeMo Guardrails, explored as a
second guardrail surface at the gateway. It is **independent of and does not
replace** the production `guardrails-proxy` in `parasol-secured`, which remains
the demo's enforced guardrails path.

## What it is

- Isolated namespace `parasol-guardrails-nemo` (nothing else touched).
- A NeMo config (`configmap.yaml`) with an **input rail** (`self check input`)
  that calls the lab MaaS model `llama-scout-17b` to classify whether a message
  is on-topic for the Parasol claims assistant; off-topic / role-change messages
  are blocked before they reach the model.
- `job.yaml` runs NeMo (pip-installed `nemoguardrails`) against two cases to
  demonstrate the rail: an on-topic claim question (allowed) and an off-topic
  message (blocked, rail fires).

## Secret (not in Git)

Created out-of-band at run time (MaaS key 2, never committed):

    oc create secret generic maas-nemo -n parasol-guardrails-nemo \
      --from-literal=OPENAI_API_KEY=<litellm_user2_virtual_key> \
      --from-literal=OPENAI_API_BASE=https://maas-rhdp.apps.maas.redhatworkshops.io/v1

## Run

    oc apply -f namespace.yaml -f configmap.yaml
    # create the secret above
    oc apply -f job.yaml
    oc logs -n parasol-guardrails-nemo job/nemo-rail-demo

## Production note

In production the rail runs as a `nemoguardrails server` sidecar/service in front
of the MCP gateway (prebuilt image, no pip-at-start), chained *after* the
guardrails-proxy. This TP only demonstrates the rail firing.
