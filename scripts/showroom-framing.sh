#!/usr/bin/env bash
# showroom-framing.sh [--revert]
# Lets the Showroom cockpit frame the platform consoles (Keycloak, OpenShift console, Argo CD,
# OpenShift AI, MLflow) by rewriting two response headers on the default IngressController:
#   - delete X-Frame-Options
#   - set Content-Security-Policy to "frame-ancestors 'self' https://<showroom host>"
# This replaces every routed app's own CSP on this cluster with "only this cluster and the Showroom
# may frame me" (lab-only trade-off). OpenShift AI and MLflow are routed through the router too
# (Route data-science-gateway, reencrypt), so they are covered. Passthrough routes (oauth-openshift)
# are not: sign in to a console once in a normal browser tab, then its framed tab reuses the session.
# Idempotent; the router pods roll once on the first apply. --revert removes the header actions.
set -euo pipefail
if [ "${1:-}" = "--revert" ]; then
  oc patch ingresscontroller default -n openshift-ingress-operator --type=json \
    -p '[{"op":"remove","path":"/spec/httpHeaders/actions"}]' 2>/dev/null || true
  echo "showroom framing: header actions removed"; exit 0
fi
DOMAIN=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')
SHOWROOM="https://showroom-parasol-showroom.${DOMAIN}"
oc patch ingresscontroller default -n openshift-ingress-operator --type=merge -p "$(cat <<JSON
{"spec":{"httpHeaders":{"actions":{"response":[
  {"name":"X-Frame-Options","action":{"type":"Delete"}},
  {"name":"Content-Security-Policy","action":{"type":"Set","set":{"value":"frame-ancestors 'self' ${SHOWROOM}"}}}
]}}}}
JSON
)"
echo "showroom framing: consoles may be framed by ${SHOWROOM}"
