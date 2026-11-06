#!/usr/bin/env bash
# 5. openai-java (the SDK the fraud-check agent would use) streams a Responses API turn from OGX: SSE events
# for the MCP listing, the MCP call, the text deltas and response.completed. Needs jbang and JDK 21.
# Expected (event counts vary):
#   event response.created x1 ... event response.mcp_call.completed x1 ... event response.output_text.delta xN
#   text: The status of claim CLM-1004 is Denied ...
#   status: completed
#   PASS  openai-java streams an OGX Responses turn with an MCP call
set -uo pipefail
. "$(dirname "$0")/lib.sh"
OPENAI_BASE_URL="$OGX/v1" OPENAI_API_KEY=unused MODEL="$MODEL" GW="$GW_IN_CLUSTER" TOKEN="$(token rebecca fraud-agent)" \
  jbang --quiet "$here/OpenAiJavaStreaming.java"
