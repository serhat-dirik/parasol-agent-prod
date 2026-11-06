package org.parasol.ai;

import java.util.Map;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import com.fasterxml.jackson.databind.ObjectMapper;

import io.opentelemetry.context.Context;
import io.quarkus.arc.Arc;
import io.quarkus.arc.InstanceHandle;
import jakarta.enterprise.context.ContextNotActiveException;
import io.opentelemetry.sdk.trace.ReadWriteSpan;
import io.opentelemetry.sdk.trace.ReadableSpan;
import io.opentelemetry.sdk.trace.SpanProcessor;
import jakarta.enterprise.context.ApplicationScoped;

/**
 * Renames the framework's auto-emitted spans to the demo's semantic names so a chat trace reads as
 * the story in MLflow and Tempo. LangChain4j names each MCP tool call {@code tools/call get_claim};
 * this makes it {@code tool.get_claim}, an MLflow TOOL span whose inputs are the arguments the model
 * passed (its result follows as the child span {@code tool.get_claim.result}, see {@link ToolCallRecorder}:
 * the MCP client ends this span before the result reaches application code). The AI-service turn span
 * {@code langchain4j.aiservices.*} becomes {@code model.chat} (the model interaction that contains the
 * tool and completion spans).
 *
 * <p>Quarkus OpenTelemetry registers every CDI {@link SpanProcessor} bean as an extra processor.
 * These span names are fixed when the span starts, so {@code onStart} is the right hook to rename.
 */
@ApplicationScoped
public class PortalSpanProcessor implements SpanProcessor {

    private static final String MCP_PREFIX = "tools/call ";
    private static final String AISERVICE_PREFIX = "langchain4j.aiservices.";
    private static final ObjectMapper JSON = new ObjectMapper();

    @ConfigProperty(name = "portal.propose.enabled", defaultValue = "false")
    boolean secured;

    @Override
    public void onStart(Context parentContext, ReadWriteSpan span) {
        String name = span.getName();
        if (name == null) {
            return;
        }
        if (name.startsWith(MCP_PREFIX)) {
            String tool = name.substring(MCP_PREFIX.length()).strip();
            span.updateName("tool." + tool);
            attribute(span);
            span.setAttribute(TraceContent.TYPE, "TOOL");
            ToolCallCollector.Entry call = started(tool, span);
            if (call != null) {
                span.setAttribute(TraceContent.INPUTS, TraceContent.json(arguments(call.arguments, secured)));
            }
        } else if (name.startsWith(AISERVICE_PREFIX)) {
            span.updateName("model.chat");
        }
    }

    /** The tool call's arguments as an object (masked on the secured side), else the raw text. */
    static Object arguments(String json, boolean secured) {
        String t = TraceContent.text(json == null ? "{}" : json, secured);
        try {
            return JSON.readValue(t, Map.class);
        } catch (Exception notAnObject) {
            return Map.of("arguments", t);
        }
    }

    /** Pair the span with the call the model asked for on this request (null outside a chat turn). */
    private ToolCallCollector.Entry started(String tool, ReadWriteSpan span) {
        try {
            ToolCallCollector calls = collector();
            return calls == null ? null : calls.started(tool, span.getSpanContext());
        } catch (ContextNotActiveException e) {
            return null;
        }
    }

    /** The current request's tool calls (null without a container). */
    ToolCallCollector collector() {
        if (Arc.container() == null) {
            return null;
        }
        InstanceHandle<ToolCallCollector> calls = Arc.container().instance(ToolCallCollector.class);
        return calls.isAvailable() ? calls.get() : null;
    }

    /** Every tool call says who it was for and which agent made it (enduser.id, gen_ai.agent.name). */
    private static void attribute(ReadWriteSpan span) {
        if (Arc.container() == null) {
            return;
        }
        try {
            InstanceHandle<McpBearerTokenProvider> auth = Arc.container().instance(McpBearerTokenProvider.class);
            if (auth.isAvailable()) {
                span.setAttribute("gen_ai.agent.name", auth.get().agentId());
            }
            InstanceHandle<CallerIdentity> caller = Arc.container().instance(CallerIdentity.class);
            if (caller.isAvailable()) {
                span.setAttribute("enduser.id", caller.get().subject());
            }
        } catch (ContextNotActiveException e) {
            // tool call outside a request (startup discovery): no user to name
        }
    }

    @Override
    public boolean isStartRequired() {
        return true;
    }

    @Override
    public void onEnd(ReadableSpan span) {
        // No-op: renaming happens in onStart; nothing to export here.
    }

    @Override
    public boolean isEndRequired() {
        return false;
    }
}
