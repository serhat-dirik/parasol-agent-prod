# Granite Guardian as a second detector (stream P1-GUARDIAN)

Additive. A second (and optional third) model-based content detector **alongside** the wave-1 regex
detector, served via the **MaaS endpoint's guard tier**. It does **not** touch the production
`guardrails-proxy` or the enforced wave-1 guardrails path. Everything lives in the isolated namespace
`parasol-guardian` and is applied manually (not wired into Argo), exactly like `guardrails-nemo` (S4).

## What it is

`guardian-detector` is a tiny stdlib HTTP service that speaks the **same contract** as the Guardrails
Orchestrator's `POST /api/v2/text/detection/content` (`{content, detectors}` -> `{detections:[...]}`),
so the existing `guardrails-proxy` could point its `ORCHESTRATOR_URL` at it with no code change. Per
request it runs the detectors named in the `detectors` field:

| detector_id        | model / rule                        | used on                         |
|--------------------|-------------------------------------|---------------------------------|
| `regex`            | the owner's three wave-1 phrases    | any text (document + user msg)  |
| `granite_guardian` | `granite-guardian-3-1-8b` (MaaS)    | any text                        |
| `llama_guard`      | `Llama-Guard-3-1B` (MaaS), optional | the **user message** only       |

### Scoring (why the verdict token, not a logprob threshold)

Each guard model emits a verdict token — Granite Guardian `Yes`/`No`, Llama Guard `safe`/`unsafe`.
The **decision is the emitted verdict token** (authoritative). The **score** is `P(risky)` read from
`top_logprobs` **at the position the verdict token is emitted** — Granite emits it first; Llama emits
a `\n\n` token first, so position-0 logprobs are noise. Two traps handled: (1) case/space variants
(`Yes`/`yes`/`YES`) are collapsed keeping the **best** logprob, else a decisive `Yes` reads as ~0;
(2) a clean `No` with tied logprobs still decides *safe* (no false positive). No fixed threshold gates
the detection — the model's label does.

## Proof (real models, reproducible)

```
oc logs job/guardian-prove -n parasol-guardian
```

```
[USER-INJECTION] granite_guardian risky score=0.9979 ; llama_guard risky score=0.9627
                 -> DETECTED by granite_guardian (harm) AND llama_guard (unsafe)
[DOCUMENT-NOTE]  regex HIT x2 (score 1.0) ; granite_guardian risky score=0.9794
                 -> DETECTED by regex AND granite_guardian (harm)
[CLEAN]          granite_guardian safe ; llama_guard safe  -> no detections
```

So the REAL Granite Guardian scores the injection risky and the clean query safe, **alongside** the
regex detector, and Llama Guard flags the user-message injection as the optional third detector.

## MaaS guard tier + GenAI Studio playground

* `granite-guardian-3-1-8b` and `Llama-Guard-3-1B` are registered MaaS models (ExternalModel +
  **MaaSModelRef `Ready`**, created by stream P1-MAAS-TIERS). A `Ready` MaaSModelRef is what the
  OpenShift AI **GenAI Studio playground** enumerates in its model picker, so Granite Guardian is
  selectable there (a cluster-admin sees all MaaS models; the auth-walled dashboard screen is captured
  in the operator's logged-in browser at record time, per the handover decision).
* The guard-tier keys are out-of-band Secrets (`maas-key-granite-guardian`, `maas-key-llama-guard`,
  data key `GENAI_API_KEY`), **never in Git**. `scripts/guardian-key.sh` creates the base-URL Secret
  `maas-guardian`; `load-credentials.sh` also exports `MAAS_KEY_GUARD` / `MAAS_KEY_LLAMAGUARD`.

## History (fallback that is no longer needed)

Before the per-model guard keys existed, all five lab virtual keys were `llama-scout-17b`-only, so the
guard model was unreachable and the mechanism was proven with a clearly-labelled llama-scout STAND-IN
(`GUARD_PROMPT` turned a general model into a Yes/No classifier). The real keys are now minted, the
stand-in override is removed, and the committed manifests use the real guard models.
