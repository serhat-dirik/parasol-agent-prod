#!/usr/bin/env bash
# authorino-tls.sh [apply|revert] : Authorino listener TLS for OpenShift AI MaaS, the documented way.
# TLS on Authorino alone breaks every gateway that calls it in plaintext; each Gateway needs the
# security.opendatahub.io/authorino-tls-bootstrap annotation so the platform creates a TLS EnvoyFilter
# for it (interim until Connectivity Link supports this natively, CONNLINK-528).
# apply: annotate both gateways, enable TLS, wait for TLS EnvoyFilters, then test the MCP gateway.
#        If the MCP gateway does not answer within the deadline, it reverts on its own.
set -uo pipefail
cd "$(dirname "$0")/.."
NS=kuadrant-system
GW_URL="https://mcp.apps.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')/mcp"

revert() {
  echo "== revert: Authorino listener TLS off"
  oc patch authorino authorino -n $NS --type merge -p '{"spec":{"listener":{"tls":{"enabled":false,"certSecretRef":null}}}}'
  oc rollout status deploy/authorino -n $NS --timeout=180s
}

envoyfilters() {
  oc get envoyfilter -A -o json | python3 -c 'import sys,json
for e in json.load(sys.stdin)["items"]:
  s=json.dumps(e["spec"])
  if "authorino" in s: print("  %s/%s: %s" % (e["metadata"]["namespace"], e["metadata"]["name"], "tls" if ("transport_socket" in s or "UpstreamTlsContext" in s) else "plaintext"))'
}

gateway_ok() {  # MCP initialize as rebecca: 200 means the gateway's auth path works
  local t; t=$(scripts/token.sh rebecca) || return 1
  [ "$(curl -sk -o /dev/null -w '%{http_code}' "$GW_URL" -H "Authorization: Bearer $t" \
      -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
      -H 'X-Mcp-Virtualserver: parasol-secured/claims-db' \
      -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"tls-check","version":"1"}}}')" = 200 ]
}

[ "${1:-apply}" = revert ] && { revert; exit 0; }

echo "== before"; envoyfilters
gateway_ok && echo "  MCP gateway OK" || { echo "  MCP gateway already failing; not touching anything"; exit 1; }

echo "== annotate gateways"
oc annotate gateway maas-default-gateway -n openshift-ingress security.opendatahub.io/authorino-tls-bootstrap=true opendatahub.io/managed=false --overwrite
oc annotate gateway mcp-gateway -n gateway-system security.opendatahub.io/authorino-tls-bootstrap=true --overwrite
echo "== Authorino: serving cert, listener TLS, CA bundle (service-account path)"
oc annotate service authorino-authorino-authorization -n $NS service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert --overwrite
oc patch authorino authorino -n $NS --type merge -p '{"spec":{"listener":{"tls":{"enabled":true,"certSecretRef":{"name":"authorino-server-cert"}}}}}'
oc set env deployment/authorino -n $NS \
  SSL_CERT_FILE=/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt \
  REQUESTS_CA_BUNDLE=/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
oc rollout status deploy/authorino -n $NS --timeout=180s

echo "== waiting up to 3 min for TLS EnvoyFilters and a working MCP gateway"
for i in $(seq 1 12); do
  echo "$(date +%T) try $i"; envoyfilters
  if gateway_ok; then echo "== MCP gateway OK with Authorino TLS"; break; fi
  [ "$i" = 12 ] && { echo "== MCP gateway still failing"; revert; exit 1; }
  sleep 15
done

echo "== MaaS readiness"
oc rollout restart deploy/maas-api -n redhat-ai-gateway-infra 2>/dev/null || echo "  (maas-api deployment not present yet)"
oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}: {.status.conditions[?(@.type=="ModelsAsAServiceReady")].message}{"\n"}'
echo "Next: scripts/abuse.sh secured rebecca 1   (Clip B still: filtered list + 403)"
