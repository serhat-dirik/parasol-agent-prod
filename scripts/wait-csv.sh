#!/usr/bin/env bash
# wait-csv.sh <namespace> <package-substring> : poll the operator CSV phase every 20 s, printing it,
# until Succeeded. Deadline 15 min (expected 2-10 min + 50%). Exit 1 on Failed or deadline.
ns=$1; pkg=$2
for i in $(seq 1 45); do
  phase=$(oc get csv -n "$ns" -o custom-columns=N:.metadata.name,P:.status.phase --no-headers 2>/dev/null | awk -v p="$pkg" 'index(tolower($1),tolower(p)){print $2; exit}')
  echo "$(date +%T) $pkg in $ns: ${phase:-no CSV yet}"
  [ "$phase" = Succeeded ] && exit 0
  [ "$phase" = Failed ] && { oc get csv -n "$ns" -o jsonpath='{range .items[?(@.status.phase=="Failed")]}{.metadata.name}: {.status.reason} {.status.message}{"\n"}{end}'; exit 1; }
  sleep 20
done
echo "deadline: $pkg in $ns not Succeeded after 15 min"; exit 1
