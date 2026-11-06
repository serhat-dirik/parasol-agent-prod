# OGX Responses API checks: results

Run on 2026-11-06 against a test OGXServer in `parasol-ogx-lab` (`setup.sh`, `lab.yaml`): OGX 1.2.5.1+rhaiv.0
(operator 0.13.0, image `odh-ogx-core-rhel9@sha256:a96caf4e…`), mcp client 1.28.1, model `qwen3-14b` through the
in-cluster MaaS gateway, MCP tools through the Connectivity Link 1.5 MCP gateway with on-behalf-of tokens
(`scripts/agent-token.sh`). Run: `./setup.sh && ./run-all.sh`; clean up: `./setup.sh delete`.

| # | Check | Result |
|---|---|---|
| 1 | Responses API on, MaaS as the inference provider | PASS |
| 2 | Gateway refusal on tools/call is one failed `mcp_call` | **FAIL**: the whole turn fails (HTTP 500, no output) |
| 3 | Gateway token at initialize via the MCP tool's `authorization` | PASS (not stored with the response) |
| 4 | traceparent reaches the MCP gateway and the model call | PASS (claims-db joins the OGX trace in Tempo; the model call carries it) |
| 5 | openai-java 4.90.0 streaming against OGX | PASS (MCP list/call events, text deltas, `completed`) |
| 6 | Per-request MaaS key via `X-OGX-Provider-Data` | PASS (contractor key answers; an invalid key is refused by MaaS: OGX log shows 401, client gets 500) |

## Check 2 in detail

Any non-2xx answer from the MCP gateway on `tools/call` ends the whole Responses turn with HTTP 500:

* a) 403 from the per-tool AuthPolicy (`rebecca may not call list_claims_by_status`, fraud agent's read-only ceiling);
* b) the MCP gateway guardrails blocking CLM-1004's document (`guardrails blocked tool response`, HTTP 500 from the
  gateway). This is normal use: it is the fraud-check case itself, and with `failMode: deny` a NeMo outage
  refuses every claims-db call the same way.

Cause: the MCP client's streamable-HTTP transport (`mcp/client/streamable_http.py`, `_handle_post_request`) calls
`response.raise_for_status()` for any non-2xx except 404. The exception cancels the session's task group, so
`session.call_tool` gets `CancelledError`, a `BaseException` that passes OGX's `except Exception` in
`tool_executor._execute_tool`; the request ends in a 500. Tool errors returned inside a 200 (`isError`, JSON-RPC
error) take the `except Exception` path and become per-call `mcp_call` errors (read from the code, not run here). Together with the known 1.2.5.1 failures (a failed tools/list; model
tool arguments that are not valid JSON, `tool_executor.py:83`), a refused tool call cannot be shown to the person
as a red chip from an OGX-built agent: the turn just fails.

## Other observations

* Model ids are `<provider_id>/<model>` (`maas/qwen3-14b`); the plain id is a 404.
* Without `authorization` the gateway's 401 on initialize comes back as HTTP 401 for the whole turn.
* A continued turn (`previous_response_id`) reuses the previous MCP listing and calls with the NEW request's
  `authorization`; the gateway still decides each call (that is how check 2a gets its 403).
* openai-java sees one event type it does not know (`_unknown`) and OGX streams MCP arguments as
  `function_call_arguments.delta`; neither breaks the stream.
* MaaS lists no models at `/v1/models` on the per-model URL (404 at start-up, harmless: the model is registered).
