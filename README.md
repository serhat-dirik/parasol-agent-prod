# AI Agents: From localhost to Production

Demo repository for the Red Hat Dev Day talk **"AI Agents: From localhost to Production, the gap nobody talks much about."**

One agent, the Parasol Insurance claims assistant, runs twice on the same OpenShift cluster:

* `parasol-free`: lift-and-shift. The containers from the laptop, copied to a namespace. Nothing between the agent and its tools, nothing between the agent and the model but a key in a Secret.
* `parasol-secured`: the layered sandbox. Same images, same code. Isolation, identity, tool authorization, guardrails, model governance, observability and a kill switch, all declared in Git.

The same three abuses are run against both: an adjuster approving a payout through the agent, a poisoned policy document paying out a denied claim, and a buggy build burning tokens. In the free namespace they all succeed. In the secured one they are stopped by a different layer each.

## What is in here

| Path | What |
|---|---|
| `apps/parasol-agent` | Quarkus + LangChain4j agent (from the Parasol workshop) with identity forwarding, `/agent/tools`, token metrics and the "v3 retry bug" switch |
| `apps/mcp-servers/claims-db` | MCP server over the claims dataset, now with one write tool: `approve_payout` |
| `apps/mcp-servers/policy-docs` | MCP server over policy documents, now with one poisoned document: `POL-VENDOR-07` |
| `gitops/bootstrap` | Operator subscriptions and the Argo CD app-of-apps |
| `gitops/platform` | Keycloak realm, MCP gateway + AuthPolicies, OpenShift AI MaaS governance, Guardrails Orchestrator, observability, image builds |
| `gitops/envs/free`, `gitops/envs/secured`, `gitops/envs/secured-storm` | The two environments and the "v3" variant |
| `scripts/` | bootstrap helpers, `abuse.sh`, `reset.sh`, `token.sh`, `probe-maas.sh` |
| `docs/` | the layers, the clip plan, the demo script |

## Quick start

Prerequisites: a fresh OpenShift 4.22 cluster (3 workers, 16 vCPU / 64 GB recommended), `oc` logged in as cluster-admin, `kustomize`, `envsubst`, `openssl`, `python3` with PyYAML, and an OpenAI-compatible MaaS endpoint with a key.

```bash
export MAAS_ENDPOINT=https://<maas-host>/v1
export MAAS_API_KEY=<key>
export MAAS_MODEL=llama-scout-17b      # or qwen3-14b once scripts/probe-maas.sh says PASS
./bootstrap.sh
```

Then:

```bash
scripts/probe-maas.sh                  # which models emit structured tool calls
scripts/abuse.sh free                  # uncontrolled
scripts/abuse.sh secured rebecca       # sandboxed, as the adjuster
scripts/abuse.sh secured marcus 1      # the manager may approve
scripts/reset.sh                       # put the data back between takes
```

Kill switch: add `./kill-switch` to `components:` in `gitops/envs/secured/kustomization.yaml`, commit, let Argo sync. The pods keep running; the agent can reach nothing.

Technology Preview pieces (MCP gateway, MCP catalog, MaaS external egress) are marked in the manifests with `VERIFY` comments where field names must be checked against the installed CRDs (`oc explain`).

## Demo users

Keycloak realm `parasol`: `rebecca` (claims adjuster, read-only tools), `marcus` (claims manager, may approve payouts), `dev`. Passwords equal the usernames. They exist only for this demo.
