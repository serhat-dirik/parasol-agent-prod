#!/usr/bin/env bash
# Enable the OpenShift console plugins the demo shows (idempotent): the Pipelines plugin gives the
# PipelineRun graph and task logs for the supply-chain beat; the Connectivity Link plugin (kuadrant) gives the
# gateways, routes, AuthPolicy/RateLimitPolicy and topology views. Usage: scripts/console-plugins.sh [plugin...]
set -euo pipefail
plugins=("$@"); [ $# -gt 0 ] || plugins=(pipelines-console-plugin kuadrant-console-plugin)
for p in "${plugins[@]}"; do
  oc get consoleplugin "$p" >/dev/null 2>&1 || { echo "skip $p (not installed)"; continue; }
  if oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' | grep -q "\"$p\""; then
    echo "$p already enabled"
  else
    oc patch consoles.operator.openshift.io cluster --type json -p "[{\"op\":\"add\",\"path\":\"/spec/plugins/-\",\"value\":\"$p\"}]" >/dev/null
    echo "$p enabled"
  fi
done
