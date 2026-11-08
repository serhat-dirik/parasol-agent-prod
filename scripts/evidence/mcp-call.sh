#!/usr/bin/env bash
# mcp-call.sh <url> <token|-> <virtual server|-> <tool> <json args>: one MCP tool call the way an agent makes it
# (initialize, initialized, tools/call), printed as "<body>|<http code>". A refusal at the handshake (a token not from
# an approved agent) is the answer. Used by the scripts/evidence/showcase*.sh evidence demos.
set -euo pipefail
url=$1 tok=$2 vs=$3 tool=$4 args=$5
h=(-H 'content-type: application/json' -H 'accept: application/json, text/event-stream')
[ "$vs" = - ] || h+=(-H "X-Mcp-Virtualserver: $vs")
[ "$tok" = - ] || h+=(-H "Authorization: Bearer $tok")
init='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"evidence","version":"1"}}}'
hdrs=$(curl -sk -D - -o /dev/null "$url" "${h[@]}" -d "$init")
head -1 <<<"$hdrs" | grep -q ' 200' || { curl -sk -w '|%{http_code}' "$url" "${h[@]}" -d "$init"; exit 0; }
sid=$(awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' <<<"$hdrs" | tr -d '\r')
[ -z "$sid" ] || h+=(-H "mcp-session-id: $sid")   # a stateless server (the unsecured one) issues none
curl -sk -o /dev/null "$url" "${h[@]}" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
curl -sk -w '|%{http_code}' "$url" "${h[@]}" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":$args}}"
