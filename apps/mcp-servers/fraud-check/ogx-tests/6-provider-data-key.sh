#!/usr/bin/env bash
# 6. Per-user MaaS key: X-OGX-Provider-Data {"openai_api_key": ...} replaces the server's key for one request.
# The contractor tier key (from the lab Secret, never printed) answers; an invalid key is refused by MaaS,
# which proves the header's key, not the server's, reached MaaS. The key is not stored with the response.
# Expected:
#   server key:      completed
#   contractor key:  completed
#   invalid key:     refused (HTTP 500; the OGX log shows MaaS answered 401)
#   key stored with the response: False
#   PASS  per-request MaaS key via X-OGX-Provider-Data
set -uo pipefail
. "$(dirname "$0")/lib.sh"
OGX="$OGX" MODEL="$MODEL" NS="$NS" python3 -I - <<'PY'
import base64, json, os, subprocess, sys, urllib.request, urllib.error
ogx, model = os.environ["OGX"], os.environ["MODEL"]
sec = json.loads(subprocess.check_output(["oc", "get", "secret", "ogx-lab-maas", "-n", os.environ["NS"], "-o", "json"]))["data"]
contractor = base64.b64decode(sec["CONTRACTOR_MAAS_KEY"]).decode()
def ask(key):
    h = {"content-type": "application/json"}
    if key is not None:
        h["X-OGX-Provider-Data"] = json.dumps({"openai_api_key": key})
    body = json.dumps({"model": model, "input": "Reply with OK. /no_think", "store": True}).encode()
    try:
        r = json.load(urllib.request.urlopen(urllib.request.Request(ogx + "/v1/responses", body, h), timeout=120))
        return r["status"], r["id"]
    except urllib.error.HTTPError as e:
        return "refused (HTTP %d)" % e.code, None
s, _ = ask(None); print("server key:     ", s)
c, cid = ask(contractor); print("contractor key: ", c)
b, _ = ask("not-a-valid-key"); print("invalid key:    ", b)
stored = urllib.request.urlopen(ogx + "/v1/responses/" + cid).read().decode() if cid else ""
leak = contractor in stored; print("key stored with the response:", leak)
ok = s == "completed" and c == "completed" and b.startswith("refused") and not leak
print(("PASS  per-request MaaS key via X-OGX-Provider-Data") if ok else "FAIL  see above"); sys.exit(0 if ok else 1)
PY
