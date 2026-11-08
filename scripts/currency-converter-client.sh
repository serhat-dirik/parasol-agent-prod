#!/usr/bin/env bash
# Idempotent: the partner bank's exchange-rate service (Showcase 7) as a resource server in realm 'parasol'.
# Client parasol-secured/currency-converter with role tool:convert_currency, granted to adjusters and claims-managers
# (contractors and developers do not convert settlement amounts). Runs before scripts/agent-clients.sh, which puts the
# tool in the claims agent's ceiling. Mirrored into gitops/platform/keycloak/realm-import.yaml.
TOOL_CLIENT=parasol-secured/currency-converter TOOL_ROLE=tool:convert_currency TOOL_NAME="currency converter, partner bank" \
  TOOL_GROUPS="adjusters claims-managers" exec "$(dirname "$0")/knowledge-base-client.sh"
