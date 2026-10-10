# Granite Guardian as a second detector (stream P1-GUARDIAN)

Additive. A second content detector **alongside** the wave-1 regex detector, served via the
**MaaS endpoint's guard tier** (`granite-guardian-3-1-8b`). It does **not** touch the production
`guardrails-proxy` or the enforced wave-1 guardrails path. Everything here lives in the isolated
namespace `parasol-guardian` and is applied manually (not wired into Argo), exactly like
`guardrails-nemo` (S4).

## What it is

`guardian-detector` is a tiny stdlib HTTP service that speaks the **same contract** as the
Guardrails Orchestrator's `POST /api/v2/text/detection/content` (`{content, detectors}` ->
`{detections:[...]}`), so the existing `guardrails-proxy` could point its `ORCHESTRATOR_URL` at it
with no code change. It runs two detectors per request:

| detector_id        | what it does                                                        |
|--------------------|---------------------------------------------------------------------|
| `regex`            | the owner's three wave-1 phrases (reproduced here, self-contained)  |
| `granite_guardian` | a call to the MaaS guard tier; the model's Yes/No verdict as a score|

Granite Guardian emits `Yes` (risky) / `No` (safe) as its first token; the score is `P(Yes)` read
from `top_logprobs` (falling back to the emitted token). `score >= GUARD_THRESHOLD` (0.5) = a
detection. The guard model runs **on the MaaS endpoint, not here** — no GPU, no pip, stdlib only.

## The gap (documented fallback — brief-sanctioned)

The real guard model is **unreachable with the credentials this lab has**:

* `granite-guardian-3-1-8b` exists on the lab LiteLLM endpoint, but **all five** lab virtual keys
  are allowlisted to `models=['llama-scout-17b']` only — they `401 key_model_access_denied` on the
  guard model. (Confirmed with P1-MAAS-TIERS.)
* There is **no LiteLLM master/admin access** to mint a key with broader model access.
* The cluster has **no GPU** to self-serve an 8B guard model on-cluster.

So the detector is **wired and ready** for the guard tier but the guard model is pending a
guard-capable MaaS key (or a GPU). This matches `docs/ui-demo-plan.md` §7 ("Granite Guardian as a
second detector — via the MaaS endpoint") and the "slides only / CPU detector stands in" note.

## Proving the mechanism end-to-end (stand-in)

To show the two-detector mechanism working now, the deployment is overridden to point at
`llama-scout-17b` with a guardian-style classifier prompt (`GUARD_PROMPT`) — **a clearly-labeled
stand-in, not real Granite Guardian** (the guardian meta says so). The code path, contract, score
extraction and "second detector alongside regex" wiring are identical to the real guard tier.

```
oc apply -k gitops/platform/guardrails-guardian          # ns, detector, service
CREDENTIALS_FILE=.../credentials.txt scripts/guardian-key.sh   # Secret maas-guardian (key2, out-of-band)
# stand-in override (demo only):
oc set env deploy/guardian-detector -n parasol-guardian GUARD_MODEL=llama-scout-17b GUARD_PROMPT='<classifier>'
oc apply -f gitops/platform/guardrails-guardian/prove-job.yaml
oc logs job/guardian-prove -n parasol-guardian
```

Observed:

```
[INJECTION/UNSAFE] guardian: {model: llama-scout-17b, score: 0.8176, verdict: risky, mode: STAND-IN}
[INJECTION/UNSAFE] DETECTED by regex: automated-processing-note score=1.0
[INJECTION/UNSAFE] DETECTED by regex: assistant-action-required score=1.0
[INJECTION/UNSAFE] DETECTED by granite_guardian: harm score=0.8176
[CLEAN]            guardian: {score: 0.0601, verdict: safe}   -> no detections
```

## Switching to the real guard model (one step, when a key exists)

1. `GUARD_KEY_FIELD=<guard-capable key field> scripts/guardian-key.sh`
2. `oc set env deploy/guardian-detector -n parasol-guardian GUARD_MODEL=granite-guardian-3-1-8b GUARD_PROMPT-`
   (unset `GUARD_PROMPT` — the real guard model's served template does the guardian formatting).

No other change. The committed `deployment.yaml` already defaults to `granite-guardian-3-1-8b` with
no prompt, i.e. the production-intended wiring; the stand-in is a runtime override only.
