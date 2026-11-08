#!/usr/bin/env bash
# showcase4.sh <topic> : evidence of Showcase 4, the operator's night (read-only)
#   spend        model tokens and refusals per user and agent, from the secured portal's own counters
#   tiers        the MaaS subscriptions: who may use which model, with which token budget (also Showcase 6)
#   agenticops   the latest AgentOps checks on the agent's turns in MLflow (also Showcase 1)
. "$(dirname "$0")/lib.sh"

case "${1:-}" in
spend)
  title "Model spend and refusals per user and agent (the secured portal's own counters, since its pod started)"
  run "oc exec -n parasol-secured deploy/portal -- curl -s localhost:8080/q/metrics | grep -E '^parasol_agent_(tokens|rejections)_total'" | python3 -c '
import sys, re, collections
tok, rej = collections.Counter(), collections.Counter()
for l in sys.stdin:
    m = re.match(r"parasol_agent_(tokens|rejections)_total\{([^}]*)\} ([0-9.eE+]+)", l)
    if not m: continue
    lb = dict(re.findall(r"(\w+)=\"([^\"]*)\"", m.group(2)))
    who = "%s via %s" % (lb.get("user"), lb.get("agent"))
    if m.group(1) == "tokens": tok[who] += float(m.group(3))
    else: rej[(who, lb.get("reason"))] += float(m.group(3))
print("  tokens:")
for who, n in tok.most_common(): print("    %-42s %8d" % (who, n))
print("  refused by the platform:")
for (who, why), n in sorted(rej.items()): print("    %-42s %-16s %d" % (who, why, n))
if not rej: print("    none")'
  note "usage_limit = the MaaS token budget of the user's tier answered 429; the model was not called." ;;
tiers)
  title "MaaS subscriptions (models-as-a-service): who may use which model, with which token budget"
  run "oc get maassubscription -n models-as-a-service -o json" | python3 -c '
import sys, json
for s in json.load(sys.stdin)["items"]:
    sp, an = s["spec"], s["metadata"].get("annotations", {})
    owners = ", ".join(g["name"] for g in sp.get("owner", {}).get("groups", []))
    off = "  SWITCHED OFF (kill switch)" if "parasol.example/kill-switch-owner" in an else ""
    print("  %-20s owners: %s%s" % (s["metadata"]["name"], owners, off))
    for m in sp.get("modelRefs", []):
        lim = ", ".join("%s tokens / %s" % (r["limit"], r["window"]) for r in m.get("tokenRateLimits", [])) or "no token limit"
        print("  %-20s   %-26s %s" % ("", m["name"], lim))' ;;
agenticops)
  title "AgenticOps (CronJob agenticops, observability, every 10 minutes): the checks on new agent turns, last runs"
  pods=$(run "oc get pods -n observability -o name --sort-by=.metadata.creationTimestamp 2>/dev/null | grep '/agenticops-' | tail -3" || true)
  [ -n "$pods" ] || { echo "  no run found (not readable here, or not deployed: MLflow tab, a trace, Assessments)"; exit 0; }
  for p in $pods; do run "oc logs -n observability $p 2>/dev/null" || true; done \
    | grep -E 'flagged=|checked ' | grep -v 'flagged=none' | tail -8 | sed 's/^/  /'
  note "Each turn gets loop, excess_steps, unknown_tool, pii_in_tool_args; a sample also goal_achieved (the judge model through MaaS)." ;;
*) usage ;;
esac
