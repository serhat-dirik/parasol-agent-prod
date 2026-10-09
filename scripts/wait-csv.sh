#!/usr/bin/env bash
# wait-csv.sh <namespace> <package-substring>  : wait until the operator CSV reports Succeeded
ns=$1; pkg=$2; t=0
until oc get csv -n "$ns" 2>/dev/null | grep -i "$pkg" | grep -q Succeeded; do
  sleep 10; t=$((t+10)); [ $t -ge 900 ] && { echo "timeout waiting for $pkg in $ns"; exit 1; }
done
echo "$pkg ready in $ns"
