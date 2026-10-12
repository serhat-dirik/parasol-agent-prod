package org.parasol.ai;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.List;
import java.util.Optional;
import java.util.regex.Pattern;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import dev.langchain4j.model.output.TokenUsage;
import dev.langchain4j.service.Result;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.context.Scope;
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

    @Inject
    McpBearerTokenProvider mcpAuth;

    @Inject
    Tracer tracer;

    /** Secured: route writes through the local propose tool (A2). Free leaves this false. */
    @ConfigProperty(name = "portal.propose.enabled", defaultValue = "false")
    boolean proposeEnabled;

    /** The whole system prompt (secured: the registered production prompt). Empty = the laptop prompt. */
    @ConfigProperty(name = "agent.system-prompt")
    Optional<String> systemPromptConfig;

    /** Which environment this deployment is (secured / free): a label on metrics and traces, not a prompt version. */
    @ConfigProperty(name = "agent.env", defaultValue = "dev")
    String env;

    /** The MLflow Prompt Registry version this deployment runs (e.g. parasol-claims-assistant-system-prompt@production). */
    @ConfigProperty(name = "agent.prompt-version", defaultValue = "unset")
    String promptVersion;

    @ConfigProperty(name = "quarkus.langchain4j.openai.parasol-chat.chat-model.model-name", defaultValue = "parasol-chat")
    String modelName;

    private String systemPrompt() {
        return systemPromptConfig.filter(p -> !p.isBlank()).orElse(ClaimsAssistant.LAPTOP_PROMPT);
    }

    /** sha256 of the prompt this pod runs: equals the registry version's prompt_sha256 when they are the same text. */
    String promptSha256() {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(systemPrompt().getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /**
     * An answer that says a payout was proposed, submitted, approved or paid. In secured the model's only
     * write is propose_payout, so such a sentence without a propose_payout call on the same turn is false.
     * ponytail: phrase regex over the model's wording; a sentence it misses is not corrected.
     */
    static final Pattern CLAIMED_PAYOUT = Pattern.compile(
            "(?i)\\b(i\\s*(have|'ve)\\s+(now\\s+|already\\s+)?(proposed|submitted|approved|paid|settled|issued)"
                    + "|(payout|payment|proposal)(\\s+[\\w,.-]+){0,8}?\\s+(has|have)\\s+been\\s+(proposed|submitted|approved|paid|issued|settled|created))\\b");

    static final String UNBACKED_NOTE = "Platform note: no payout was proposed or approved in this turn "
            + "(propose_payout was not called), so nothing was submitted for a manager.";

    /** The note to append when {@code answer} claims a payout action no tool performed, else null. */
    static String unbackedClaimNote(String answer, boolean proposed) {
        return !proposed && answer != null && CLAIMED_PAYOUT.matcher(answer).find() ? UNBACKED_NOTE : null;
    }

    /** Ask the assistant. {@code conversationId} ties a chat session's turns together (A5 memory). */
    public AgentAnswer answer(String conversationId, String question) {
        Timer.Sample latency = Timer.start(metrics);
        // MLflow 3.14 OTLP ingest reads these span attributes into trace metadata: session.id ->
        // mlflow.trace.session and user.id -> mlflow.trace.user. Keying both on the caller makes
        // rebecca / marcus / nina.contractor each show up as one SESSION (the night shift = one session,
        // ~200 turns for nina.contractor). Set on the current (root) span; the ingest scans all spans.
        Span root = Span.current();
        String who = caller.subject();
        root.setAttribute("session.id", who);
        root.setAttribute("user.id", who);
        // Attribution: WHO asked (enduser.id) and WHICH agent acted for them (the Keycloak client the
        // tools see as azp), plus the prompt this deployment runs. PortalSpanProcessor stamps the
        // same pair on every tool span.
        root.setAttribute("enduser.id", who);
        root.setAttribute("gen_ai.agent.name", mcpAuth.agentId());
        root.setAttribute("gen_ai.agent.id", mcpAuth.agentId());
        root.setAttribute("gen_ai.prompt.ref", promptVersion);
        String promptSha = promptSha256();
        root.setAttribute("gen_ai.prompt.sha256", promptSha);
        root.setAttribute("mlflow.traceTag.prompt_sha256", promptSha);
        root.setAttribute("gen_ai.request.model", modelName);
        root.setAttribute("deployment.environment", env);
        // MLflow turns root-span attributes "mlflow.traceTag.<key>" into trace tags, so the trace header
        // reads "agent X on behalf of user Y" with the prompt and model next to it.
        root.setAttribute("mlflow.traceTag.agent", mcpAuth.agentId());
        root.setAttribute("mlflow.traceTag.prompt", promptVersion);
        root.setAttribute("mlflow.traceTag.model", modelName);
        root.setAttribute("mlflow.traceTag.env", env);
        // No trace without an exporting SDK (free): no id to show.
        String traceId = root.getSpanContext().isValid() ? root.getSpanContext().getTraceId() : null;
        // W3C baggage rides along with traceparent on the model call, so the guardrails proxy can log
        // and count each detection with the user and the agent it acted for, and apply its output rule
        // (the confidential marker) to everyone outside claims-managers ("|"-separated group names).
        String groups = String.join("|", JwtPeek.groups(caller.authorization()));
        Scope baggage = Baggage.current().toBuilder()
                .put("enduser.id", who).put("gen_ai.agent.name", mcpAuth.agentId())
                .put("enduser.groups", groups).build().makeCurrent();
        try {
            Result<String> result = proposeEnabled
                    ? assistant.askWithPropose(conversationId, systemPrompt(), question)
                    : assistant.ask(conversationId, systemPrompt(), question);
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
            // Secured: the answer may only claim a payout action that a tool call on this turn performed.
            String note = proposeEnabled ? unbackedClaimNote(answer, proposal != null) : null;
            if (note != null) {
                answer = answer + "\n\n" + note;
                LOG.infof("guardrail action=correct detector=unbacked-action user=%s agent=%s trace=%s", who,
                        mcpAuth.agentId(), traceId);
                metrics.counter("parasol_guardrail_detections_total", "detector", "unbacked-action", "action", "correct")
                        .increment();
                Span cs = tracer.spanBuilder("guardrails.answer").startSpan();
                cs.setAttribute("guardrail.action", "correct");
                cs.setAttribute("guardrail.detectors", "unbacked-action");
                cs.end();
            }
            // Operator-dashboard metrics: the model-path tool calls returned a result, so they
            // passed the gateway (status 200); 403s are counted on the Approve path in ClaimResource.
            recordToolCalls(toolCalls);
            recordGuardrail(guardrail);
            // Trace semantics: name the observed steps so the MLflow/Tempo trace reads as the story
            // (guardrails.tool_result when a detector flagged a tool result, the propose step).
            emitStorySpans(guardrail, proposal);
            LOG.infof("chat caller=%s agent=%s env=%s prompt=%s prompt_sha256=%.12s tools=%s guardrail=%s tokens=%s trace=%s", caller.subject(), mcpAuth.agentId(), env,
                    promptVersion, promptSha,
                    toolCalls.stream().map(ToolCall::tool).toList(),
                    guardrail == null ? "none" : guardrail.action(),
                    result.tokenUsage() == null ? "?" : result.tokenUsage().totalTokenCount(), traceId);
            return new AgentAnswer(question, answer, toolCalls, modelName,
                    usage(result.tokenUsage()), caller.subject(), env, null, false, guardrail, proposal, traceId);
        } catch (Exception e) {
            String detail = redact(rootMessage(e));
            boolean auth = looksLikeAuthFailure(detail);
            LOG.warnf("assistant call failed (authFailure=%s): %s", auth, detail);
            String error = errorMessage(detail, auth);
            // Rejections the platform answered for this user (usage limit 429, offline, key), by reason.
            metrics.counter("parasol_agent_rejections_total", "reason", reason(error), "user", who,
                    "agent", mcpAuth.agentId(), "env", env).increment();
            return new AgentAnswer(question, null, List.of(), modelName, null,
                    caller.subject(), env, error, auth, null, null, traceId);
        } finally {
            baggage.close();
            // P95 latency panel: a per-env/user/agent histogram of the whole assistant turn.
            latency.stop(Timer.builder("parasol_agent_latency_seconds")
                    .description("Assistant turn latency (model + MCP round-trips)")
                    .tag("env", env).tag("user", caller.subject()).tag("agent", mcpAuth.agentId())
                    .publishPercentileHistogram()
                    .register(metrics));
        }
    }

    /**
     * parasol_tool_calls_total{tool,user,agent,status}: one count per MCP tool the model invoked on this
     * turn. These reached a result, so status is 200; the Approve path counts the 403s per tool.
     */
    private void recordToolCalls(List<ToolCall> toolCalls) {
        String user = caller.subject();
        for (ToolCall tc : toolCalls) {
            metrics.counter("parasol_tool_calls_total", "tool", tc.tool(), "user", user, "agent", mcpAuth.agentId(),
                    "status", "200")
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

    /** The rejection reason label for {@link #errorMessage}'s message. */
    static String reason(String error) {
        if (error.contains("(429)")) {
            return "usage_limit";
        }
        if (error.contains("offline")) {
            return "offline";
        }
        return error.contains("authentication") ? "model_auth" : "other";
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
        // offender (e.g. nina.contractor in the night-shift storm); "anonymous" on the free, no-token path.
        String user = caller.subject();
        if (t.inputTokenCount() != null) {
            metrics.counter("parasol_agent_tokens_total", "type", "input", "env", env, "user", user,
                    "agent", mcpAuth.agentId())
                    .increment(t.inputTokenCount());
        }
        if (t.outputTokenCount() != null) {
            metrics.counter("parasol_agent_tokens_total", "type", "output", "env", env, "user", user,
                    "agent", mcpAuth.agentId())
                    .increment(t.outputTokenCount());
        }
        metrics.counter("parasol_agent_model_calls_total", "env", env, "user", user, "agent", mcpAuth.agentId())
                .increment();
    }

    /**
     * Emit the semantic spans that make a secured chat trace read as the story, as children of the
     * current turn span. A guardrails detection becomes {@code guardrails.input} when it masked the
     * caller's input (PII) or {@code guardrails.tool_result} when it flagged / blocked a tool result
     * (the inflated-document case), with the action as the span status (block = ERROR). A proposed
     * payout becomes {@code tool.propose_payout} (the Read-Propose-Act card step) - note that in
     * secured no {@code approve_payout} span appears, because the gateway filters it out.
     */
    private void emitStorySpans(Guardrail guardrail, Proposal proposal) {
        if (guardrail != null) {
            boolean input = "mask".equals(guardrail.action());
            Span gs = tracer.spanBuilder(input ? "guardrails.input" : "guardrails.tool_result").startSpan();
            try {
                if (guardrail.action() != null) {
                    gs.setAttribute("guardrail.action", guardrail.action());
                }
                if (guardrail.detectors() != null) {
                    gs.setAttribute("guardrail.detectors", guardrail.detectors());
                }
                if (guardrail.score() != null) {
                    gs.setAttribute("guardrail.score", guardrail.score());
                }
                if ("block".equals(guardrail.action())) {
                    gs.setStatus(StatusCode.ERROR, "blocked by guardrails");
                }
            } finally {
                gs.end();
            }
        }
        if (proposal != null) {
            Span ps = tracer.spanBuilder("tool.propose_payout").startSpan();
            try {
                ps.setAttribute("tool.name", "propose_payout");
                if (proposal.claimNumber() != null) {
                    ps.setAttribute("claim.number", proposal.claimNumber());
                }
                if (proposal.proposed() != null) {
                    ps.setAttribute("payout.proposed", proposal.proposed());
                }
                if (proposal.claimed() != null) {
                    ps.setAttribute("payout.claimed", proposal.claimed());
                }
            } finally {
                ps.end();
            }
        }
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
                              Usage tokenUsage, String caller, String env, String error,
                              boolean authFailure, Guardrail guardrail, Proposal proposal, String traceId) {
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
