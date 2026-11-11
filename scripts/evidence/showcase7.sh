#!/usr/bin/env bash
# showcase7.sh <topic> : evidence of Showcase 7, third-party tools (read-only)
#   onboarding   the onboarding runs of the partner bank's versions: verdict, findings, built, promoted
#   tools        the MCP servers the secured agent reaches, the onboarded version, and the unsecured shortcut
#   scan         the runtime tool scanner's latest verdict per server: pinned, drifted, flagged
#   payouts [claim]  the latest claims-db payout record of both portals (showcase1.sh payouts)
. "$(dirname "$0")/lib.sh"

case "${1:-}" in
onboarding)
  title "The bank's releases (parasol-build; standing in for the bank's registry)"
  run "oc get istag currency-converter:1.4.2 currency-converter:1.4.3 currency-converter:latest -n parasol-build -o custom-columns='TAG:.metadata.name,DIGEST:.image.metadata.name'"
  title "Onboarding runs (pipeline parasol-tool-onboarding)"
  run "oc get pipelinerun -n parasol-build -l tekton.dev/pipeline=parasol-tool-onboarding -o json" | python3 -c '
import sys, json
for p in json.load(sys.stdin)["items"]:
    r = {x["name"]: x["value"] for x in p.get("status", {}).get("results", [])}
    sk = [t["name"] for t in p.get("status", {}).get("skippedTasks", [])]
    print("  %-50s gate=%-8s findings=%-2s built=%-4s promoted=%s" % (p["metadata"]["name"], r.get("GATE", "?"),
          r.get("FINDINGS", "?"), "no" if "build-onboarded-image" in sk else "yes", (r.get("PROMOTED_DIGEST") or "-")[7:19] or "-"))'
  title "What the secured side runs (Argo CD Application env-secured-tools)"
  run "oc get application env-secured-tools -n openshift-gitops -o json" | python3 -c '
import sys, json; a = json.load(sys.stdin)["metadata"]["annotations"]
for k in ("onboarded-version", "onboarded-digest", "onboarded-tools-sha256", "onboarded-by"): print("  %-24s %s" % (k, a.get("parasol.example/" + k, "-")))'
  title "Parasol's onboarded image: Tekton Chains' keyless signature and provenance on the onboarded digest"
  img="image-registry.openshift-image-registry.svc:5000/parasol-build/currency-converter@$(oc get application env-secured-tools -n openshift-gitops -o jsonpath='{.metadata.annotations.parasol\.example/onboarded-digest}')"
  run "oc get --raw /apis/image.openshift.io/v1/namespaces/parasol-build/imagestreams/currency-converter | python3 -c 'import sys,json; print(\"  signature/attestation tags:\", sorted(t[\"tag\"][:16] + \"...\" + t[\"tag\"][-4:] for t in json.load(sys.stdin)[\"status\"].get(\"tags\", []) if t[\"tag\"].endswith((\".sig\", \".att\"))) or \"none (registry tags not listed here)\")'" || true
  note "  verify yourself: cosign verify --certificate-identity spiffe://parasol-demo/ns/openshift-pipelines/sa/tekton-chains-controller --certificate-oidc-issuer https://oidc-discovery.apps.$DOMAIN --rekor-url https://rekor-server-trusted-artifact-signer.apps.$DOMAIN --allow-insecure-registry $img" ;;
tools)
  title "MCP servers the gateway federates for the secured agent (MCPServerRegistration, parasol-secured)"
  run "oc get mcpserverregistration -n parasol-secured" | sed 's/^/  /'
  echo "  currency-converter runs as onboarded: $(run "oc get application env-secured-tools -n openshift-gitops -o jsonpath='{.metadata.annotations.parasol\\.example/onboarded-version}' 2>/dev/null")"
  title "Can a portal reach the bank's service as published (currency-converter.parasol-thirdparty) directly?"
  for ns in parasol-secured parasol-free; do
    run "oc exec -n $ns deploy/portal -- timeout 5 bash -c '</dev/tcp/currency-converter.parasol-thirdparty.svc/8080' 2>/dev/null" \
      && echo "  $ns: reachable" || echo "  $ns: blocked"
  done ;;
scan)
  title "The runtime tool scanner's latest verdict per MCP server (mcp-system/mcp-tool-scanner)"
  # the scanner logs only changes: replay its log to the current state per server
  run "oc logs -n mcp-system deploy/mcp-tool-scanner --tail=-1 2>/dev/null | grep tool-scan" | python3 -c '
import sys, re
last, flags = {}, {}
for l in sys.stdin:
    m = re.search(r"tool-scan action=(\w+) server=(\S+) registered=(\S+)(.*)", l)
    if not m: continue
    act, srv, reg, rest = m.groups(); kv = dict(re.findall(r"(\w+)=(\x27[^\x27]*\x27|\S+)", rest))
    if act == "scanned":
        last[srv] = "registered=%s version=%s pin=%s" % (reg, kv.get("version"), kv.get("pin"))
    elif act == "drift":
        last[srv] = "registered=%s version=%s DRIFT pinned=%s current=%s" % (reg, kv.get("version"), kv.get("pinned", "")[:8], kv.get("current", "")[:8])
    elif act == "flag":
        flags[(srv, kv.get("tool"), kv.get("rule"))] = 1
    elif act == "cleared":
        flags.pop((srv, kv.get("tool"), kv.get("rule")), None)
for s in sorted(last): print("  %-40s %s" % (s, last[s]))
print("Descriptions with instructions for the assistant (open findings):")
for s, t, r in sorted(flags): print("  %-40s %-18s %s" % (s, t, r))
if not flags: print("  none")' ;;
payouts) exec "$EV/showcase1.sh" payouts "${2:-}" ;;
*) usage ;;
esac
