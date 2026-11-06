package org.parasol.ai;

import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.data.message.ChatMessage;
import dev.langchain4j.data.message.ToolExecutionResultMessage;
import dev.langchain4j.model.chat.listener.ChatModelListener;
import dev.langchain4j.model.chat.listener.ChatModelRequestContext;
import dev.langchain4j.model.chat.listener.ChatModelResponseContext;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.spi.CDI;

/**
 * A {@link ChatModelListener} that records the tools the model asked to call and what each returned.
 *
 * <p>quarkus-langchain4j auto-registers every {@code ChatModelListener} CDI bean around the model.
 * On each response we pull the {@link AiMessage}'s tool-execution requests (id, name, JSON arguments);
 * on the next request the trailing tool-result messages carry the text each tool returned, including a
 * refusal: the MCP client turns an MCP {@code isError} result or a non-2xx HTTP answer into a tool error,
 * and LangChain4j's default handler hands its message to the model as the result, so the turn goes on.
 * Both land in the request-scoped {@link ToolCallCollector}. We resolve the collector through
 * {@code CDI.current()} and swallow a missing request context, because the model callback may run on a
 * different (event-loop) thread than the request - if the context is not propagated we simply do not
 * record (the answer is unaffected).
 */
@ApplicationScoped
public class ToolCallRecorder implements ChatModelListener {

    /** The MCP gateway's guardrails refusals (tool result blocked; NeMo unreachable, fail closed). */
    static final String BLOCKED = "blocked by guardrails";
    static final String UNAVAILABLE = "guardrails check unavailable";

    /** How the MCP client words a non-2xx answer (QuarkusStreamableHttpMcpTransport). */
    private static final Pattern HTTP_REFUSAL =
            Pattern.compile("Unexpected status code: (403|503), body:\\s?(.*)", Pattern.DOTALL);
    private static final Pattern RPC_MESSAGE = Pattern.compile("\"message\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");

    /**
     * The gateway's reason when a tool result text is a refusal, else null:
     * an MCP error result {@code blocked by guardrails} (or {@code guardrails check unavailable}), or a
     * 403/503 whose JSON-RPC error message (else the body, else the status) is the reason.
     */
    static String blockedReason(String text) {
        if (text == null) {
            return null;
        }
        String t = text.strip();
        if (t.startsWith(BLOCKED) || t.startsWith(UNAVAILABLE)) {
            return cap(t);
        }
        Matcher m = HTTP_REFUSAL.matcher(t);
        if (!m.find()) {
            return null;
        }
        Matcher rpc = RPC_MESSAGE.matcher(m.group(2));
        if (rpc.find()) {
            return cap(rpc.group(1).replace("\\\"", "\""));
        }
        String body = m.group(2).strip();
        return body.isEmpty() || body.startsWith("<") ? "HTTP " + m.group(1) : cap(body);
    }

    private static String cap(String s) {
        return s.length() > 200 ? s.substring(0, 200) + "..." : s;
    }

    /** The collector of the current request; null when there is no active request context. */
    ToolCallCollector collector() {
        try {
            return CDI.current().select(ToolCallCollector.class).get();
        } catch (RuntimeException contextNotActive) {
            return null;
        }
    }

    @Override
    public void onRequest(ChatModelRequestContext requestContext) {
        List<ChatMessage> messages = requestContext.chatRequest().messages();
        int first = messages.size();
        while (first > 0 && messages.get(first - 1) instanceof ToolExecutionResultMessage) {
            first--;
        }
        if (first == messages.size()) {
            return;
        }
        ToolCallCollector collector = collector();
        if (collector == null) {
            return;
        }
        try {
            // only the trailing results: the ones answering the model's last tool requests (this turn)
            for (ChatMessage m : messages.subList(first, messages.size())) {
                ToolExecutionResultMessage r = (ToolExecutionResultMessage) m;
                collector.result(r.id(), r.toolName(), r.text());
            }
        } catch (RuntimeException contextNotActive) {
            // No active request context on this thread - skip recording, keep answering.
        }
    }

    @Override
    public void onResponse(ChatModelResponseContext responseContext) {
        AiMessage aiMessage = responseContext.chatResponse().aiMessage();
        if (aiMessage == null || !aiMessage.hasToolExecutionRequests()) {
            return;
        }
        ToolCallCollector collector = collector();
        if (collector == null) {
            return;
        }
        try {
            for (ToolExecutionRequest request : aiMessage.toolExecutionRequests()) {
                collector.record(request.id(), request.name(), request.arguments());
            }
        } catch (RuntimeException contextNotActive) {
            // No active request context on this thread - skip recording, keep answering.
        }
    }
}
