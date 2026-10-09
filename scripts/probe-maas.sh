#!/usr/bin/env bash
# Does this model, on this endpoint, emit STRUCTURED tool calls? Run for each candidate model.
# PASS = finish_reason "tool_calls" and a tool_calls array. FAIL = the call narrated in content.
set -euo pipefail
: "${MAAS_ENDPOINT:?}"; : "${MAAS_API_KEY:?}"
for m in ${*:-llama-scout-17b qwen3-14b qwen3-235b}; do
  printf '%-22s' "$m"
  curl -sk "$MAAS_ENDPOINT/chat/completions" -H "Authorization: Bearer $MAAS_API_KEY" -H 'content-type: application/json' -d "{
    \"model\": \"$m\", \"temperature\": 0,
    \"messages\": [{\"role\":\"system\",\"content\":\"You are a claims assistant. Use tools instead of guessing.\"},{\"role\":\"user\",\"content\":\"What is the status of claim CLM-1001?\"}],
    \"tools\": [{\"type\":\"function\",\"function\":{\"name\":\"get_claim\",\"description\":\"Look up a claim by number, e.g. CLM-1001\",\"parameters\":{\"type\":\"object\",\"properties\":{\"claimNumber\":{\"type\":\"string\"}},\"required\":[\"claimNumber\"]}}}]}" \
  | python3 -c 'import sys,json
try:
  r=json.load(sys.stdin); c=r["choices"][0]
  tc=c["message"].get("tool_calls"); print("PASS structured tool call:", tc[0]["function"]) if tc else print("FAIL finish_reason=%s content=%r" % (c.get("finish_reason"), (c["message"].get("content") or "")[:120]))
except Exception as e: print("ERROR", e)'
done
