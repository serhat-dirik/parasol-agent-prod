#!/usr/bin/env bash
# Put each per-model key (install contract env, see bootstrap.sh) into its OWN cluster Secret, in the
# namespaces that consume it. Idempotent; key values are never printed or committed.
# Usage: scripts/maas-model-keys.sh   (with AGENT_/GUARD_/JUDGE_[/LLAMAGUARD_] ENDPOINT+KEY exported)
set -euo pipefail
: "${GUARD_KEY:?set the model env (AGENT_KEY, GUARD_KEY, JUDGE_KEY, ...) or source scripts/load-credentials.sh}"

# mk <namespace> <secret-name> <key-value>  — Secret with data key GENAI_API_KEY (+ MAAS_API_KEY alias,
# + api-key: the key EvalHub jobs read when the secret is the job's model.auth.secret_ref)
mk() {
  local ns="$1" name="$2" val="$3"
  if ! oc get ns "$ns" >/dev/null 2>&1; then echo "skip $ns/$name (namespace absent)"; return 0; fi
  if [ -z "$val" ]; then echo "skip $ns/$name (no key set)"; return 0; fi
  oc create secret generic "$name" -n "$ns" \
    --from-literal=GENAI_API_KEY="$val" --from-literal=MAAS_API_KEY="$val" --from-literal=api-key="$val" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  echo "secret $ns/$name applied"
}

# guard-tier detector models (granite-guardian required; Llama-Guard optional 3rd detector)
mk parasol-guardian maas-key-granite-guardian "$GUARD_KEY"
mk parasol-guardian maas-key-llama-guard      "${LLAMAGUARD_KEY:-}"
# eval judge (gpt-oss-120b) — pipeline + eval namespaces
mk parasol-build maas-key-gpt-oss-120b        "${JUDGE_KEY:-}"
mk parasol-eval  maas-key-gpt-oss-120b        "${JUDGE_KEY:-}"
# agent model (evaluated by the LMEvalJob)
mk parasol-eval  maas-key-qwen3-14b           "${AGENT_KEY:-}"
# MLflow judge in the Tekton agent-eval task (mounted as files /maas/endpoint + /maas/key)
if oc get ns parasol-build >/dev/null 2>&1 && [ -n "${JUDGE_ENDPOINT:-}" ] && [ -n "${JUDGE_KEY:-}" ]; then
  oc create secret generic maas-eval-key -n parasol-build \
    --from-literal=endpoint="$JUDGE_ENDPOINT" --from-literal=key="$JUDGE_KEY" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  echo "secret parasol-build/maas-eval-key applied (judge endpoint + key)"
fi

echo "done: per-model Secrets applied where the consuming namespace exists."
