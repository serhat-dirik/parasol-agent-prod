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
