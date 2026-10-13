# AI Agents: From localhost to Production

Anyone can stand up an AI agent on a laptop in an afternoon. Running that same agent in
production — where real people use it, feed it real documents, and will try to abuse it — is
where the hard, rarely-discussed problems live. This repository is a working demonstration of
that gap, and of how an OpenShift-based platform closes it.

Everything is declared in Git and synced by Argo CD. The sections below are collapsed; open the
one you need.

<details open>
<summary><b>Overview</b> — what the demo is</summary>

The application is the **Parasol Insurance claims portal**: a web app (Quarkus + React/PatternFly,
Keycloak login) whose chat assistant is a tool-using agent — it calls MCP tools to read claims and
policy documents and to approve payouts. The *same* portal image runs twice on one cluster:

* **`portal-free`** (the **unsecured** portal) — the laptop setup, lifted into a namespace. Nothing
  sits between the agent and its tools, and nothing between the agent and the model but an API key in
  a Secret.
* **`portal` (secured)** — the same image behind a layered sandbox: namespace isolation, Keycloak
  identity carried to every tool call, per-identity tool authorization at an MCP gateway, content
  guardrails, model-as-a-service governance with per-tier token budgets, OpenTelemetry tracing and
  token metrics, a GitOps kill switch on the Argo CD Application, and a signed-image supply chain with admission control.

Six scenarios — things a real user might do — are run against both portals, and every step is
something you watch happen in a browser:

* **Scenario 1 — a colleague.** Rebecca, a claims adjuster, asks the assistant to approve a payout
  she has no authority to approve. *Unsecured:* it approves. *Secured:* the tool is filtered out of her
  list and a forced call is refused by the MCP gateway; the assistant can only *propose*, and only a
  claims manager's click actually writes.
* **Scenario 2 — a customer's document.** A repair estimate uploaded to a denied claim is inflated
  to AED 84,000 and carries a hidden "processing note" addressed to the assistant. Both portals run the
  **same injection-obeying model (`qwen3-14b`)**, so the only variable is the platform. *Unsecured:* the
  model obeys the hidden note and pays 84,000 on a denied claim. *Secured:* the model still obeys — it
  tries to pay — but `approve_payout` is not in its tool list, so it can only *propose*; guardrails flag the
  hidden instruction and the Read-Propose-Act gate surfaces the 10× gap — no write happens. The controls,
  not model luck, stop the payout.
* **Scenario 3 — the confidential document.** The assistant searches Parasol's knowledge base, where some
  documents are for everyone, some for staff and some (HR) for claims managers only. An adjuster asks about
  plans for adjuster roles. *Unsecured:* the restricted restructuring plan is retrieved and shared.
  *Secured:* retrieval runs as the user (her token's groups, then PostgreSQL row-level security), so the
  restricted documents never reach the model; "I'm a claims manager" in the chat changes nothing. The same holds
  for claim records: secured, claims-db answers an adjuster only for the claims assigned to her (claims managers:
  all), decided from the verified on-behalf-of token; unsecured, rebecca reads a colleague's claim (CLM-1029).
* **Scenario 4 — the night shift.** An outsourced night-shift contractor's account (or its leaked token)
  is scripted at 3 a.m. to loop long requests and drain the token budget. *Unsecured:* the shared key burns all night. *Secured:* the topic guardrail
  refuses the junk at no cost, a per-user budget returns HTTP 429 for that account while staff keep
  working, an alert fires naming the user, and the operator can disable the account or flip the kill
  switch — the pods keep running, the agent can reach nothing.
* **Scenario 5 — the evaluation gate.** A developer shortens the system prompt. The release pipeline
  evaluates it against the golden set; below the 0.95 gate the promotion is skipped. The production prompt
  that does run is the released one, to the byte: the release registers the prompt from Git, gates it and
  pins exactly that text next to the image digest; a Git edit alone changes nothing at run time, and every
  chat trace carries the sha256 of the text it ran.
* **Scenario 6 — the poisoned tool.** A third-party currency tool is plugged into the assistant; later its
  description changes, same version, and asks for payouts. *Unsecured:* the assistant pays. *Secured:* the
  gateway federates only reviewed registrations and the tool scanner flags and pins every description.

Then **the incident** (Showroom page 09): one payout reconstructed from the platform's own records, from the
claim timeline through the MLflow trace, Keycloak's token exchange, the gateway, the release on Argo CD and
the Model Registry to the signed digest (`scripts/incident-report.sh <claim>`). And on the supply-chain page,
**only approved models**: a secured workload cannot reach a public model API (egress only to the platform's
gateways, drops logged by OVN), provider keys live only in MaaS, and MaaS routes only registered models. For
Scenario 2, an optional section shows that nothing leaves through the answer either: no tool reaches an
arbitrary destination, egress is closed, and the guardrails proxy removes off-list links and images.

In `portal-free` all but the evaluation gate cause harm. In `portal` a different layer stops each, and the platform
consoles (Keycloak, the OpenShift AI dashboard, the OpenShift console, Argo CD) show *why*. The
scripts in this repo are only for setting the demo up, playing the abusive customer, and resetting
between runs — the demo itself is the browser.

</details>

<details>
<summary><b>What's here</b> — repository layout</summary>

| Path | What |
|---|---|
| `apps/parasol-portal` | The Parasol claims portal (Quarkus + React/PatternFly, Keycloak login); its chat assistant is the tool-using agent — tool-call chips, Documents tab, Read-Propose-Act approval, guardrail banners, per-tier model keys, a dashboard |
| `apps/parasol-agent` | The same agent as a headless REST service, used by the test and load scripts (not what the audience sees) |
| `apps/mcp-servers/claims-db` | MCP server over the claims dataset (CLM-1001…1030) with the `approve_payout` write tool, `get_claim_documents` (the seeded customer document on CLM-1004), and a small REST API the portal reads |
| `apps/mcp-servers/policy-docs` | MCP server over the Parasol policy documents |
| `gitops/bootstrap` | Operator subscriptions and the Argo CD app-of-apps |
| `gitops/platform` | Keycloak realm, MCP gateway + AuthPolicies, OpenShift AI MaaS governance, Guardrails Orchestrator, observability (OTel → Tempo and MLflow), and the secure build pipeline with image signing and admission control |
| `gitops/envs/free`, `gitops/envs/secured`, `gitops/envs/secured-storm` | The two environments and the "v3" storm variant |
| `scripts/` | bootstrap helpers, the test/load harness, and the reset — see **Demo scripts** |

</details>

<details>
<summary><b>Quick install</b></summary>

Prerequisites: a fresh OpenShift 4.22 cluster (3 workers, 16 vCPU / 64 GB recommended, no GPU; OpenShift
AI not needed), `oc` logged in as cluster-admin (token login), `kustomize`, `envsubst`, `openssl`, `curl`,
`jq` and `python3` with PyYAML. Every prerequisite (OpenShift GitOps, each operator, a Keycloak instance,
the OpenShift AI DataScienceCluster) is detected first and installed only if missing.

The demo calls three models over OpenAI-compatible APIs. Each one can come from a **different
provider**, so each has its own endpoint (a base URL ending in `/v1`) and its own key:

| Role | Model | Endpoint | Key | Must support |
|---|---|---|---|---|
| Agent, both portals | `qwen3-14b` (set another with `AGENT_MODEL`) | `AGENT_ENDPOINT` | `AGENT_KEY` | structured tool calls, and obeying an instruction hidden in a document (that is what makes Scenario 2 live) |
| Guard detector | `granite-guardian-3-1-8b` | `GUARD_ENDPOINT` | `GUARD_KEY` | chat completions with `logprobs` (the risk score is read from them) |
| Evaluation judge | `gpt-oss-120b` | `JUDGE_ENDPOINT` | `JUDGE_KEY` | strong instruction following (Scenario 5) |
| Third detector (optional) | `Llama-Guard-3-1B` | `LLAMAGUARD_ENDPOINT` | `LLAMAGUARD_KEY` | chat completions with `logprobs` |

```bash
export AGENT_ENDPOINT=https://<agent-provider>/v1   AGENT_KEY=<key>
export GUARD_ENDPOINT=https://<guard-provider>/v1   GUARD_KEY=<key>
export JUDGE_ENDPOINT=https://<judge-provider>/v1   JUDGE_KEY=<key>
# optional
export LLAMAGUARD_ENDPOINT=https://<provider>/v1    LLAMAGUARD_KEY=<key>
./bootstrap.sh
```

If all models sit behind one endpoint, set the same URL for each. `bootstrap.sh` checks the three
required pairs before it touches the cluster and names any that are missing.

`bootstrap.sh` is idempotent (re-run it after any failure; every WARN names the command to re-run). It
installs what is missing, creates the secrets (none ever in Git), builds the images in-cluster, applies the
Argo CD app-of-apps, sets up the supply chain (SPIRE, Trusted Artifact Signer, cosign key, admission) and
seeds the demo data (MLflow golden-set runs, answers generated live: the production prompt passing the gate, 22 of 23
with the platform controls on, and the shortened candidate prompt blocked below the 0.95 gate, prompt and model registry versions, the EvalHub run, the GenAI Studio playground), then runs
the first release: the production prompt is signed, passes the gate and is promoted (pinned on the Argo CD
Application `env-secured`; nothing is written to Git), the candidate (shortened prompt) is blocked by the
gate. No manual step. On a bare cluster it takes **75 to 120 minutes**. Argo CD only reads
the repo (`REPO_URL`, any remote it can reach).

Verify the install with `scripts/status.sh` (all Argo apps Synced/Healthy, both portals up), or Argo CD
directly. Then open the portals in a browser — **this is the demo**:

* uncontrolled: `https://portal-free.apps.<cluster-domain>`
* secured: `https://portal.apps.<cluster-domain>`

**Demo users** — Keycloak realm `parasol` (passwords equal the usernames; they exist only for this demo):

* `rebecca` — claims adjuster (read-only tools; can propose but not approve)
* `marcus` — claims manager (may approve payouts)
* `nina.contractor` — Nina Patel, night-shift contractor (read-only claim tools; no payout, no fraud check;
  a low per-user token budget)
* `dev` — developer

</details>

<details>
<summary><b>Demo UI</b></summary>

The demo runs from the **Showroom** at `https://showroom-parasol-showroom.apps.<cluster-domain>`: a
step-by-step guide on the left, the live apps on the right — both portals, Keycloak, OpenShift AI,
the OpenShift console, Argo CD, MLflow, and a Terminal with `oc` and this repo — so the whole demo
happens in one browser window. It walks the six scenarios (the colleague, the customer's document,
the confidential document, the night shift, the evaluation gate, the poisoned tool), the incident
reconstruction and the supply chain, says which tab each step uses, where to
look on the platform, which log commands confirm each beat, and how to reset and troubleshoot.

Sign in with your OpenShift account when the Showroom opens; the framed consoles reuse that session.
`scripts/showroom-framing.sh` (run by `bootstrap.sh`) lets only the Showroom frame the consoles.

</details>

<details>
<summary><b>Demo scripts</b> — the operator's runbook</summary>

The demo itself happens in the browser (see **Demo UI**); these are the terminal steps behind it.
First: export the model variables from **Quick install** (`AGENT_*`, `GUARD_*`, `JUDGE_*`).

Before the demo:
1. `scripts/probe-maas.sh` — confirm the agent model emits structured tool calls (pass other model ids as arguments to compare).
2. `scripts/status.sh` — confirm all Argo apps are Synced/Healthy and both portals are up.

The scripts behind each scenario (the browser steps are in **Demo UI**):
1. **Reset** — `scripts/reset.sh` re-seeds both portals' claims and refills the per-user token budget.
   It runs as the first step of Scenario 1, and again before Scenario 4's secured run.
2. **Scenario 1 — the colleague** — driven in the browser. Headless equivalent:
   - `scripts/abuse.sh free` — rebecca approves;
   - `scripts/abuse.sh secured rebecca` — filtered tool list + 403;
   - `scripts/abuse.sh secured marcus 1` — the manager succeeds.
3. **Scenario 2 — the customer's document** — driven in the browser. Headless equivalent:
   - `scripts/abuse-doc.sh both` — the unsecured portal pays AED 84,000; secured flags the hidden
     note and proposes without writing.
4. **Scenario 3 — the confidential document** — `scripts/knowledge-base-demo.sh` asks the scenario's
   questions on both portals as rebecca, marcus and nina.contractor; `scripts/knowledge-base-ingest.sh`
   (re)loads the knowledge base (idempotent).
5. **Scenario 4 — the night shift** — `scripts/night-shift.sh 40` logs in as `nina.contractor` and loops
   requests; run it against each portal as in Demo UI.
6. **Scenario 5 — the evaluation gate** — `scripts/eval-goldenset.sh` runs the golden set (secured
   blocked vs unsecured allowed, PASS 3/3); the dashboard LMEval run is
   `oc apply -f gitops/platform/eval/lmevaljob-agent-model.yaml` then `oc get lmevaljob -n parasol-eval -w`;
   the golden set is generated live per release (3 attempts per case, majority; scored with the platform on for the gate and model alone for comparison): production 22 of 23 with the platform (18 alone), shortened candidate 20 of 23 (below the 0.95 gate), in MLflow `parasol-agent-eval`.
7. **Scenario 6 — the poisoned tool** — `scripts/tool-rugpull.sh plug|on|off|register|unregister|status`
   plugs the vendor `currency-converter` (project `parasol-thirdparty`) into the unsecured portal, flips its
   tool description (same version), and switches the governed registration on the secured gateway;
   the tool scanner (`mcp-system/mcp-tool-scanner`) flags and pins descriptions. `scripts/reset.sh` undoes all of it.
8. **The incident** — `scripts/incident-report.sh CLM-1001` (after marcus approved CLM-1001) prints the
   joined evidence read-only: timeline and PAYOUT line, approval and proposal traces, TOKEN_EXCHANGE events,
   gateway refusals, the release on `env-secured`, the registry version and the signed digest.
9. **Layer 6 — supply chain** — `scripts/signing-demo.sh` shows admission refusing an unsigned image
   and admitting the signed one.

Other helpers:
- `scripts/token.sh <user>` — print a demo user's access token (headless login through the public client `parasol-demo-cli`; the portal client is browser-only).
- `scripts/agent-token.sh <user> [fraud-agent]` — the token an agent presents for that user at the MCP gateway.
- Bootstrap helpers, called by `bootstrap.sh` (each idempotent, re-runnable alone): `ensure-operators.py`,
  `rhoai-enable.sh`, `build-images.sh`, `gen-trusted-keys.sh`, `authorino-tls.sh`, `maas-key.sh`,
  `maas-portal-keys.sh`, `portal-oidc-client.sh`, `portal-users.sh`, `fetch-detector-model.sh`,
  `supply-chain.sh` (SPIRE, Trusted Artifact Signer, cosign key, admission), `seed-demo.sh` (MLflow,
  prompt/model registry, `eval-seed.sh`, `evalhub-run.sh`, `ogx-playground.sh`, `pipeline-runs.sh`).
- MaaS catalogue (two external models, per-tier keys): `maas-model-keys.sh` puts each per-model MaaS
  key into its own cluster Secret; `maas-ext-model-secrets.sh` creates the upstream per-model key Secrets
  (and the required `inference.llm-d.ai/ipp-managed=true` label); `maas-tier-keys.sh` mints the prod + guard
  tier keys; `maas-extproc-reload.sh` reloads the ai-gateway ext-procs for the "model registered before
  the ext-proc started" case.

</details>

<details>
<summary><b>Architecture</b> — how the secured side stops each scenario</summary>

The secured portal is a stack of layers, each a distinct Red Hat component declared in Git. The point
of the stack is that a *different* layer catches each scenario:

* **Scenario 1 (the colleague)** → **identity + tool authorization.** The assistant acts on behalf of
  the Keycloak user: every tool call carries a token the agent (`parasol-claims-agent`, authenticated by
  its ServiceAccount token, no secret) exchanged for the user's, holding only the roles that are both the
  user's and inside the agent's ceiling (Layer 2); the MCP gateway admits only approved agents' tokens, filters `tools/list` per identity and
  enforces a per-tool AuthPolicy, so rebecca never sees `approve_payout` and a forced `tools/call` is a
  403 (Layer 3). Even a permitted write happens only on a claims-manager's button click (Read-Propose-Act).
* **Scenario 2 (the customer's document)** → **guardrails + the same gate.** The guardrails proxy scans
  the tool result, flags the hidden "processing note" and masks PII (Layer 4); the Read-Propose-Act card
  surfaces the AED 84,000-vs-8,400 gap, so nothing is auto-written. Because both portals run the same
  injection-obeying model (`qwen3-14b`), this is shown without relying on model behaviour: the model obeys
  the note and tries to pay, and the hidden `approve_payout` + guardrails flag + Read-Propose-Act gate stop
  the write anyway.
* **Scenario 3 (the confidential document)** → **identity on data.** The knowledge-base server verifies the
  agent's on-behalf-of token and searches only the documents the user's groups may read; PostgreSQL
  row-level security refuses every other row to its role (Layer 2); a guardrails output rule withholds an
  answer carrying the restricted-document marker for anyone outside claims-managers (Layer 4).
* **Scenario 4 (the night shift)** → **model governance + observability.** MaaS gives the contractor a
  low per-tier token budget and returns 429 for that account alone (Layer 5); the topic guardrail refuses
  off-topic junk at zero cost (Layer 4); token metrics raise an alert naming the user and the agent, and the kill switch
  severs egress with one change on the Argo CD Application (Layer 7). Namespace isolation (Layer 1) bounds the blast radius throughout.

| # | Layer | Defends | Component | In this repo |
|---|---|---|---|---|
| 1 | Isolation | blast radius of all scenarios; only approved models | Namespace, ResourceQuota, NetworkPolicy (egress only to the platform gateways; every drop in the OVN ACL audit log), restricted PSA, no SA token, (Kata via `runtimeClassName`) | `gitops/envs/secured/{quota,networkpolicy,sandbox-patch}.yaml` |
| 2 | Identity | Scenarios 1 and 3 (documents and claim records) | Agent identities (`parasol-claims-agent`, `parasol-fraud-agent`: ServiceAccount token as client assertion) acting on behalf of the user via token exchange, with per-agent role ceilings | `apps/parasol-portal` (`CallerIdentity`, `McpBearerTokenProvider`), `gitops/platform/keycloak`, `scripts/agent-clients.sh`, `apps/mcp-servers/knowledge-base`, `gitops/envs/secured/knowledge-base.yaml` |
| 3 | Tool authorization | Scenario 1 | MCP gateway (Connectivity Link, TP): federation, per-identity tool list, per-tool AuthPolicy | `gitops/platform/mcp-gateway`, `gitops/envs/secured/mcp-registrations.yaml` |
| 4 | Guardrails | Scenarios 2, 3 and 4 | Guardrails detection proxy (enforced): regex injection phrases, PII masking, topic refusal, off-list links and images removed from answers (rules in ConfigMap `guardrails-rules`); flag-and-continue or block, each detection logged and counted with user, agent and trace id. The HF prompt-injection detector is deployed but not inline. Additive model-based detectors in the guard tier: Granite Guardian (`granite-guardian-3-1-8b`) and optional Llama-Guard (user message only), shown in GenAI Studio | `gitops/platform/guardrails`, `gitops/platform/guardrails-guardian` |
| 5 | Model governance | Scenario 4 | OpenShift AI MaaS: **two external models** on their own tiers — `qwen3-14b` (prod, the agent both portals run) and `granite-guardian-3-1-8b` (guard, the detector) — each a MaaSSubscription + MaaSAuthPolicy with its own key and per-tier token budget enforced by Connectivity Link; the agent never holds the upstream key (TP for external models). The eval judge `gpt-oss-120b` is reached via its own key, off the tiers | `gitops/platform/rhoai/*`, `gitops/platform/maas-tiers`, `scripts/maas-key.sh`, `scripts/maas-portal-keys.sh`, `scripts/maas-tier-keys.sh` |
| 6 | Lifecycle gate | regressions, unsigned images (cross-cutting) | Tekton pipeline (build → scan → eval gate → cosign sign → promote); Sigstore admission `ClusterImagePolicy` | `gitops/platform/pipeline`, `scripts/signing-demo.sh` |
| 7 | Observability and control | Scenarios 3 and 4; knowing and stopping | OTel → Tempo and MLflow (each chat turn links to its trace; tags agent/prompt/model), Perses dashboard *Parasol Assistant Token Spend* (spend, tool calls, gateway rejections, guardrail hits by user and agent), PrometheusRule alert, kill-switch component | `gitops/platform/observability`, `gitops/envs/secured/kill-switch` |

**Request paths (secured).** Model: portal → model-gateway → guardrails-proxy → OpenShift AI MaaS
→ LiteLLM; the MaaS serves the model named in `agent-config` — **`qwen3-14b`** on both portals so the
hidden-note obedience is live. Tools: portal → MCP gateway (`https://mcp.apps.<domain>/mcp`, per-client virtual server)
→ `claims-db` / `policy-docs`. The **kill switch** is a kustomize component that *replaces* the
agent/portal NetworkPolicy egress (a NetworkPolicy only ever adds allows, so a "deny" policy would
do nothing); add it to the `env-secured` Application (`spec.source.kustomize.components`) and Argo severs the model path — pods keep running, the agent reaches nothing.

**Read-Propose-Act.** `approve_payout` is hidden from the gateway's `tools/list` for every identity
(so no model ever auto-calls it) but stays backend-federated; `tools/call` is still authorized by
the Keycloak `tool:approve_payout` role (claims-managers), so a manager's **Approve button**
executes it and an adjuster's forced call is a 403.

**GitOps.** Argo CD owns everything under `gitops/platform` and `gitops/envs`. The app-of-apps in
`gitops/bootstrap/apps` is *applied by `bootstrap.sh`* through `envsubst` (CLUSTER_DOMAIN, REPO_URL,
MAAS_*) and is not itself git-synced; everything else syncs from the remote. Argo `selfHeal` reverts
live `oc patch`es, so change synced resources via Git, not `oc`.

**Visible in OpenShift AI (not just YAML).** Models-as-a-Service lists the **two external models the
demo uses** (`qwen3-14b` the portals run on, and guard-tier `granite-guardian-3-1-8b`) with their
subscriptions, auth policies and per-key usage; the MCP catalog entries; the GenAI Studio playground
(model picker incl. Granite Guardian + MCP tools + guardrails toggles); the Guardrails Orchestrator and
its detectors; **Model evaluation runs** (TrustyAI/LMEval); and MLflow traces + the `parasol-agent-eval`
golden-set runs (prompt, tool calls, tokens).

Technology Preview as of OpenShift AI 3.5 / Connectivity Link 1.4 (Oct 2026): MCP gateway, MCP
catalog + lifecycle operator, MaaS external-model egress, GenAI Studio guardrails. **Gateway-native MCP
guardrails** (`mcpGuardrailsMode` on the DataScienceCluster) are the blueprint-aligned target but remain a
TP gap on 3.5.1 — flipping the flag only re-reconciles the guardrails orchestrator and wires no guardrails
onto the production MCP gateway ext-proc (the 3.5.1 sidecar cannot relay tool-calling turns), so the
**guardrails-proxy is the enforced path** (both Scenario 2's hidden-note flag and Scenario 4's 0-token
topic refusal fire through it). Manifests mark field names to check against the installed CRDs with
`VERIFY` comments (`oc explain`).

</details>

<details>
<summary><b>Troubleshooting</b> — operational gotchas</summary>

* **MCP tool not appearing / `TotalTools: 0`.** Re-federating a tool needs the `MCPServerRegistration`
  deleted and recreated **and** the mcp-gateway broker pod (ns `mcp-system`) restarted; the
  registration alone shows zero tools until the broker bounces.
* **A live `oc patch` reverts itself.** Argo `selfHeal` on `env-secured` reverts live edits. Change
  synced resources (e.g. the MCPVirtualServer tool list) via Git + an Argo refresh, not `oc`.
* **Reset to a clean state.** The live gate/propose tests re-approve CLM-1001 and mutate claims;
  `scripts/reset.sh` restores both the data and the per-user token allowance (it restarts Limitador).
* **429 shows as HTTP 502.** The portal surfaces the upstream 429 as a 502 whose chat body still reads
  "you have reached your usage limit (429)". The on-screen wording is correct; only the HTTP status
  differs. `night-shift.sh` detects the limit from the body.
* **Kill switch "does nothing".** A separate quarantine NetworkPolicy only adds allows and blocks
  nothing — the kill-switch component must *replace* the egress. Under the kill switch the agent
  returns a clean 502 after ~50 s (connect timeout + one retry).
* **Portal not exporting traces.** `QUARKUS_OTEL_ENABLED` is build-time; at runtime set
  `QUARKUS_OTEL_SDK_DISABLED=false` + `QUARKUS_OTEL_EXPORTER_OTLP_ENDPOINT` + `quarkus.application.name`.
* **OpenShift AI MaaS not Ready.** Each Gateway that calls Authorino needs the annotation
  `security.opendatahub.io/authorino-tls-bootstrap: "true"`; the MaaS gateway must listen HTTPS 443
  with a service-CA cert whose listener hostname is the Service FQDN; the upstream key Secret needs
  the label `inference.llm-d.ai/ipp-managed=true`. `scripts/authorino-tls.sh` does the Authorino part
  (auto-revert). Enabling Authorino TLS and then forcing a Kuadrant reconcile can leave the Kuadrant
  EnvoyFilters in plaintext and break the MCP gateway — if that happens, revert and re-verify.
* **Which models obey the hidden note.** `llama-scout-17b` does **not** obey (0/30 with the white-text
  note); `qwen3-14b` and `gpt-oss-120b` **do** (6/6). Both portals now run on **`qwen3-14b`** so the
  obedience is shown live: unsecured pays the inflated AED 84,000 on a denied claim; secured, the same
  obeying model can only *propose* (`approve_payout` is hidden), guardrails flag the note, and the gate
  catches the 10× amount — the secured controls stop the payout regardless of which model obeys.
* **Keycloak tools come back empty (`tools=[]`) or every tool call is a 403.** The agent's exchanged
  token must carry `resource_access` roles for `claims-db`/`policy-docs` and `azp=parasol-claims-agent`
  (`scripts/agent-token.sh rebecca` shows what the gateway sees); re-run `scripts/agent-clients.sh`.
  A `calls must come through an approved agent` 403 means a raw login token reached the gateway.

</details>
