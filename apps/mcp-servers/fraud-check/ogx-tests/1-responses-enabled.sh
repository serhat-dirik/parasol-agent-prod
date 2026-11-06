#!/usr/bin/env bash
# 1. The Responses API is switched on and answers through MaaS (inference provider remote::openai -> MaaS).
# Expected:
#   providers: inference=echo,maas responses=builtin tool_runtime=model-context-protocol
#   PASS  responses enabled: status completed, model maas/qwen3-14b
set -uo pipefail
. "$(dirname "$0")/lib.sh"
curl -s "$OGX/v1/providers" | python3 -c 'import json,sys
d={}
for p in json.load(sys.stdin)["data"]: d.setdefault(p["api"], []).append(p["provider_id"])
print("providers: inference=%s responses=%s tool_runtime=%s" % tuple(",".join(sorted(d.get(a, []))) for a in ("inference", "responses", "tool_runtime")))'
r=$(curl -s "$OGX/v1/responses" -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"input\":\"Reply with the single word OK. /no_think\",\"store\":true}")
st=$(printf '%s' "$r" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r.get("status"), r.get("model"))' 2>/dev/null)
[ "${st%% *}" = completed ] && pass "responses enabled: status completed, model ${st#* }" || fail "responses: $r"
