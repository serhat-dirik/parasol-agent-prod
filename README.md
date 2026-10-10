# AI Agents: From localhost to Production

Anyone can stand up an AI agent on a laptop in an afternoon. Running that same agent in
production — where real people use it, feed it real documents, and will try to abuse it — is
where the hard, rarely-discussed problems live. This repository is a working demonstration of
that gap, and of how an OpenShift-based platform closes it.

The application is the **Parasol Insurance claims portal**: a web app (Quarkus + React/PatternFly,
Keycloak login) whose chat assistant is a tool-using agent — it calls MCP tools to read claims and
policy documents and to approve payouts. The *same* portal image runs twice on one cluster:

* **`portal-free`** — the laptop setup, lifted into a namespace. Nothing sits between the agent and
  its tools, and nothing between the agent and the model but an API key in a Secret.
* **`portal` (secured)** — the same image behind a layered sandbox: namespace isolation, Keycloak
  identity carried to every tool call, per-identity tool authorization at an MCP gateway, content
  guardrails, model-as-a-service governance with per-tier token budgets, OpenTelemetry tracing and
  token metrics, a Git-commit kill switch, and a signed-image supply chain with admission control —
  all declared in Git and synced by Argo CD.

Three things a real user might do are run against both portals, and every beat is something you
watch happen in a browser:

1. **A colleague.** Rebecca, a claims adjuster, asks the assistant to approve a payout she has no
   authority to approve. *Free:* it approves. *Secured:* the tool is filtered out of her list and a
   forced call is refused by the MCP gateway; the assistant can only *propose*, and only a claims
   manager's click actually writes.
2. **A customer's document.** A repair estimate uploaded to a denied claim is inflated to
   AED 84,000 and carries a hidden "processing note" addressed to the assistant. *Free:* the agent
   pays 84,000 on a denied claim. *Secured:* guardrails flag the hidden instruction in the document
   and the Read-Propose-Act gate surfaces that the amount is 10× the real claim — no write happens.
3. **The night shift.** A policyholder account loops long off-topic requests at 2 a.m. to drain the
   token budget. *Free:* the shared key burns all night. *Secured:* the topic guardrail refuses the
   junk at no cost, a per-user budget returns HTTP 429 for that account while staff keep working, an
   alert fires naming the user, and the operator can disable the account or flip the kill switch —
   the pods keep running, the agent can reach nothing.

In `portal-free` all three cause harm. In `portal` a different layer stops each, and the platform
consoles (Keycloak, the OpenShift AI dashboard, the OpenShift console, Argo CD) show *why*. The
scripts in this repo are only for setting the demo up, playing the abusive customer, and resetting
between takes — the demo itself is the browser.

## What is in here

| Path | What |
|---|---|
| `apps/parasol-portal` | The Parasol claims portal (Quarkus + React/PatternFly, Keycloak login); its chat assistant is the tool-using agent — tool-call chips, Documents tab, Read-Propose-Act approval, guardrail banners, per-tier model keys, a dashboard |
| `apps/parasol-agent` | The same agent as a headless REST service, used by the test and load scripts (not what the audience sees) |
| `apps/mcp-servers/claims-db` | MCP server over the claims dataset (CLM-1001…1030) with the `approve_payout` write tool, `get_claim_documents` (the seeded customer document on CLM-1004), and a small REST API the portal reads |
| `apps/mcp-servers/policy-docs` | MCP server over the Parasol policy documents |
| `gitops/bootstrap` | Operator subscriptions and the Argo CD app-of-apps |
| `gitops/platform` | Keycloak realm, MCP gateway + AuthPolicies, OpenShift AI MaaS governance, Guardrails Orchestrator, observability (OTel → Tempo and MLflow), and the secure build pipeline with image signing and admission control |
| `gitops/envs/free`, `gitops/envs/secured`, `gitops/envs/secured-storm` | The two environments and the "v3" storm variant |
| `scripts/` | bootstrap helpers, `abuse.sh` / `abuse-doc.sh` (test harness), `night-shift.sh` (the abusive-customer load), `reset.sh`, `token.sh`, `probe-maas.sh` |
| `docs/` | the layers, the UI demo plan, and the shot list |

## Quick start

Prerequisites: a fresh OpenShift 4.22 cluster (3 workers, 16 vCPU / 64 GB recommended), `oc` logged in as cluster-admin, `kustomize`, `envsubst`, `openssl`, `python3` with PyYAML, and an OpenAI-compatible MaaS endpoint with a key.

```bash
export MAAS_ENDPOINT=https://<maas-host>/v1
export MAAS_API_KEY=<key>
export MAAS_MODEL=llama-scout-17b      # the one model known to emit structured tool calls here
./bootstrap.sh
```

Then open the portals in a browser — this is the demo:

* uncontrolled: `https://portal-free.apps.<cluster-domain>`
* secured: `https://portal.apps.<cluster-domain>`

The scripts are the setup and the abusive-customer load, not the demo itself:

```bash
scripts/probe-maas.sh                  # does the model emit structured tool calls?
scripts/abuse-doc.sh                   # scenario 2 (the customer document) against both portals
scripts/night-shift.sh                 # scenario 3: the policyholder loop that drains the budget
scripts/reset.sh                       # put the data (and the per-user token allowance) back between takes
```

Kill switch: add `./kill-switch` to `components:` in `gitops/envs/secured/kustomization.yaml`, commit, let Argo sync. The pods keep running; the agent can reach nothing. Remove the line to restore.

Technology Preview pieces (MCP gateway, MCP catalog, MaaS external egress, Guardrails) are marked in the manifests with `VERIFY` comments where field names must be checked against the installed CRDs (`oc explain`).

## Demo users

Keycloak realm `parasol` (passwords equal the usernames; they exist only for this demo):

* `rebecca` — claims adjuster (read-only tools; can propose but not approve)
* `marcus` — claims manager (may approve payouts)
* `tom.becker` — policyholder, the night-shift account (no claims tools; a low per-user token budget)
* `dev` — developer
