#!/usr/bin/env bash
# showcase5.sh <topic> : evidence of Showcase 5, supply chain, signing and admission (read-only)
#   release   what runs in production: the release run, the Argo CD pin, the running pod, admission (also Showcase 1)
#   models    the model path of each portal and what it can reach
. "$(dirname "$0")/lib.sh"

case "${1:-}" in
release)
  title "1) The release run parasol-portal-release-production (parasol-build), its results"
  run "oc get pipelinerun parasol-portal-release-production -n parasol-build -o json" | python3 -c '
import sys, json
r = {x["name"]: x["value"] for x in json.load(sys.stdin).get("status", {}).get("results", [])}
for k in ("EVAL_GATE", "EVAL_SCORE", "AGENT_VERSION", "SBOM_SHA256", "PROMOTED_DIGEST"): print("  %-22s %s" % (k, r.get(k, "-")))'
  title "2) The pin on the Argo CD Application env-secured"
  run "oc get application env-secured -n openshift-gitops -o json" | python3 -c '
import sys, json; a = json.load(sys.stdin)["metadata"]["annotations"]
for k in ("promoted-digest", "promoted-by", "prompt-version", "agent-version"): print("  %-22s %s" % (k, a.get("parasol.example/" + k, "-")))'
  title "3) The running secured portal"
  run "oc get pods -n parasol-secured -l app=portal -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'" | sed 's/.*@/  image                  /'; echo
  title "4) Admission"
  echo "  namespace parasol-secured policy.rhtas.com/include=$(run "oc get ns parasol-secured -o jsonpath='{.metadata.labels.policy\\.rhtas\\.com/include}'")"
  run "oc get clusterimagepolicies.policy.sigstore.dev -o json" | python3 -c '
import sys, json
for p in json.load(sys.stdin)["items"]:
    s = p["spec"]
    print("  ClusterImagePolicy %s: images %s, accepted signers %s" % (p["metadata"]["name"],
          ", ".join(i["glob"].rsplit("/", 1)[-1] for i in s["images"]), ", ".join(a["name"] for a in s["authorities"])))' ;;
models)
  title "The model endpoint each portal calls (ConfigMap agent-config, key endpoint)"
  for ns in parasol-free parasol-secured; do
    echo "  $ns: $(run "oc get cm agent-config -n $ns -o jsonpath='{.data.endpoint}'")"
  done
  title "What each portal pod can reach (HTTP code; 000 = the connection never left the namespace)"
  for ns in parasol-free parasol-secured; do
    for u in https://api.openai.com/v1/models "https://maas.apps.$DOMAIN/v1/models"; do
      printf '  %-16s %-24s %s\n' "$ns" "$(cut -d/ -f3 <<<"$u" | cut -d. -f1-2)" \
        "$(run "oc exec -n $ns deploy/portal -- curl -s -o /dev/null -w '%{http_code}' --max-time 8 $u 2>/dev/null" || true)"
    done
  done ;;
*) usage ;;
esac
