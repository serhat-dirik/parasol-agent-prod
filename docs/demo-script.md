# Demo script and shot lists

Terminal prompt shows the identity: `parasol (rebecca) $`. 1080p, one font everywhere, captions added in editing.

## Clip A: uncontrolled (parasol-free), ~3 min
1. `scripts/status.sh` for 5 s: two namespaces, same images.
2. `oc get deploy -n parasol-free` and `oc get networkpolicy,authpolicy -n parasol-free` (nothing). Say: this is the laptop, copied.
3. `scripts/abuse.sh free`
   * Abuse 1: the agent approves CLM-1002 for whoever asks. Caption: "nobody asked who you are".
   * Abuse 2: the innocent question, `search_policies` then `approve_payout` CLM-1004, timeline shows Denied → Approved → PaymentIssued. Caption: "a document paid a claim".
   * Abuse 3 (storm overlay applied to free, or skip here and show in B): tokens climbing in `/q/metrics`.
4. `scripts/reset.sh`.

## Clip B: sandboxed (parasol-secured), ~3 min
1. `oc get networkpolicy,resourcequota -n parasol-secured`, `oc get mcpserverregistration,authpolicy -A`. 10 s, say the seven layers.
2. `scripts/abuse.sh secured rebecca`
   * tools visible: no `approve_payout`. Caption: "the model never sees the tool".
   * Abuse 1: 403 from the MCP gateway, `oc logs -n mcp-system deploy/mcp-gateway | grep approve_payout` shows user and tool.
   * Abuse 2: guardrails block, show `oc logs deploy/guardrails ... | grep -i detection` with the score; timeline of CLM-1004 still Denied.
3. `scripts/abuse.sh secured marcus 1`: the manager can. Same agent, same code.
4. `scripts/reset.sh`.

## Clip C: 3am, ~1.5 min
1. Switch Argo env-secured to the storm overlay (`gitops/envs/secured-storm`), wait for rollout, `scripts/abuse.sh secured rebecca 3`.
2. Console: Observe > Metrics `rate(parasol_agent_tokens_total[1m])*60`; alert `ParasolAgentTokenSpendHigh` firing; MaaS 429 in the agent log if the on-cluster MaaS is wired.
3. Console: Observe > Traces, the looping request: agent → gateway → claims-db spans repeating.
4. Kill switch: `git commit` adding `./kill-switch` to components, Argo syncs, `scripts/abuse.sh secured rebecca 1` returns a clean 502, `oc get pods` still Running. Caption: "revoke, don't kill".
5. Revert the commit, switch Argo back to `gitops/envs/secured`.

## Recording checklist
* `scripts/reset.sh` before every take. Fresh tokens (realm token lifespan is 1 h).
* Extra 5 s before/after each beat. Speed up waits 2 to 3x with a visible marker.
* Static fallback PNG of each final frame.
