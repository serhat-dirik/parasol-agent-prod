#!/usr/bin/env bash
# Put each per-model key (install contract env, see bootstrap.sh) into its OWN cluster Secret, in the
# namespaces that consume it. Idempotent; key values are never printed or committed.
# Usage: scripts/maas-model-keys.sh   (with AGENT_/GUARD_/JUDGE_[/LLAMAGUARD_] ENDPOINT+KEY exported)
set -euo pipefail
JUDGE_MODEL="${JUDGE_MODEL:-gpt-oss-120b}"
# Secret name from the judge model id, DNS-1123 (as bootstrap.sh derives GUARD_MODEL_NAME); default: maas-key-gpt-oss-120b
JUDGE_SECRET="maas-key-$(printf '%s' "$JUDGE_MODEL" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | cut -c1-54 | sed -E 's/^-+|-+$//g')"
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
mk parasol-guardian maas-key-guard           "$GUARD_KEY"
mk parasol-guardian maas-key-llama-guard      "${LLAMAGUARD_KEY:-}"
# eval judge (JUDGE_MODEL) — pipeline + eval namespaces
mk parasol-build "$JUDGE_SECRET"              "${JUDGE_KEY:-}"
mk parasol-eval  "$JUDGE_SECRET"              "${JUDGE_KEY:-}"
# agent model (evaluated by the LMEvalJob)
mk parasol-eval  maas-key-agent           "${AGENT_KEY:-}"
# MLflow judge in the Tekton agent-eval task (mounted as files /maas/endpoint + /maas/key + /maas/model).
# Only a first-install fallback: scripts/maas-eval-key.sh replaces it with a MaaS key (judge metered on
# subscription parasol-eval) and this script never overwrites an existing one.
if oc get ns parasol-build >/dev/null 2>&1 && [ -n "${JUDGE_ENDPOINT:-}" ] && [ -n "${JUDGE_KEY:-}" ] \
   && ! oc get secret maas-eval-key -n parasol-build >/dev/null 2>&1; then
  oc create secret generic maas-eval-key -n parasol-build \
    --from-literal=endpoint="$JUDGE_ENDPOINT" --from-literal=key="$JUDGE_KEY" --from-literal=model="$JUDGE_MODEL" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  echo "secret parasol-build/maas-eval-key applied (direct judge endpoint + key + model $JUDGE_MODEL, until maas-eval-key.sh)"
fi

echo "done: per-model Secrets applied where the consuming namespace exists."
