# Demo script and shot lists

Terminal prompt shows the identity: `parasol (rebecca) $`. 1080p, one font everywhere, captions added in editing.

## Clip A: uncontrolled (parasol-free), ~3 min
1. `scripts/status.sh` for 5 s: two namespaces, same images.
2. `oc get deploy -n parasol-free` and `oc get networkpolicy,authpolicy -n parasol-free` (nothing). Say: this is the laptop, copied.
3. `scripts/abuse.sh free`
   * Abuse 1: the agent approves CLM-1002 for whoever asks. Caption: "nobody asked who you are".
   * Abuse 2: the innocent question, `search_policies` returns POL-VENDOR-07 with its hidden note, delivered to the model unfiltered: `oc logs -n parasol-free deploy/parasol-agent --tail=2000 | grep -o -i 'Claims assistant processing note[^]]*' | head -1`. With llama-scout-17b the model answers without acting on it (tested 9 Oct, 4 wordings, 0 of 12): narrate "this model ignored it today; nothing in this namespace would have stopped it". Caption: "nothing filtered the document".
   * Abuse 3 (storm overlay applied to free, or skip here and show in B): tokens climbing in `/q/metrics`.
4. `scripts/reset.sh`.

## Clip B: sandboxed (parasol-secured), ~3 min
1. `oc get networkpolicy,resourcequota -n parasol-secured`, `oc get mcpserverregistration,authpolicy -A`. 10 s, say the seven layers.
2. `scripts/abuse.sh secured rebecca`
   * tools visible: no `approve_payout`. Caption: "the model never sees the tool".
   * Abuse 1: the model reaches for `approve_payout` and the framework refuses (the tool does not exist for her); the same call forced at the gateway gets a 403 naming user and tool. `oc logs -n kuadrant-system deploy/authorino --since=10m | grep 'denied for'` shows it.
   * Abuse 2: guardrails block, `oc logs -n parasol-secured deploy/guardrails-proxy --since=10m | grep detection:` shows the regex hits with score 1.0; timeline of CLM-1004 still Denied.
3. `scripts/abuse.sh secured marcus 1`: the manager can. Same agent, same code.
4. `scripts/reset.sh`.

## Clip C: 3am, ~2 min
1. Switch Argo env-secured to the storm overlay: `oc patch application env-secured -n openshift-gitops --type merge -p '{"spec":{"source":{"path":"gitops/envs/secured-storm"}}}'`, then `oc rollout status deploy/parasol-agent -n parasol-secured --timeout=300s`, then `scripts/abuse.sh secured rebecca 3`.
2. Console: Observe > Metrics `sum by (version)(rate(parasol_agent_tokens_total[1m]))*60` climbs to ~120k tokens/min; Observe > Alerting `ParasolAgentTokenSpendHigh` pending, then firing after ~1.5 min (threshold 20000 tokens/min).
3. OpenShift AI MaaS cuts it off: the agent's MaaS key is on subscription `parasol-stage` (200k tokens / 10 min), so after ~190k tokens the MaaS gateway answers 429 and `abuse.sh` prints `Too Many Requests`. Order on 10 Oct: alert pending, then 429, then alert firing ~20 s later. `oc logs -n openshift-ingress deploy/maas-default-gateway-openshift-default --since=5m | grep '" 429 '`. Caption: "the platform stopped the spend".
4. Console: Observe > Traces (instance observability/parasol, service parasol-agent): the looping request, ~25 repeated `ClaimsAssistant.ask` / model-completion spans.
5. Switch Argo back (same `oc patch` with `gitops/envs/secured`), then `scripts/reset.sh` (also restores the model allowance).
6. Kill switch: `git commit` changing `components: []` to `components: [./kill-switch]` in `gitops/envs/secured/kustomization.yaml`, Argo syncs (~20 s), `scripts/abuse.sh secured rebecca 1` returns a clean 502 after ~50 s (two 25 s connection attempts; speed up in the edit), `oc get pods -n parasol-secured` still Running. Caption: "revoke, don't kill".
7. `git revert` the commit, Argo restores the model path, `scripts/reset.sh`.

## Recording checklist
* `scripts/reset.sh` before every take. Fresh tokens (realm token lifespan is 1 h).
* Extra 5 s before/after each beat. Speed up waits 2 to 3x with a visible marker.
* Static fallback PNG of each final frame.
