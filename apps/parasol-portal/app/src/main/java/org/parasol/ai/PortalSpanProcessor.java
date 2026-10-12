package org.parasol.ai;

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
 * this makes it {@code tool.get_claim}. The AI-service turn span {@code langchain4j.aiservices.*}
 * becomes {@code model.chat} (the model interaction that contains the tool and completion spans).
 *
 * <p>Quarkus OpenTelemetry registers every CDI {@link SpanProcessor} bean as an extra processor.
 * These span names are fixed when the span starts, so {@code onStart} is the right hook to rename.
 */
@ApplicationScoped
public class PortalSpanProcessor implements SpanProcessor {

    private static final String MCP_PREFIX = "tools/call ";
    private static final String AISERVICE_PREFIX = "langchain4j.aiservices.";

    @Override
    public void onStart(Context parentContext, ReadWriteSpan span) {
        String name = span.getName();
        if (name == null) {
            return;
        }
        if (name.startsWith(MCP_PREFIX)) {
            span.updateName("tool." + name.substring(MCP_PREFIX.length()).strip());
            attribute(span);
        } else if (name.startsWith(AISERVICE_PREFIX)) {
            span.updateName("model.chat");
        }
    }

    /** Every tool call says who it was for and which agent made it (enduser.id, gen_ai.agent.name). */
    private static void attribute(ReadWriteSpan span) {
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
