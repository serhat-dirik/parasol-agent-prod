#!/usr/bin/env bash
# ES256 key pair for the MCP gateway's trusted header (x-mcp-authorized wristband):
# private key for Authorino (kuadrant-system), public key for the broker (mcp-system). Idempotent.
set -euo pipefail
if oc get secret trusted-headers-public-key -n mcp-system >/dev/null 2>&1 && oc get secret trusted-headers-private-key -n kuadrant-system >/dev/null 2>&1; then
  echo "trusted header keys already present"; exit 0; fi
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
openssl ecparam -name prime256v1 -genkey -noout -out "$d/private-key.pem"
openssl ec -in "$d/private-key.pem" -pubout -out "$d/public-key.pem" 2>/dev/null
oc get ns mcp-system >/dev/null 2>&1 || oc create ns mcp-system
oc get ns kuadrant-system >/dev/null 2>&1 || oc create ns kuadrant-system
oc create secret generic trusted-headers-public-key --from-file=key="$d/public-key.pem" -n mcp-system --dry-run=client -o yaml | oc apply -f -
oc create secret generic trusted-headers-private-key --from-file=key.pem="$d/private-key.pem" -n kuadrant-system --dry-run=client -o yaml | oc apply -f -
echo "trusted header keys created"
