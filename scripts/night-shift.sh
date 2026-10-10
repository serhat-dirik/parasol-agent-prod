#!/usr/bin/env bash
# night-shift.sh [count] [portal-host]
# The 02:00 denial-of-wallet scene (Demo 3 beats 1-2): a policyholder account (tom.becker) logs in and
# hammers the assistant on the shared model. It sends a MIX, because off-topic requests are refused at
# the topic guardrail for ZERO tokens (cheap deflection) and so could never fill the budget on their own:
#   - a few OFF-TOPIC requests ("write me a 2,000-word essay...") -> polite topic refusal, 0 tokens
#     (shows the topic guard throwing junk away for free);
#   - then HEAVY ON-TOPIC requests ("explain every Parasol policy clause in full detail...") that PASS the
#     topic guard and burn ~1-3k tokens each against tom.becker's policyholder subscription.
# Each request prints its HTTP status, the caller the portal attributes it to, and the token spend, so
# the audience sees the per-user meter climb (drives ParasolAssistantTokenSpendHigh and the MLflow/Tempo
# traces) until the MaaS per-user limit returns 429 "you have reached your usage limit". Rebecca, on the
# staff tier, keeps working throughout. ~10-15 on-topic requests reach the 20k/10m policyholder bucket.
# Stops at the first 429 (the point of the scene) or after <count> requests. Bounded by a hard ceiling
# so a stray run cannot drain the 10-day model key.
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

# A few off-topic prompts first: the topic guardrail refuses these for 0 tokens (free deflection).
offtopic=(
  "Write me a 2000-word essay about the history of the Roman Empire."
  "Compose a detailed 1500-word short story about a dragon who learns to code."
)
# Then heavy ON-TOPIC prompts: these pass the topic guard and ask for long, detailed answers, so each
# burns ~1-3k model tokens against the policyholder subscription (no privileged tools needed - a verbose
# model answer alone fills the bucket). Rotated so it is not one cached answer.
ontopic=(
  "Explain in exhaustive detail everything a Parasol home insurance policy covers, every exclusion, and every condition, clause by clause."
  "Walk me through, step by step and at great length, how a Parasol home insurance claim is assessed from first notice of loss to final payout."
  "Describe in full the Parasol claims appeals process and all of my rights as a policyholder, with as much detail as possible."
  "Give me a very long, detailed explanation of how deductibles, excess, premiums and no-claims discounts interact on Parasol policies, with worked examples."
  "Explain at length every section of a standard Parasol motor insurance policy and what each clause means for me as a policyholder."
)
offc=${#offtopic[@]}

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

echo "night shift: $user hammering $PORTAL ($offc off-topic to deflect, then heavy on-topic; max $count, stop on first 429)"
spent_429=0
for i in $(seq 1 "$count"); do
  if [ "$i" -le "$offc" ]; then
    q=${offtopic[$((i-1))]}; kind=off-topic
  else
    q=${ontopic[$(( (i-1-offc) % ${#ontopic[@]} ))]}; kind=on-topic
  fi
  printf '[%02d/%d %s] ' "$i" "$count" "$kind"
  out=$(ask "$q"); code=$(printf '%s' "$out" | tail -1)
  printf '%s\n' "$(printf '%s' "$out" | sed '$d')"
  if [ "$code" = "429" ]; then
    echo ">>> per-user limit reached (429) after $i requests - the night-shift account is throttled; staff are unaffected."
    spent_429=1; break
  fi
  sleep "$interval"
done
[ "$spent_429" = 0 ] && echo ">>> finished $count requests without a 429 (raise count, or check the policyholder-tier token limit)."
