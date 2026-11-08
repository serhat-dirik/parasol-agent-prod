#!/usr/bin/env bash
# Put the claims data back between takes (both environments) and give the secured agent a fresh
# model allowance (Limitador keeps its token counters in memory; a restart clears them).
for ns in parasol-free parasol-secured; do
  oc exec -n $ns deploy/claims-db -- curl -s -X POST localhost:8080/admin/reset 2>/dev/null && echo " $ns reset" || echo " $ns: not running"
done
if [ "${1:-}" != "--keep-allowance" ]; then
  oc rollout restart deploy/limitador-limitador -n kuadrant-system >/dev/null \
    && oc rollout status deploy/limitador-limitador -n kuadrant-system --timeout=120s >/dev/null \
    && echo " model allowance reset" || echo " model allowance: Limitador restart failed"
fi
# Showcase 7: the bank's latest back to 1.4.2 (the unsecured side restarts on it) and out of the free assistant. The
# secured side needs nothing: it only ever runs what onboarding promoted.
if oc get istag currency-converter:1.4.2 -n parasol-build >/dev/null 2>&1; then
  [ "$(oc get istag currency-converter:latest -n parasol-build -o jsonpath='{.image.metadata.name}' 2>/dev/null)" = \
    "$(oc get istag currency-converter:1.4.2 -n parasol-build -o jsonpath='{.image.metadata.name}')" ] \
    && echo " the bank's latest: 1.4.2" || "$(dirname "$0")/tool-rugpull.sh" release 1.4.2 | head -1
  "$(dirname "$0")/tool-rugpull.sh" unplug
fi
# Showcase 4 operator switches: gateways back up, Parasol's MaaS subscriptions and users back on, both agents
# enabled (each a no-op when already so).
"$(dirname "$0")/kill-switch.sh" break-glass on >/dev/null && echo " gateways: on" || echo " gateways: kill-switch.sh break-glass on failed"
"$(dirname "$0")/kill-switch.sh" parasol on >/dev/null && echo " MaaS subscriptions: on" || echo " MaaS subscriptions: kill-switch.sh parasol on failed"
"$(dirname "$0")/kill-switch.sh" user --all on >/dev/null && echo " users: enabled" || echo " users: kill-switch.sh user --all on failed"
for a in claims-agent fraud-agent; do
  "$(dirname "$0")/agent-switch.sh" $a on >/dev/null && echo " $a: enabled" || echo " $a: agent-switch.sh on failed"
done
