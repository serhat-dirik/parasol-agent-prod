package org.parasol.ai;

import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

import jakarta.enterprise.context.RequestScoped;

/**
 * Per-request record of the MCP tools the agent called.
 *
 * <p>Request-scoped so each {@code POST /agent/ask} sees only its own tool calls. Populated by
 * {@link ToolCallRecorder} (a {@code ChatModelListener}) as the model asks for tools, and completed with
 * each tool's result text when the next model request carries it; read by {@link AgentService} to build
 * the {@code toolCalls} in the response. This is how we surface the calls even though LangChain4j's
 * {@code Result.toolExecutions()} does not include MCP-tool executions (only local {@code @Tool} beans).
 */
@RequestScoped
public class ToolCallCollector {

    private final List<Entry> calls = new ArrayList<>();

    /** A recorded call; mutable because its result arrives with the next model request. */
    static final class Entry {
        final String id;
        final String tool;
        final String arguments;
        String result;
        String reason;

        Entry(String id, String tool, String arguments) {
            this.id = id;
            this.tool = tool;
            this.arguments = arguments;
        }
    }

    synchronized void record(String id, String tool, String arguments) {
        calls.add(new Entry(id, tool, arguments));
    }

    /**
     * Attach a tool result to its call: by the tool-call id, else the oldest call of that tool still
     * without a result. Returns the entry, or null when no call of this turn matches (an earlier turn's
     * result in the chat memory).
     */
    synchronized Entry result(String id, String tool, String text) {
        Entry match = null;
        for (Entry e : calls) {
            if (e.result == null && id != null && id.equals(e.id)) {
                match = e;
                break;
            }
        }
        if (match == null && (id == null || id.isBlank())) {
            for (Entry e : calls) {
                if (e.result == null && Objects.equals(tool, e.tool)) {
                    match = e;
                    break;
                }
            }
        }
        if (match != null) {
            match.result = text == null ? "" : text;
            match.reason = ToolCallRecorder.blockedReason(text);
        }
        return match;
    }

    synchronized List<ToolCall> calls() {
        return calls.stream()
                .map(e -> new ToolCall(e.tool, e.arguments, e.result, e.reason != null, e.reason))
                .toList();
    }
}
