# The layered sandbox (what each layer is, which Red Hat component, where it lives in Git)

| # | Layer | Stops | Component | In this repo |
|---|---|---|---|---|
| 1 | Isolation | noisy neighbour, lateral movement, bypassing the gateway | Namespace, ResourceQuota, NetworkPolicy, restricted PSA, no SA token, (Kata via `runtimeClassName`) | `gitops/envs/secured/{quota,networkpolicy,sandbox-patch}.yaml` |
| 2 | Identity | "the agent acts as a service account" | Keycloak user identity forwarded by the agent; service identity for discovery | `apps/parasol-agent/.../McpBearerTokenProvider.java`, `gitops/platform/keycloak` |
| 3 | Tool authorization | adjuster approving payouts, tool sprawl | MCP gateway (Connectivity Link, TP): federation, per-identity tool list, per-tool AuthPolicy | `gitops/platform/mcp-gateway`, `gitops/envs/secured/mcp-registrations.yaml` |
| 4 | Guardrails | injected instructions in documents and tool results | TrustyAI Guardrails Orchestrator gateway: prompt-injection classifier + regex | `gitops/platform/guardrails` |
| 5 | Model governance | unbounded spend, wrong model for the tier | Connectivity Link TokenRateLimitPolicy on the model gateway (the mechanism OpenShift AI MaaS generates; MaaS external models are TP and its API needs Authorino TLS) | `gitops/platform/rhoai/model-governance.yaml`, `maas.yaml` |
| 6 | Lifecycle gate | shipping a regression | pipeline with eval threshold, signed images, GitOps promotion | (stretch) |
| 7 | Observability and control | not knowing, not being able to stop it | OTel → Tempo, token metrics + PrometheusRule, kill-switch component | `gitops/platform/observability`, `gitops/envs/secured/kill-switch` |

Technology Preview as of OpenShift AI 3.5 / Connectivity Link 1.4 (Oct 2026): MCP gateway, MCP catalog and lifecycle operator, MaaS external model egress, MaaS observability dashboard. Say so on the slide.
