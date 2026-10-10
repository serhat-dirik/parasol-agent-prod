package org.parasol.ai;

import java.util.List;
import java.util.Optional;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import dev.langchain4j.model.output.TokenUsage;
import dev.langchain4j.service.Result;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
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
    ProposalHolder proposalHolder;

    @Inject
    MeterRegistry metrics;

    /** Secured: route writes through the local propose tool (A2). Free leaves this false. */
    @ConfigProperty(name = "portal.propose.enabled", defaultValue = "false")
    boolean proposeEnabled;

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
        Timer.Sample latency = Timer.start(metrics);
        try {
            Result<String> result = proposeEnabled
                    ? assistant.askWithPropose(conversationId, safetyRules(), question)
                    : assistant.ask(conversationId, safetyRules(), question);
            count(result.tokenUsage());
            List<ToolCall> toolCalls = toolCallCollector.calls();
            Proposal proposal = proposalHolder.has()
                    ? new Proposal(proposalHolder.claimNumber(), proposalHolder.proposed(), proposalHolder.claimed())
                    : null;
            // The secured model path runs through the guardrails proxy, which prepends a sentinel
            // first line to the answer (option A agreed with Stream G). Split it off so the UI can
            // render the amber banner / mask chip; the remaining lines are the real answer.
            Guardrail guardrail = Guardrail.parse(result.content());
            String answer = guardrail == null ? result.content() : guardrail.strippedContent();
            // Operator-dashboard metrics: the model-path tool calls returned a result, so they
            // passed the gateway (status 200); 403s are counted on the Approve path in ClaimResource.
            recordToolCalls(toolCalls);
            recordGuardrail(guardrail);
            LOG.infof("chat caller=%s version=%s tools=%s guardrail=%s tokens=%s", caller.subject(), version,
                    toolCalls.stream().map(ToolCall::tool).toList(),
                    guardrail == null ? "none" : guardrail.action(),
                    result.tokenUsage() == null ? "?" : result.tokenUsage().totalTokenCount());
            return new AgentAnswer(question, answer, toolCalls, modelName,
                    usage(result.tokenUsage()), caller.subject(), version, null, false, guardrail, proposal);
        } catch (Exception e) {
            String detail = redact(rootMessage(e));
            boolean auth = looksLikeAuthFailure(detail);
            LOG.warnf("assistant call failed (authFailure=%s): %s", auth, detail);
            String error = errorMessage(detail, auth);
            return new AgentAnswer(question, null, List.of(), modelName, null,
                    caller.subject(), version, error, auth, null, null);
        } finally {
            // P95 latency panel: a per-version/user histogram of the whole assistant turn.
            latency.stop(Timer.builder("parasol_agent_latency_seconds")
                    .description("Assistant turn latency (model + MCP round-trips)")
                    .tag("version", version).tag("user", caller.subject())
                    .publishPercentileHistogram()
                    .register(metrics));
        }
    }

    /**
     * parasol_tool_calls_total{tool,user,status}: one count per MCP tool the model invoked on this
     * turn. These reached a result, so status is 200; the Approve path counts the 403s per tool.
     */
    private void recordToolCalls(List<ToolCall> toolCalls) {
        String user = caller.subject();
        for (ToolCall tc : toolCalls) {
            metrics.counter("parasol_tool_calls_total", "tool", tc.tool(), "user", user, "status", "200")
                    .increment();
        }
    }

    /**
     * parasol_guardrail_detections_total{detector,action}: one count per detector the guardrails
     * proxy reported on this turn (flag / block / mask), so the dashboard shows detector hits.
     */
    private void recordGuardrail(Guardrail guardrail) {
        if (guardrail == null || guardrail.detectors() == null || guardrail.detectors().isBlank()) {
            return;
        }
        String action = guardrail.action() == null ? "unknown" : guardrail.action();
        for (String detector : guardrail.detectors().split(",")) {
            String d = detector.strip();
            if (!d.isEmpty()) {
                metrics.counter("parasol_guardrail_detections_total", "detector", d, "action", action)
                        .increment();
            }
        }
    }

    /** Map an upstream failure to the message the chat shows (Demo 3 states: usage limit, offline). */
    static String errorMessage(String detail, boolean auth) {
        String d = detail == null ? "" : detail.toLowerCase();
        if (d.contains("429") || d.contains("rate limit") || d.contains("rate_limit")
                || d.contains("too many requests") || d.contains("quota")) {
            return "You have reached your usage limit (429). Please try again later.";
        }
        if (auth) {
            return "model authentication failed - check the MaaS key; it may be expired";
        }
        // Kill switch / severed model path: connection refused, timeout, 502/503/504, no route.
        if (d.contains("timed out") || d.contains("timeout") || d.contains("connection")
                || d.contains("502") || d.contains("503") || d.contains("504")
                || d.contains("unreachable") || d.contains("no route")) {
            return "The assistant is offline.";
        }
        return "the assistant could not complete that request";
    }

    private void count(TokenUsage t) {
        if (t == null) {
            return;
        }
        // user tag carries the Keycloak preferred_username so the per-user spend alert can NAME the
        // offender (e.g. tom.becker in the night-shift storm); "anonymous" on the free, no-token path.
        String user = caller.subject();
        if (t.inputTokenCount() != null) {
            metrics.counter("parasol_agent_tokens_total", "type", "input", "version", version, "user", user)
                    .increment(t.inputTokenCount());
        }
        if (t.outputTokenCount() != null) {
            metrics.counter("parasol_agent_tokens_total", "type", "output", "version", version, "user", user)
                    .increment(t.outputTokenCount());
        }
        metrics.counter("parasol_agent_model_calls_total", "version", version, "user", user).increment();
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
                              Usage tokenUsage, String caller, String version, String error,
                              boolean authFailure, Guardrail guardrail, Proposal proposal) {
    }

    /** A payout the assistant proposed (secured, A2): the UI renders proposed vs claimed with an Approve button. */
    public record Proposal(String claimNumber, Double proposed, Double claimed) {
    }

    /**
     * A guardrails signal parsed from the first line of the proxy's answer (option A, Stream G):
     * {@code ❦GUARDRAILS action=<flag|block|mask>;detectors=<csv>;score=<num>;masked=<csv>;msg=<text>❧}
     * followed by a newline and the real answer. {@code action} drives the UI: flag=amber banner +
     * summary continues, block=amber banner + refusal, mask=grey "personal data masked" chip.
     */
    public record Guardrail(String action, String detectors, String score, String masked, String msg,
                            String strippedContent) {

        private static final String PREFIX = "❦GUARDRAILS ";   // ❦
        private static final String SUFFIX = "❧";              // ❧

        /** Parse the sentinel off {@code content}, or return null if the first line is not one. */
        static Guardrail parse(String content) {
            if (content == null) {
                return null;
            }
            int nl = content.indexOf('\n');
            String firstLine = (nl < 0 ? content : content.substring(0, nl)).strip();
            if (!firstLine.startsWith(PREFIX) || !firstLine.endsWith(SUFFIX)) {
                return null;
            }
            String rest = nl < 0 ? "" : content.substring(nl + 1);
            String middle = firstLine.substring(PREFIX.length(), firstLine.length() - SUFFIX.length());
            // msg is always last and its value may contain ';', so peel it off before splitting the rest.
            String msg = null;
            int msgAt = middle.indexOf("msg=");
            if (msgAt >= 0) {
                msg = middle.substring(msgAt + 4);
                middle = middle.substring(0, msgAt);
            }
            String action = null;
            String detectors = null;
            String score = null;
            String masked = null;
            for (String token : middle.split(";")) {
                int eq = token.indexOf('=');
                if (eq < 0) {
                    continue;
                }
                String k = token.substring(0, eq).strip();
                String v = token.substring(eq + 1);
                switch (k) {
                    case "action" -> action = v;
                    case "detectors" -> detectors = v;
                    case "score" -> score = v;
                    case "masked" -> masked = v;
                    default -> { /* ignore unknown keys */ }
                }
            }
            return new Guardrail(action, detectors, score, masked, msg, rest);
        }
    }
}
