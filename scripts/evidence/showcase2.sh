#!/usr/bin/env bash
# showcase2.sh <topic> : evidence of Showcase 2, the customer's document (read-only)
#   payouts [claim]  the latest claims-db payout record of both portals (showcase1.sh payouts)
#   guardrails       the NeMo rules, where they run, the gateway's blocks, the tools an agent can be offered
#   flags            the model-path guardrail decisions, with user, agent and trace id
. "$(dirname "$0")/lib.sh"

rails() {  # rails <configmap>: the rail names of one NeMo config, one line
  run "oc get cm $1 -n parasol-secured -o jsonpath='{.data.config\\.yaml}' 2>/dev/null" \
    | sed -n 's/^ *- \(parasol [a-z ]*[a-z]\).*/\1/p' | paste -sd, - | sed 's/,/, /g'
}

case "${1:-}" in
payouts) exec "$EV/showcase1.sh" payouts "${2:-}" ;;
guardrails)
  title "Guardrails run in NeMo Guardrails (NemoGuardrails parasol-nemo, parasol-secured): three configs, one rules file"
  echo "  parasol-tool-results       run by the MCP GATEWAY on every claims-db tool result -> block: the agent gets a"
  echo "                             refusal (HTTP 500; chip \"documents flagged as suspicious\") and never reads the document"
  echo "      rails: $(rails nemo-parasol-tool-results || echo '?')"
  echo "  parasol-chat               run by the guardrails proxy on the secured assistant's model path"
  echo "      user input:  injection phrases -> block; off-topic -> block; personal data -> mask"
  echo "      answers:     confidential marker (not claims-managers) -> block; external links -> redact"
  echo "      rails: $(rails nemo-parasol-chat || echo '?')"
  echo "  parasol-tool-descriptions  run by the onboarding pipeline on a third-party tool's descriptions (Showcase 7)"
  echo "      rails: $(rails nemo-parasol-tool-descriptions || echo '?')"
  title "Wiring at the MCP gateway"
  echo "  MCPGatewayExtension guardrails-ref:  $(run "oc get mcpgatewayextension -n mcp-system -o jsonpath='{.items[0].metadata.annotations.mcp\\.kuadrant\\.io/guardrails-ref}' 2>/dev/null" || echo '(not readable)')"
  echo "  claims-db guardrails-config-ids:     $(run "oc get mcpserverregistration claims-db -n parasol-secured -o jsonpath='{.metadata.annotations.mcp\\.kuadrant\\.io/guardrails-config-ids}' 2>/dev/null" || echo '(not readable)')"
  echo "  NeMo pods ready:                     $(run "oc get deploy parasol-nemo -n parasol-secured -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null" || echo '?')"
  title "Tool results the gateway blocked (last 3 hours)"
  { run "oc logs -n mcp-system deploy/mcp-gateway --since=3h 2>/dev/null | grep 'guardrails blocked'" || true; } \
    | sed -E 's/.*msg="?([^"]*)"? .*tool=([a-z_]+).*reason="?([^"]*)"?.*/  \2  \1  (\3)/' | tail -5 | grep . || echo "  none"
  title "Tools any agent in parasol-secured can be offered (MCPVirtualServer): approve_claim at most, no tool that pays"
  run "oc get mcpvirtualserver -n parasol-secured -o jsonpath='{range .items[*]}{\"  \"}{.metadata.name}{\": \"}{.spec.tools}{\"\\n\"}{end}'" \
    | tr -d '[]"' | sed 's/,/, /g'
  note "  approve_claim only sets a claim UnderReview -> Ready for payment; a claims manager's Release payment click pays" ;;
flags)
  title "Guardrail decisions on the model path in the last 3 hours (deploy/guardrails-proxy, parasol-secured)"
  run "oc logs -n parasol-secured deploy/guardrails-proxy --since=3h | grep 'guardrail action='" \
    | sed -E "s/.*action=([a-z]+) detector=([a-z-]+) score=([0-9.]+) user=([^ ]+) agent=([^ ]+) trace=([0-9a-f]+) text=(.*)/  \1  \2  \4 via \5  trace=\6  \7/" \
    | awk '!seen[$0]++' | tail -8 | grep . || echo "  none in the last 3 hours" ;;
*) usage ;;
esac
