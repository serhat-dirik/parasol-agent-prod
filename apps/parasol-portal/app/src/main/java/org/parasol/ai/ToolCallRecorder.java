package org.parasol.ai;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.data.message.ChatMessage;
import dev.langchain4j.data.message.ToolExecutionResultMessage;
import dev.langchain4j.model.chat.listener.ChatModelListener;
import dev.langchain4j.model.chat.listener.ChatModelRequestContext;
import dev.langchain4j.model.chat.listener.ChatModelResponseContext;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Context;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.spi.CDI;
import jakarta.inject.Inject;

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
    /**
     * Connectivity Link 1.5's gateway answers a tool result its guardrails blocked with HTTP 500 and an
     * empty body (not the isError result its design describes), so any 500 on a tool call is this refusal.
     * The chip shows the short text.
     */
    public static final String GATEWAY_500_REASON =
            "refused by the MCP gateway (HTTP 500; with guardrails on, this is how a blocked tool result arrives)";
    public static final String GATEWAY_500_CHIP = "refused by the MCP gateway (HTTP 500)";

    /** How the MCP client words a non-2xx answer (QuarkusStreamableHttpMcpTransport). */
    private static final Pattern HTTP_REFUSAL =
            Pattern.compile("Unexpected status code: (403|500|503), body:\\s?(.*)", Pattern.DOTALL);
    private static final Pattern RPC_MESSAGE = Pattern.compile("\"message\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");

    /**
     * The gateway's reason when a tool result text is a refusal, else null:
     * an MCP error result {@code blocked by guardrails} (or {@code guardrails check unavailable}), or a
     * 403/503 whose JSON-RPC error message (else the body, else the status) is the reason, or any 500.
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
        if ("500".equals(m.group(1))) {
            return GATEWAY_500_REASON;
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

    @Inject
    Tracer tracer;

    @ConfigProperty(name = "portal.propose.enabled", defaultValue = "false")
    boolean secured;

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
                traceResult(collector.result(r.id(), r.toolName(), r.text()));
            }
        } catch (RuntimeException contextNotActive) {
            // No active request context on this thread - skip recording, keep answering.
        }
    }

    /**
     * The tool's result on the trace: a child span {@code tool.<name>.result} of the call's TOOL span, with
     * the result text the model saw as its outputs (masked on the secured side) and the refusal, if any.
     */
    void traceResult(ToolCallCollector.Entry call) {
        if (call == null || call.span == null || tracer == null) {
            return;
        }
        Span s = tracer.spanBuilder("tool." + call.tool + ".result")
                .setParent(Context.root().with(Span.wrap(call.span))).startSpan();
        try {
            s.setAttribute("tool.name", call.tool);
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("result", TraceContent.text(call.result, secured));
            if (call.reason != null) {
                out.put("blocked", call.reason);
                s.setAttribute("tool.blocked", true);
                s.setAttribute("tool.blocked.reason", call.reason);
                s.setStatus(StatusCode.ERROR, call.reason);
            }
            s.setAttribute(TraceContent.OUTPUTS, TraceContent.json(out));
        } finally {
            s.end();
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
