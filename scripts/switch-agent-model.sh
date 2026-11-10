#!/usr/bin/env bash
# Switch the agent model (the model both portals run) on an installed cluster, without reinstalling.
#   scripts/switch-agent-model.sh <model-id> [--endpoint URL] [--free-only] [--dry-run]
#     <model-id>     upstream model id at the endpoint (AGENT_MODEL), e.g. llama-scout-17b
#     --endpoint     OpenAI-compatible base URL ending in /v1 (AGENT_ENDPOINT); default: install.env, else the current one
#     --free-only    switch only the unsecured portal (parasol-free); the secured side keeps the released model
#     --dry-run      print what would change, change nothing
#   AGENT_KEY (environment or install.env) is the endpoint's API key; needed only when the key changes. Never printed.
#
# Full switch (default), in the order bootstrap.sh uses:
#   1 upstream key Secrets: maas-upstream-agent (MaaS) and parasol-free/maas-credentials (free portal)
#   2 the Argo CD Applications that carry the agent model, rendered from gitops/bootstrap/apps exactly as bootstrap does
#     (platform-rhoai: MaaS ExternalModel/MaaSModelRef renamed to the new model, the old ones pruned; env-free and
#     env-secured: agent-config model; platform-guardrails and platform-guardrails-nemo: MaaS URL and NeMo judge model)
#   3 the guard tier's subscriptions (gitops/platform/maas-tiers, applied by bootstrap, not by Argo)
#   4 the release evaluation's model (Secret parasol-build/maas-eval-agent-key: model + endpoint; same key)
#   5 portal restarts (they read the model from agent-config at start-up), then AGENT_MODEL/AGENT_ENDPOINT in
#     install.env, so a later ./bootstrap.sh keeps the switch
# Not covered (backlog item 6, release side): the secured portal switches at once, before a release evaluated the new
# model; the release gate's model-alone bar (env-secured parasol.example/model-only-baseline) was measured on the
# previous model, so the first release on the new model can fail that condition.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
NEW_MODEL="" NEW_ENDPOINT="" FREE_ONLY=0 DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --endpoint) NEW_ENDPOINT="${2:?}"; shift 2;;
    --free-only) FREE_ONLY=1; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) usage;;
    -*) usage;;
    *) [ -z "$NEW_MODEL" ] || usage; NEW_MODEL="$1"; shift;;
  esac
done
[ -n "$NEW_MODEL" ] || usage

ENVF="${INSTALL_ENV:-install.env}"
if [ -f "$ENVF" ]; then set -a; . "./${ENVF#./}"; set +a; fi
for t in oc kustomize envsubst python3 curl; do command -v $t >/dev/null || { echo "$t is required" >&2; exit 1; }; done

# Same derivations as bootstrap.sh
dns_name() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | cut -c1-63 | sed -E 's/^-+|-+$//g'; }
host() { echo "$1" | sed -E 's#https?://([^/:]+).*#\1#'; }
port() { local p; p="$(echo "$1" | sed -nE 's#https?://[^/:]+:([0-9]+).*#\1#p')"; echo "${p:-443}"; }
cmval() { oc get cm agent-config -n "$1" -o jsonpath="{.data.$2}" 2>/dev/null || true; }

OLD_MODEL=$(cmval parasol-free model); OLD_ENDPOINT=$(cmval parasol-free endpoint)
[ -n "$OLD_MODEL" ] || { echo "parasol-free/agent-config not found: is the demo installed?" >&2; exit 1; }
export AGENT_MODEL="$NEW_MODEL"
export AGENT_ENDPOINT="${NEW_ENDPOINT:-${AGENT_ENDPOINT:-$OLD_ENDPOINT}}"
export AGENT_MODEL_NAME="$(dns_name "$AGENT_MODEL")" AGENT_HOST="$(host "$AGENT_ENDPOINT")" AGENT_PORT="$(port "$AGENT_ENDPOINT")"
OLD_NAME="$(dns_name "$OLD_MODEL")"
SECURED_MODEL=$(cmval parasol-secured model)

echo "agent model: $OLD_MODEL @ $(host "$OLD_ENDPOINT")  ->  $AGENT_MODEL @ $AGENT_HOST (MaaS name $AGENT_MODEL_NAME)"
echo "scope: $([ $FREE_ONLY = 1 ] && echo 'free portal only' || echo 'whole installation')$([ $DRY = 1 ] && echo ', dry run')"
if [ "$AGENT_MODEL" = "$OLD_MODEL" ] && [ "$AGENT_ENDPOINT" = "$OLD_ENDPOINT" ] && { [ $FREE_ONLY = 1 ] || [ "$SECURED_MODEL" = "$AGENT_MODEL" ]; }; then
  echo "nothing to change"; exit 0
fi

# Preflight: the endpoint lists the model (needs the key; skipped without it).
if [ -n "${AGENT_KEY:-}" ]; then
  if curl -skf -m 20 -H "Authorization: Bearer $AGENT_KEY" "${AGENT_ENDPOINT%/}/models" -o /tmp/parasol-models.$$; then
    python3 - "$AGENT_MODEL" /tmp/parasol-models.$$ <<'PY' || { rm -f /tmp/parasol-models.$$; exit 1; }
import json, sys
ids = [m.get("id") for m in json.load(open(sys.argv[2])).get("data", [])]
if sys.argv[1] not in ids:
    sys.exit(f"the endpoint does not list {sys.argv[1]}; it lists: {', '.join(i for i in ids if i)}")
print(f"preflight: the endpoint lists {sys.argv[1]}")
PY
    rm -f /tmp/parasol-models.$$
  else
    echo "WARN: could not list the endpoint's models (key or URL wrong?); continuing"
  fi
else
  echo "WARN: AGENT_KEY not set: no preflight, and the key Secrets are left as they are (same key assumed)"
fi

run() { if [ $DRY = 1 ]; then echo "  [dry run] $*"; else "$@"; fi; }
apply() { if [ $DRY = 1 ]; then oc apply --dry-run=server -f - | sed 's/^/  [dry run] /'; else oc apply -f -; fi; }

# The Argo CD Applications, rendered as bootstrap.sh renders them; the values bootstrap had are read from the cluster.
export CLUSTER_DOMAIN="$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')"
export REPO_URL="$(oc get application env-free -n openshift-gitops -o jsonpath='{.spec.source.repoURL}')"
export REPO_REVISION="$(oc get application env-free -n openshift-gitops -o jsonpath='{.spec.source.targetRevision}')"
realm=$(oc get application env-secured -n openshift-gitops -o json | python3 -c '
import json, sys, yaml
for p in json.load(sys.stdin)["spec"]["source"]["kustomize"].get("patches", []):
    for op in yaml.safe_load(p["patch"]) or []:
        if op.get("path") == "/data/realmUrl": print(op["value"])')
export KEYCLOAK_INTERNAL_URL="${KEYCLOAK_INTERNAL_URL:-${realm%/realms/parasol}}"
export JUDGE_MODEL="${JUDGE_MODEL:-gpt-oss-120b}"; export JUDGE_MODEL_NAME="$(dns_name "$JUDGE_MODEL")"
export JUDGE_HOST="${JUDGE_HOST:-$(host "${JUDGE_ENDPOINT:-$(oc get externalmodel "$JUDGE_MODEL_NAME" -n models-as-a-service -o jsonpath='https://{.spec.endpoint}/v1')}")}"
APPS_ENV='$CLUSTER_DOMAIN $REPO_URL $REPO_REVISION $AGENT_ENDPOINT $AGENT_MODEL $AGENT_MODEL_NAME $AGENT_HOST $AGENT_PORT $JUDGE_MODEL $JUDGE_MODEL_NAME $JUDGE_HOST $KEYCLOAK_INTERNAL_URL'
for v in CLUSTER_DOMAIN REPO_URL REPO_REVISION KEYCLOAK_INTERNAL_URL JUDGE_HOST; do
  [ -n "${!v}" ] || { echo "could not determine $v (set it, or put it in $ENVF)" >&2; exit 1; }
done
if [ $FREE_ONLY = 1 ]; then APPS="env-free"
else APPS="env-free env-secured platform-rhoai platform-guardrails platform-guardrails-nemo"; fi

echo "== 1 keys"
if [ -n "${AGENT_KEY:-}" ]; then
  oc -n parasol-free create secret generic maas-credentials --from-literal=GENAI_API_KEY="$AGENT_KEY" \
    --dry-run=client -o yaml | apply >/dev/null
  if [ $FREE_ONLY = 0 ]; then
    oc -n models-as-a-service create secret generic maas-upstream-agent --from-literal=api-key="$AGENT_KEY" \
      --dry-run=client -o yaml | apply >/dev/null
    run oc -n models-as-a-service label secret maas-upstream-agent inference.llm-d.ai/ipp-managed=true --overwrite >/dev/null
  fi
  echo "key Secrets written"
else
  echo "unchanged (no AGENT_KEY)"
fi

echo "== 2 Argo CD Applications: $APPS"
kustomize build gitops/bootstrap/apps | envsubst "$APPS_ENV" | python3 -c '
import sys, yaml
keep = set(sys.argv[1].split())
docs = [d for d in yaml.safe_load_all(sys.stdin) if d and d.get("kind") == "Application" and d["metadata"]["name"] in keep]
missing = keep - {d["metadata"]["name"] for d in docs}
if missing: sys.exit("not in gitops/bootstrap/apps: " + ", ".join(sorted(missing)))
print(yaml.safe_dump_all(docs, sort_keys=False))' "$APPS" | apply
for a in $APPS; do run oc annotate application "$a" -n openshift-gitops argocd.argoproj.io/refresh=normal --overwrite >/dev/null; done

if [ $FREE_ONLY = 0 ]; then
  echo "== 3 guard tier subscriptions (gitops/platform/maas-tiers)"
  if [ -n "${GUARD_ENDPOINT:-}" ]; then
    export GUARD_MODEL="${GUARD_MODEL:-granite-guardian-3-1-8b}"; export GUARD_MODEL_NAME="$(dns_name "$GUARD_MODEL")" GUARD_HOST="$(host "$GUARD_ENDPOINT")"
    kustomize build gitops/platform/maas-tiers | envsubst '$GUARD_HOST $GUARD_MODEL $GUARD_MODEL_NAME $AGENT_MODEL_NAME' | apply
  else   # no install.env: rename the agent model in the live tier objects' modelRefs
    for o in maassubscription/parasol-tier-prod maassubscription/parasol-tier-guard maasauthpolicy/parasol-tier-access; do
      oc get "$o" -n models-as-a-service -o json | python3 -c '
import json, sys
o = json.load(sys.stdin); old, new = sys.argv[1], sys.argv[2]
for m in o["spec"].get("modelRefs", []):
    if m.get("name") == old: m["name"] = new
for k in ("resourceVersion", "uid", "creationTimestamp", "generation", "managedFields"): o["metadata"].pop(k, None)
o.pop("status", None); print(json.dumps(o))' "$OLD_NAME" "$AGENT_MODEL_NAME" | apply
    done
  fi

  echo "== 4 release evaluation model (parasol-build/maas-eval-agent-key)"
  if oc get secret maas-eval-agent-key -n parasol-build >/dev/null 2>&1; then
    GW=https://maas-default-gateway-openshift-default.openshift-ingress.svc.cluster.local
    data=$(python3 -c 'import base64, json, sys; print(json.dumps({"data": {"model": base64.b64encode(sys.argv[1].encode()).decode(),
      "endpoint": base64.b64encode(sys.argv[2].encode()).decode()}}))' "$AGENT_MODEL_NAME" "$GW/models-as-a-service/$AGENT_MODEL_NAME/v1")
    run oc patch secret maas-eval-agent-key -n parasol-build --type merge -p "$data" >/dev/null
    echo "eval model: $AGENT_MODEL_NAME (same parasol-eval key)"
  else
    echo "not present (scripts/maas-eval-key.sh creates it)"
  fi
fi

echo "== 5 roll out"
if [ $DRY = 0 ]; then
  for i in $(seq 1 30); do   # wait (5 min) until Argo applied the new agent-config
    f=$(cmval parasol-free model); s=$(cmval parasol-secured model)
    [ "$f" = "$AGENT_MODEL" ] && { [ $FREE_ONLY = 1 ] || [ "$s" = "$AGENT_MODEL" ]; } && break
    echo "$(date +%T) waiting for Argo CD to sync agent-config (free: $f, secured: $s)"; sleep 10
  done
fi
run oc rollout restart deploy/portal -n parasol-free >/dev/null
[ $FREE_ONLY = 1 ] || run oc rollout restart deploy/portal -n parasol-secured >/dev/null
echo "portals restarted; guardrails-proxy and NeMo roll out when Argo CD applies their changed spec"
if [ $FREE_ONLY = 0 ] && [ $DRY = 0 ] && [ -f "$ENVF" ]; then
  setvar() { if grep -q "^$1=" "$ENVF"; then sed -i.bak "s#^$1=.*#$1=\"$2\"#" "$ENVF" && rm -f "$ENVF.bak"; else printf '%s="%s"\n' "$1" "$2" >> "$ENVF"; fi; }
  setvar AGENT_MODEL "$AGENT_MODEL"; setvar AGENT_ENDPOINT "$AGENT_ENDPOINT"
  echo "$ENVF: AGENT_MODEL and AGENT_ENDPOINT updated (a later ./bootstrap.sh keeps the switch)"
fi

cat <<EOF

Done: agent model $AGENT_MODEL$([ $FREE_ONLY = 1 ] && echo ' (free portal only)').
Next:
  - scripts/regression.sh            the showcases on the new model (the unsecured beats need tool calls, and
                                     Showcase 2's payout needs a model that follows the injected note)
$([ $FREE_ONLY = 1 ] || echo "  - RERUN=1 scripts/pipeline-runs.sh --wait   evaluate a release on the new model. The model-alone bar was
                                     measured on $OLD_MODEL: a gate failure on that condition is expected
                                     until the release side handles a model change (backlog item 6)")
  - back: scripts/switch-agent-model.sh $OLD_MODEL$([ "$(host "$OLD_ENDPOINT")" = "$AGENT_HOST" ] || echo " --endpoint $OLD_ENDPOINT")$([ $FREE_ONLY = 1 ] && echo ' --free-only')
EOF
