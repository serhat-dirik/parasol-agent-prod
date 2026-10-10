#!/usr/bin/env bash
# V6-DOCLING: deploy the isolated Docling + nomic-embed policy RAG stack (ns parasol-rag).
# Reads MaaS key 2 from the credentials file at run time; the key value is NEVER printed
# or committed. Idempotent: safe to re-run. Teardown: oc delete ns parasol-rag.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=gitops/platform/docling-rag
CRED="${CREDENTIALS_FILE:-/Users/hdirik/RHSA/RedHatSASupport/AgentsInProd/credentials.txt}"

# MaaS key 2 (evaluations) + base URL — value read straight into the secret, not echoed.
KEY2="$(grep -A1 '^litellm_user2_virtual_key' "$CRED" | tail -1 | tr -d '[:space:]')"
BASE="$(grep -A1 '^litellm_api_base_url' "$CRED" | tail -1 | tr -d '[:space:]')"
[ -n "$KEY2" ] && [ -n "$BASE" ] || { echo "could not read key2/base from $CRED"; exit 1; }

oc apply -f "$DIR/namespace.yaml"

oc create secret generic maas-rag -n parasol-rag \
  --from-literal=OPENAI_API_KEY="$KEY2" \
  --from-literal=OPENAI_API_BASE="$BASE" \
  --dry-run=client -o yaml | oc apply -f -

oc create configmap policy-rag-code -n parasol-rag \
  --from-file=rag_app.py="$DIR/app/rag_app.py" \
  --from-file=corpus.json="$DIR/app/corpus.json" \
  --dry-run=client -o yaml | oc apply -f -

oc create configmap policy-pdf -n parasol-rag \
  --from-file=policy-info.pdf=apps/parasol-portal/app/src/main/resources/policies/policy-info.pdf \
  --dry-run=client -o yaml | oc apply -f -

oc apply -f "$DIR/embed-server.yaml"
oc apply -f "$DIR/rag-app.yaml"

echo "applied. route: https://$(oc get route policy-rag -n parasol-rag -o jsonpath='{.spec.host}' 2>/dev/null || echo pending)"
