#!/usr/bin/env bash
# night-shift.sh [count] [portal-host]
# The 02:00 denial-of-wallet scene (Demo 3 beats 1-2): a policyholder account (tom.becker) logs in and
# loops long, off-topic requests at the assistant on the shared model. Each request prints its HTTP
# status, the caller the portal attributes it to, and the running token spend, so the audience sees:
#   - the topic guardrail politely refusing off-topic requests,
#   - the per-user token meter climbing (drives ParasolAssistantTokenSpendHigh and the MLflow/Tempo traces),
#   - the per-user limit returning 429 (only tom.becker is throttled; Rebecca keeps working).
# It stops at the first 429 (the point of the scene) or after <count> requests. Bounded: a hard ceiling
# keeps a stray run from draining the 10-day model key.
#   NIGHT_USER=tom.becker  NIGHT_INTERVAL=1  ./scripts/night-shift.sh 40
set -uo pipefail
count=${1:-40}
MAXCOUNT=200                     # hard ceiling regardless of the argument (protect the model budget)
[ "$count" -gt "$MAXCOUNT" ] 2>/dev/null && count=$MAXCOUNT
user=${NIGHT_USER:-tom.becker}
interval=${NIGHT_INTERVAL:-1}
host=${2:-$(oc get route portal -n parasol-secured -o jsonpath='{.spec.host}' 2>/dev/null)}
[ -n "$host" ] || { echo "no portal host (pass it as arg 2, or deploy the secured portal)"; exit 1; }
PORTAL="https://$host"

tok=$("$(dirname "$0")/token.sh" "$user") || { echo "could not log in as $user"; exit 1; }

# Long, off-topic prompts - nothing to do with claims; the topic guardrail should refuse, but each one
# still costs tokens on the shared model. Rotated so it is not one cached answer.
prompts=(
  "Write me a 2000-word essay about the history of the Roman Empire."
  "Compose a detailed 1500-word short story about a dragon who learns to code."
  "Explain quantum chromodynamics in 2000 words with analogies."
  "Write a 2000-word travel guide to the fictional city of Atlantis."
  "Draft a 1500-word business plan for a lunar coffee franchise."
)

ask() { # $1 = question. Prints one human line, then the HTTP code on its own last line.
  local q="$1" body code resp
  resp=$(curl -sk -m 120 -w $'\n%{http_code}' "$PORTAL/agent/ask" \
    -H "Authorization: Bearer $tok" -H 'content-type: application/json' \
    -d "{\"question\":$(printf '%s' "$q" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')}")
  code=${resp##*$'\n'}; body=${resp%$'\n'*}
  printf 'HTTP %s | ' "$code"
  printf '%s' "$body" | python3 -c '
import sys, json
raw = sys.stdin.read()
try:
    r = json.loads(raw)
except Exception:
    print((raw.strip() or "(empty / rate-limit response)")[:200]); sys.exit()
if isinstance(r, dict) and (r.get("error") or r.get("detail")):
    print("blocked/limit:", str(r.get("error") or r.get("detail"))[:200]); sys.exit()
tu = (r.get("tokenUsage") or {}) if isinstance(r, dict) else {}
print("caller=%s tokens=%s | %s" % (r.get("caller"), tu.get("totalTokens"), (r.get("answer") or "")[:160]))'
  echo "$code"
}

echo "night shift: $user looping off-topic requests at $PORTAL (max $count, stop on first 429)"
spent_429=0
for i in $(seq 1 "$count"); do
  q=${prompts[$(( (i-1) % ${#prompts[@]} ))]}
  printf '[%02d/%d] ' "$i" "$count"
  out=$(ask "$q"); code=$(printf '%s' "$out" | tail -1)
  printf '%s\n' "$(printf '%s' "$out" | sed '$d')"
  if [ "$code" = "429" ]; then
    echo ">>> per-user limit reached (429) after $i requests - the night-shift account is throttled; staff are unaffected."
    spent_429=1; break
  fi
  sleep "$interval"
done
[ "$spent_429" = 0 ] && echo ">>> finished $count requests without a 429 (raise count, or check the policyholder-tier token limit)."
