#!/usr/bin/env bash
# results-prune.sh <namespace> <pipelinerun-name>... : delete the Tekton Results archive (result and records) of
# earlier PipelineRuns with these names, keeping the live run's. The guide's runs reuse fixed names; the console merges
# archived TaskRuns of a same-name run into the current graph (an old failed promote shows as failed).
# Called by pipeline-runs.sh and tool-rugpull.sh before they re-create a named run. Permanent; a missing Results API
# is skipped (nothing to prune).
set -euo pipefail
ns="${1:?usage: $0 <namespace> <pipelinerun-name>...}"; shift
oc get svc tekton-results-api-service -n openshift-pipelines >/dev/null 2>&1 || exit 0
port=$((20000 + RANDOM % 20000))
oc port-forward -n openshift-pipelines svc/tekton-results-api-service "$port:8080" >/dev/null 2>&1 & pf=$!
trap 'kill $pf 2>/dev/null' EXIT
for _ in $(seq 1 20); do curl -sk -o /dev/null "https://localhost:$port" && break; sleep 0.5; done
api="https://localhost:$port/apis/results.tekton.dev/v1alpha2/parents/$ns/results"
token=$(oc whoami -t)
for name in "$@"; do
  live=$(oc get pipelinerun "$name" -n "$ns" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
  uids=$(curl -skf -G -H "Authorization: Bearer $token" "$api/-/records" --data-urlencode page_size=200 \
      --data-urlencode "filter=data.metadata.name == '$name' || data.metadata.labels['tekton.dev/pipelineRun'] == '$name'" \
    | python3 -c 'import json,sys
print(" ".join(sorted({r["name"].split("/")[2] for r in json.load(sys.stdin).get("records", [])} - {sys.argv[1]})))' "$live")
  n=0
  for uid in $uids; do
    curl -skf -o /dev/null -X DELETE -H "Authorization: Bearer $token" "$api/$uid" && n=$((n + 1))
  done
  echo " results-prune: $name: $n archived run(s) deleted"
done
