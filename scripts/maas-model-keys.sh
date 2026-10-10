#!/usr/bin/env bash
# Put each per-model MaaS key (exported by load-credentials.sh as MAAS_KEY_*) into its OWN cluster
# Secret, in the namespaces that consume it. Idempotent; key values are never printed or committed.
# Usage: source scripts/load-credentials.sh && scripts/maas-model-keys.sh
set -euo pipefail
: "${MAAS_KEY_GUARD:?source scripts/load-credentials.sh first (MAAS_KEY_* not set)}"

# mk <namespace> <secret-name> <key-value>  — Secret with data key GENAI_API_KEY (+ MAAS_API_KEY alias)
mk() {
  local ns="$1" name="$2" val="$3"
  if ! oc get ns "$ns" >/dev/null 2>&1; then echo "skip $ns/$name (namespace absent)"; return 0; fi
  if [ -z "$val" ]; then echo "skip $ns/$name (no key in credentials)"; return 0; fi
  oc create secret generic "$name" -n "$ns" \
    --from-literal=GENAI_API_KEY="$val" --from-literal=MAAS_API_KEY="$val" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  echo "secret $ns/$name applied"
}

# guard-tier detector models
mk parasol-guardian maas-key-granite-guardian "$MAAS_KEY_GUARD"
mk parasol-guardian maas-key-llama-guard      "${MAAS_KEY_LLAMAGUARD:-}"
# stage-tier model serving (granite-4-0-h-tiny)
mk models-as-a-service maas-key-granite-tiny  "$MAAS_KEY_STAGE"
# eval judge (gpt-oss-120b) — pipeline + eval namespaces
mk parasol-build maas-key-gpt-oss-120b        "$MAAS_KEY_JUDGE"
mk parasol-eval  maas-key-gpt-oss-120b        "$MAAS_KEY_JUDGE"
# replay model (qwen3-14b)
mk parasol-eval  maas-key-qwen3-14b           "${MAAS_KEY_QWEN3_14B:-}"

echo "done: per-model MaaS Secrets applied where the consuming namespace exists."
