package org.parasol.ai;

import java.util.List;
import java.util.Optional;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import dev.langchain4j.model.output.TokenUsage;
import dev.langchain4j.service.Result;
import io.micrometer.core.instrument.MeterRegistry;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The portal's one entry point to the tool-using assistant, shared by the chat WebSocket and the
 * {@code POST /agent/ask} REST endpoint (the latter is what {@code scripts/night-shift.sh} drives).
 *
 * <p>It runs {@link ClaimsAssistant#ask}, counts tokens, pulls the MCP tool calls the model made
 * out of the request-scoped {@link ToolCallCollector}, and turns an upstream failure (expired MaaS
 * key, a gateway 403/guardrails block surfaced as an exception) into a clean {@link AgentAnswer}
 * with an {@code error} instead of a stack trace. Blocking: the model + MCP round-trips take seconds.
 */
@ApplicationScoped
public class AgentService {

    private static final Logger LOG = Logger.getLogger(AgentService.class);

    @Inject
    ClaimsAssistant assistant;

    @Inject
    ToolCallCollector toolCallCollector;

    @Inject
    CallerIdentity caller;

    @Inject
    MeterRegistry metrics;

    @ConfigProperty(name = "agent.safety-rules")
    Optional<String> safetyRulesConfig;

    @ConfigProperty(name = "agent.version", defaultValue = "dev")
    String version;

    @ConfigProperty(name = "quarkus.langchain4j.openai.parasol-chat.chat-model.model-name", defaultValue = "parasol-chat")
    String modelName;

    private String safetyRules() {
        return safetyRulesConfig.orElse("");
    }

    /** Ask the assistant. {@code conversationId} ties a chat session's turns together (A5 memory). */
    public AgentAnswer answer(String conversationId, String question) {
        try {
            Result<String> result = assistant.ask(conversationId, safetyRules(), question);
            count(result.tokenUsage());
            List<ToolCall> toolCalls = toolCallCollector.calls();
            LOG.infof("chat caller=%s version=%s tools=%s tokens=%s", caller.subject(), version,
                    toolCalls.stream().map(ToolCall::tool).toList(),
                    result.tokenUsage() == null ? "?" : result.tokenUsage().totalTokenCount());
            return new AgentAnswer(question, result.content(), toolCalls, modelName,
                    usage(result.tokenUsage()), caller.subject(), version, null, false);
        } catch (Exception e) {
            String detail = redact(rootMessage(e));
            boolean auth = looksLikeAuthFailure(detail);
            LOG.warnf("assistant call failed (authFailure=%s): %s", auth, detail);
            String error = auth ? "model authentication failed - check the MaaS key; it may be expired"
                    : "the assistant could not complete that request";
            return new AgentAnswer(question, null, List.of(), modelName, null,
                    caller.subject(), version, error, auth);
        }
    }

    private void count(TokenUsage t) {
        if (t == null) {
            return;
        }
        if (t.inputTokenCount() != null) {
            metrics.counter("parasol_agent_tokens_total", "type", "input", "version", version)
                    .increment(t.inputTokenCount());
        }
        if (t.outputTokenCount() != null) {
            metrics.counter("parasol_agent_tokens_total", "type", "output", "version", version)
                    .increment(t.outputTokenCount());
        }
        metrics.counter("parasol_agent_model_calls_total", "version", version).increment();
    }

    private static Usage usage(TokenUsage t) {
        return t == null ? null : new Usage(t.inputTokenCount(), t.outputTokenCount(), t.totalTokenCount());
    }

    static String rootMessage(Throwable t) {
        Throwable c = t;
        while (c.getCause() != null && c.getCause() != c) {
            c = c.getCause();
        }
        String m = c.getMessage();
        return m == null ? c.getClass().getSimpleName() : m;
    }

    /** Blank any sk-/JWT-shaped token out of an upstream message before it is logged or returned. */
    static String redact(String message) {
        return message == null ? null
                : message.replaceAll("(sk-|eyJ)[A-Za-z0-9._~+/=-]{8,}", "$1<redacted>");
    }

    static boolean looksLikeAuthFailure(String detail) {
        if (detail == null) {
            return false;
        }
        String l = detail.toLowerCase();
        return l.contains("401") || l.contains("unauthorized") || l.contains("authentication")
                || l.contains("invalid api key") || l.contains("invalid_api_key");
    }

    public record Usage(Integer inputTokens, Integer outputTokens, Integer totalTokens) {
    }

    public record AgentAnswer(String question, String answer, List<ToolCall> toolCalls, String model,
                              Usage tokenUsage, String caller, String version, String error, boolean authFailure) {
    }
}
