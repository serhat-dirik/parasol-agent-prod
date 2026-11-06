package org.parasol.ai;

/**
 * One tool the agent invoked while answering: the tool {@code name}, the JSON {@code arguments}
 * the model passed, and (when available) the tool {@code result} text the model saw. Reported in the
 * {@code POST /agent/ask} response so a lab can see exactly which "API" the agent called.
 * {@code blocked} is true when the MCP gateway refused the call or its result (guardrails block, 403,
 * guardrails check unavailable); {@code reason} is the gateway's explanation, shown as a red chip.
 */
public record ToolCall(String tool, String arguments, String result, boolean blocked, String reason) {
}
