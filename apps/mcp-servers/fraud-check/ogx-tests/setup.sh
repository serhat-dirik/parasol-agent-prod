#!/usr/bin/env bash
# Stand up the test OGX server for checks 1-6 in namespace parasol-ogx-lab; `setup.sh delete` removes it all.
# The MaaS keys are copied from parasol-secured (agent key + the portal's staff and contractor keys) with oc,
# never printed. No other namespace is changed.
set -euo pipefail
NS=${OGX_LAB_NS:-parasol-ogx-lab}
if [ "${1:-}" = delete ]; then oc delete namespace "$NS" --wait=false; exit 0; fi
oc get namespace "$NS" >/dev/null 2>&1 || oc create namespace "$NS"
python3 -I - "$NS" <<'PY'
import json, subprocess, sys
get = lambda n: json.loads(subprocess.check_output(["oc", "get", "secret", n, "-n", "parasol-secured", "-o", "json"]))["data"]
a, p = get("maas-credentials"), get("maas-portal-keys")
data = {"OPENAI_API_KEY": a["GENAI_API_KEY"], "STAFF_MAAS_KEY": p["STAFF_MAAS_KEY"], "CONTRACTOR_MAAS_KEY": p["CONTRACTOR_MAAS_KEY"]}
obj = {"apiVersion": "v1", "kind": "Secret", "type": "Opaque", "data": data,
       "metadata": {"name": "ogx-lab-maas", "namespace": sys.argv[1]}}
subprocess.run(["oc", "apply", "-f", "-"], input=json.dumps(obj).encode(), check=True)
PY
oc apply -n "$NS" -f "$(dirname "$0")/lab.yaml"
oc rollout status -n "$NS" deploy/ogx-echo --timeout=300s
for _ in $(seq 1 30); do oc get deploy/ogx-lab -n "$NS" >/dev/null 2>&1 && break; sleep 5; done
oc rollout status -n "$NS" deploy/ogx-lab --timeout=300s
