#!/usr/bin/env bash
echo "--- Argo applications"; oc get applications -n openshift-gitops -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null
echo "--- gateway"; oc get gateway -n gateway-system 2>/dev/null; oc get mcpgatewayextension -A 2>/dev/null; oc get mcpserverregistration -A 2>/dev/null; oc get authpolicy -A 2>/dev/null
echo "--- pods"; for ns in keycloak parasol-free parasol-secured; do echo "[$ns]"; oc get pods -n $ns 2>/dev/null; done
echo "--- routes"; for ns in parasol-free parasol-secured; do echo "$ns: https://$(oc get route parasol-agent -n $ns -o jsonpath='{.spec.host}' 2>/dev/null)"; done
echo "keycloak: https://$(oc get route -n keycloak -o jsonpath='{.items[0].spec.host}' 2>/dev/null)"
echo "mcp gateway: https://$(oc get route mcp-gateway -n gateway-system -o jsonpath='{.spec.host}' 2>/dev/null)/mcp"
