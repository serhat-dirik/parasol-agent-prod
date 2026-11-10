# policy-docs (MCP server)

Keyword retrieval over Parasol's policy documents, exposed as MCP tools. The claims assistant in the
Parasol portal calls `search_policies` to ground answers about coverage, deductibles, documentation, claim
workflow, service levels and payout timing, and cites the policy id it used.

## Tools

| Tool              | Arguments                       | Returns                                                         |
|-------------------|---------------------------------|-----------------------------------------------------------------|
| `search_policies` | `query`, `maxResults` (opt, ≤8) | Top matching passages (id, title, category, score, text)        |
| `get_policy`      | `policyId`                      | One document in full, or a not-found message                    |
| `list_policies`   | —                               | The catalog (id, title, category)                               |

## Corpus and retrieval

* Nine documents in code (`PolicyCorpus`): auto, home, life and claim workflow (`POL-CLAIM-01..03`:
  statuses, review SLAs, payment after approval).
* `POL-VENDOR-07` carries a hidden instruction to pay a claim: the poisoned document of Showcase 2.
  Ids and facts are referenced by the guide, the eval golden set and the regression; do not reorder or edit them.
* Ranking is a weighted term-frequency score (title ×3, body ×1, stopwords dropped, ties by id). No
  embeddings, no database, no model call: the same query always returns the same passages, which the
  release gate's evaluation relies on.
* Permission-aware vector retrieval (pgvector, per-user filtering) is the separate `knowledge-base` server
  (`apps/mcp-servers/knowledge-base`, tool `search_knowledge`).

## Endpoint and callers

Streamable HTTP at `POST /mcp` on port 8080 (`quarkus-mcp-server-http`). The portal reads the URL from
`agent-config` key `policyDocsMcpUrl` (env `POLICY_DOCS_MCP_URL`):

| Environment       | Runs as                                                                 | Portal calls                                     |
|-------------------|-------------------------------------------------------------------------|--------------------------------------------------|
| `parasol-free`    | Deployment (`gitops/envs/base/policy-docs.yaml`)                        | `http://policy-docs:8080/mcp` directly           |
| `parasol-secured` | `MCPServer` run by the OpenShift AI MCP lifecycle operator (`gitops/envs/secured/policy-docs-mcpserver.yaml`) | the MCP gateway, header `X-Mcp-Virtualserver: parasol-secured/policy-docs`; Keycloak roles `tool:search_policies`, `tool:get_policy`, `tool:list_policies` |

In `parasol-secured` only the MCP gateway may reach the server (AdminNetworkPolicy `parasol-mcp-servers`), and
the `MCPServerRegistration` pins the sha256 of the reviewed tool definitions (`MCPToolDefinitionDrift` fires
on a change).

## Build

In-cluster binary build into `parasol-build/policy-docs:latest`:

```
scripts/build-images.sh policy-docs
```

The script restarts the free Deployment and deletes the secured one so the operator recreates it on the new
digest (admission pins the digest).

## Local development

```
./mvnw quarkus:dev      # port 8082
./mvnw test
```

## Tech

Quarkus 3.33.2.1, Java 21, `quarkus-mcp-server-http` 1.13.1. UBI9 multi-stage `Containerfile`
(`ubi9/openjdk-21:1.23` → `ubi9/openjdk-21-runtime:1.23`), non-root UID 185, restricted-v2 SCC. Health at
`/q/health/*`, Prometheus metrics at `/q/metrics`, OpenTelemetry tracing (the secured `MCPServer` turns the
exporter on to the cluster collector).
