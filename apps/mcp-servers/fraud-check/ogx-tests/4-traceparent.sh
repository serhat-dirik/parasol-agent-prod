#!/usr/bin/env bash
# 4. Trace context: a caller's traceparent reaches the model call (MaaS) and the MCP gateway.
# OGX runs under opentelemetry-instrument (OTEL_SERVICE_NAME set), so its httpx calls carry traceparent.
#  - MCP gateway: the gateway forwards it to claims-db, whose spans land in Tempo in the SAME trace as OGX's.
#  - MaaS: its gateway records no traces, so a header echo (provider "echo", same remote::openai client as
#    the MaaS provider) shows the traceparent OGX puts on a model call, and Tempo shows the MaaS call span.
# Expected:
#   services in trace <id>: ['claims-db', 'ogx-lab']
#   model call span to MaaS in the trace: True
#   echo saw traceparent with trace id <id>: True
#   PASS  traceparent reaches the MCP gateway (claims-db joined the trace) and the model call
set -uo pipefail
. "$(dirname "$0")/lib.sh"
tid=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
tp="00-$tid-$(python3 -c 'import secrets; print(secrets.token_hex(8))')-01"
tool=$(mcp_tool claims-db claims-db "$(token rebecca fraud-agent)" '["get_claim"]')
curl -s "$OGX/v1/responses" -H 'content-type: application/json' -H "traceparent: $tp" \
  -d "{\"model\":\"$MODEL\",\"input\":\"What is the status of claim CLM-1004? /no_think\",\"tools\":[$tool]}" | summary
curl -s -o /dev/null "$OGX/v1/chat/completions" -H 'content-type: application/json' -H "traceparent: $tp" \
  -d '{"model":"echo/echo","messages":[{"role":"user","content":"hi"}]}'
sleep 15   # span batches flush every 5 s, then the collector forwards
trace=$(oc exec -n "$NS" deploy/ogx-lab -- curl -s --max-time 10 "http://tempo-parasol.observability.svc.cluster.local:3200/api/traces/$tid")
svc=$(printf '%s' "$trace" | python3 -c 'import json,sys
d=json.load(sys.stdin); s=set(); maas=False
for b in d.get("batches",d.get("resourceSpans",[])):
    name=[a["value"].get("stringValue") for a in b["resource"]["attributes"] if a["key"]=="service.name"][0]; s.add(name)
    for ss in b.get("scopeSpans",b.get("instrumentationLibrarySpans",[])):
        for sp in ss["spans"]:
            if any(a["key"] in ("server.address","net.peer.name") and "maas-default-gateway" in str(a["value"]) for a in sp.get("attributes",[])): maas=True
print(sorted(s)); print(maas)')
echo "services in trace $tid: $(printf '%s' "$svc" | head -1)"
echo "model call span to MaaS in the trace: $(printf '%s' "$svc" | tail -1)"
echo_ok=$(oc logs -n "$NS" deploy/ogx-echo --since=2m | grep -c "traceparent=00-$tid-")
echo "echo saw traceparent with trace id $tid: $([ "$echo_ok" -gt 0 ] && echo True || echo False)"
printf '%s' "$svc" | head -1 | grep -q "'claims-db'" && printf '%s' "$svc" | tail -1 | grep -q True && [ "$echo_ok" -gt 0 ] \
  && pass "traceparent reaches the MCP gateway (claims-db joined the trace) and the model call" || fail "see above"
