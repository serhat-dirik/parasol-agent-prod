#!/usr/bin/env bash
# Idempotent: the knowledge-base database credentials, one Secret per environment (parasol-free, parasol-secured),
# generated here once and never printed or committed. Keys: admin-password (postgres superuser: the ingestion
# job only), owner-password (kb_owner, owns the table), app-password (kb_app, the server's role: no owner, no
# superuser, no BYPASSRLS).
set -euo pipefail
for ns in parasol-free parasol-secured; do
  oc get ns "$ns" >/dev/null 2>&1 || oc create ns "$ns" >/dev/null
  if oc get secret knowledge-base-db -n "$ns" >/dev/null 2>&1; then
    echo "knowledge-base-db exists in $ns"
  else
    oc -n "$ns" create secret generic knowledge-base-db --from-literal=admin-password="$(openssl rand -hex 16)" \
      --from-literal=owner-password="$(openssl rand -hex 16)" --from-literal=app-password="$(openssl rand -hex 16)" >/dev/null
    echo "knowledge-base-db created in $ns"
  fi
done
