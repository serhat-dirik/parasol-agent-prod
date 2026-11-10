package org.parasol.ai;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.eclipse.microprofile.rest.client.inject.RestClient;
import org.jboss.logging.Logger;
import org.parasol.model.ClaimDtos;
import org.parasol.resources.ClaimsDbClient;

import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.mcp.client.McpClient;
import dev.langchain4j.model.output.TokenUsage;
import dev.langchain4j.service.Result;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.context.Scope;
import io.quarkiverse.langchain4j.mcp.runtime.McpClientName;
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

    @Inject
    McpBearerTokenProvider mcpAuth;

    @Inject
    Tracer tracer;

    @Inject
    @RestClient
    ClaimsDbClient claimsDb;

    /** The fraud-check MCP server through the gateway, as the signed-in user's agent: the automatic check (secured). */
    @Inject
    @McpClientName("fraud-check")
    McpClient fraudCheck;

    /** Secured: the portal's checks on each turn (unbacked actions, claim status, suspicious documents). Free: off. */
    @ConfigProperty(name = "portal.secured", defaultValue = "false")
    boolean secured;

    /**
     * File holding the whole system prompt (secured: the RELEASED prompt, mounted from ConfigMap
     * agent-prompt-release, which only the release's promote writes). Read on every turn, so the prompt that
     * runs is always the one the release pinned (the kubelet refreshes the mount within about a minute); a Git
     * edit of the authoring file changes nothing here. Unset = the laptop prompt. A sibling file
     * {@code promptVersion} names the registry version (name/version) the release pinned.
     */
    @ConfigProperty(name = "agent.system-prompt-file")
    Optional<String> systemPromptFile;

    /** Which environment this deployment is (secured / free): a label on metrics and traces, not a prompt version. */
    @ConfigProperty(name = "agent.env", defaultValue = "dev")
    String env;

    /** The MLflow Prompt Registry version this deployment runs (e.g. parasol-claims-assistant-system-prompt@production). */
    @ConfigProperty(name = "agent.prompt-version", defaultValue = "unset")
    String promptVersion;

    @ConfigProperty(name = "quarkus.langchain4j.openai.parasol-chat.chat-model.model-name", defaultValue = "parasol-chat")
    String modelName;

    String systemPrompt() {
        if (systemPromptFile.isEmpty()) {
            return ClaimsAssistant.LAPTOP_PROMPT;
        }
        try {
            return Files.readString(Path.of(systemPromptFile.get()));
        } catch (IOException e) {   // never fall back silently to a weaker prompt
            throw new IllegalStateException("system prompt file unreadable: " + systemPromptFile.get(), e);
        }
    }

    /** The registry version the release pinned (file promptVersion next to the prompt), else the configured ref. */
    private String releasedVersion() {
        if (systemPromptFile.isPresent()) {
            Path v = Path.of(systemPromptFile.get()).resolveSibling("promptVersion");
            try {
                if (Files.isReadable(v)) {
                    return Files.readString(v).trim();
                }
            } catch (IOException ignored) {
                // fall back to the configured reference
            }
        }
        return promptVersion;
    }

    /** sha256 of a prompt text: equals the registry version's prompt_sha256 when they are the same text. */
    static String sha256(String text) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(text.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /**
     * Secured, two-stage approval: the model's only write is approve_claim (the claim is valid, the amount agreed);
     * it can never pay, a claims manager releases payments on the claim page. So an answer that says a payment was
     * made is always false, and one that says the claim was approved is false unless approve_claim succeeded on the
     * same turn; a negated sentence ("no payment has been made") is not a claim. Mirrored in
     * gitops/platform/eval/mlflow-agent-eval/agent_eval.py.
     * ponytail: phrase regex over the model's wording; a sentence it misses is not corrected.
     */
    static final Pattern CLAIMED_PAYMENT = Pattern.compile(
            "(?i)\\b(i\\s*(have|'ve)\\s+(now\\s+|already\\s+)?(paid|settled|issued|released)"
                    + "|(?<!no )(payout|payment)(\\s+[\\w,.-]+){0,8}?\\s+(has|have)\\s+been\\s+(paid|issued|settled|released|made))\\b");
    static final Pattern CLAIMED_APPROVAL = Pattern.compile(
            "(?i)\\b(i\\s*(have|'ve)\\s+(now\\s+|already\\s+)?approved"
                    + "|(?<!no )(claim|payout|payment)(\\s+[\\w,.-]+){0,8}?\\s+(has|have)\\s+been\\s+approved)\\b");

    static final String UNBACKED_PAYMENT_NOTE = "Platform note: no payment was made. The assistant cannot pay a claim: "
            + "a claims manager releases the payment on the claim page.";
    static final String UNBACKED_APPROVAL_NOTE = "Platform note: the claim was not approved in this turn "
            + "(approve_claim did not run), so nothing changed.";

    /** The note to append when {@code answer} claims a payment, or an approval no tool performed, else null. */
    static String unbackedClaimNote(String answer, boolean approved) {
        if (answer == null) {
            return null;
        }
        if (CLAIMED_PAYMENT.matcher(answer).find()) {
            return UNBACKED_PAYMENT_NOTE;
        }
        return !approved && CLAIMED_APPROVAL.matcher(answer).find() ? UNBACKED_APPROVAL_NOTE : null;
    }

    /** approve_claim ran on this turn and the gateway did not refuse it. */
    static boolean approvedThisTurn(List<ToolCall> calls) {
        return calls.stream().anyMatch(c -> "approve_claim".equals(c.tool()) && !c.blocked()
                && c.result() != null && c.result().contains("Ready for payment"));
    }

    /**
     * A claim status the answer states ("CLM-1006 is Closed", "status: Approved"). Mirrored in
     * gitops/platform/eval/mlflow-agent-eval/agent_eval.py (literal-compared with this source).
     * ponytail: phrase regex over the whole answer; a status stated another way is not corrected.
     */
    static final Pattern STATED_STATUS = Pattern.compile(
            "(?i)\\b(?:is|has\\s+been|as|status(?:\\s+is)?:?)\\s+(?:now\\s+|currently\\s+|still\\s+)?\\**"
                    + "(submitted|under\\s*review|in\\s*review|approved|denied|closed|paid|settled|rejected|cancell?ed)\\b");

    /** An amount the answer states explicitly ("the amount is 84,000", "claimed USD 84,000"). */
    static final Pattern STATED_AMOUNT = Pattern.compile(
            "(?i)\\b(?:amount\\s+is|claimed)\\s+(USD\\s*|\\$\\s*|AED\\s*|EUR\\s*)?([0-9][0-9,]*(?:\\.[0-9]+)?)(\\s*(?:USD|AED|EUR))?");

    static final Pattern CLAIM_NUMBER = Pattern.compile("\\bCLM-\\d{4}\\b");

    static final String STATUS_NOTE = "Platform note: the claims record shows %s as %s, not the status stated above.";

    static final String AMOUNT_NOTE = "Platform note: the claims record shows the claimed amount on %s as %s, "
            + "not the amount stated above.";

    /** A status word as one token: "Under Review" -> underreview; "In Review" is the same status. */
    static String statusKey(String s) {
        String k = s.toLowerCase().replaceAll("\\s+", "");
        return k.equals("inreview") ? "underreview" : k.replace("cancelled", "canceled");
    }

    /**
     * The correction notes for claim facts the answer misstates, else null. For each claim number in the
     * answer (at most 5), {@code lookup} reads the record (null when unreadable): a status the answer states
     * that is not the record's, with the record's status named nowhere in the answer, gets a note naming the
     * recorded status; an amount stated as "amount is X" / "claimed X" (USD or no currency) that differs
     * from the record gets a note naming the recorded amount.
     */
    static String statusMismatchNote(String answer, java.util.function.Function<String, ClaimDtos.ClaimDto> lookup) {
        if (answer == null) {
            return null;
        }
        String flat = statusKey(answer);
        List<String> stated = STATED_STATUS.matcher(answer).results().map(m -> statusKey(m.group(1))).toList();
        List<java.math.BigDecimal> amounts = STATED_AMOUNT.matcher(answer).results()
                .filter(m -> !(String.valueOf(m.group(1)) + m.group(3)).matches("(?i).*(AED|EUR).*"))
                .map(m -> new java.math.BigDecimal(m.group(2).replace(",", ""))).toList();
        if (stated.isEmpty() && amounts.isEmpty()) {
            return null;
        }
        List<String> notes = new java.util.ArrayList<>();
        for (String n : CLAIM_NUMBER.matcher(answer).results().map(java.util.regex.MatchResult::group)
                .distinct().limit(5).toList()) {
            ClaimDtos.ClaimDto c = lookup.apply(n);
            if (c == null) {
                continue;
            }
            if (c.status() != null && !c.status().isBlank()) {
                String rec = statusKey(c.status());
                if (stated.stream().anyMatch(s -> !s.equals(rec)) && !flat.contains(rec)) {
                    notes.add(String.format(STATUS_NOTE, n, c.status()));
                }
            }
            if (c.amount() != null && !amounts.isEmpty()) {
                try {
                    java.math.BigDecimal rec = new java.math.BigDecimal(c.amount().replace(",", ""));
                    if (amounts.stream().anyMatch(a -> a.compareTo(rec) != 0)) {
                        notes.add(String.format(AMOUNT_NOTE, n, c.amount()));
                    }
                } catch (NumberFormatException ignored) {
                    // a record amount that is not a number: nothing to compare
                }
            }
        }
        return notes.isEmpty() ? null : String.join("\n", notes);
    }

    /** The claim as the user may read it (claims-db's record rule), null when it cannot be read. */
    private ClaimDtos.ClaimDto readClaim(String number) {
        try {
            return claimsDb.one(number, mcpAuth.getAuthorization(null));
        } catch (RuntimeException refusedOrMissing) {
            return null;
        }
    }

    /**
     * The user message the model gets: the question, then a short note with who is signed in (name, username,
     * groups from the token), the claim open on screen and today's date. The model needs these to answer "who am I",
     * "this claim" or "how long ago". The note is information, not authority: the MCP gateway still decides every
     * call from the verified token. After the question, not before it: a leading line changed how the model weighs
     * tool descriptions (Showcase 6's unsecured rug pull stopped reproducing). It rides on the user message, not the
     * system prompt, so the registered prompt text and its sha256 (which the release gate checks) stay unchanged.
     */
    static String withContext(String question, String authorization, String claimNumber, LocalDate today) {
        List<String> notes = new ArrayList<>();
        String username = JwtPeek.preferredUsername(authorization);
        if (username != null) {
            String name = JwtPeek.name(authorization);
            List<String> groups = JwtPeek.groups(authorization);
            notes.add("Signed in: " + (name == null ? username : name + " (" + username + ")")
                    + (groups.isEmpty() ? "" : ", groups " + String.join(", ", groups)));
        }
        if (claimNumber != null && !claimNumber.isBlank()) {
            notes.add("Open claim: " + claimNumber.trim());
        }
        notes.add("Today is " + today);
        return question + "\n\n(" + String.join(". ", notes) + ".)";
    }

    /** Ask the assistant. {@code conversationId} ties a chat session's turns together (A5 memory). */
    public AgentAnswer answer(String conversationId, String question, String claimNumber) {
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
        String promptVersion = releasedVersion();
        root.setAttribute("gen_ai.prompt.ref", promptVersion);
        String prompt = systemPrompt();
        String promptSha = sha256(prompt);
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
        // The trace's Request in MLflow: this span is the AGENT span of the turn (TraceContent).
        TraceContent.question(root, question, secured);
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
            // Agent kill switch: an operator disabled this agent's Keycloak client, so it may not act for
            // anyone. Refuse before the model is asked (the model path uses a MaaS key, not the agent identity).
            if (mcpAuth.agentRefused()) {
                LOG.warnf("assistant refused: agent %s was refused by Keycloak (client disabled) caller=%s trace=%s",
                        mcpAuth.agentId(), who, traceId);
                metrics.counter("parasol_agent_rejections_total", "reason", reason(AGENT_DISABLED), "user", who,
                        "agent", mcpAuth.agentId(), "env", env).increment();
                TraceContent.answer(root, null, AGENT_DISABLED, secured);
                return new AgentAnswer(question, null, List.of(), modelName, null,
                        who, env, AGENT_DISABLED, false, null, traceId);
            }
            String turn = withContext(question, caller.authorization(), claimNumber, LocalDate.now());
            Result<String> result = assistant.ask(conversationId, prompt, turn);
            count(result.tokenUsage());
            List<ToolCall> toolCalls = new ArrayList<>(toolCallCollector.calls());
            // The secured model path runs through the guardrails proxy, which prepends a sentinel
            // first line to the answer (option A agreed with Stream G). Split it off so the UI can
            // render the amber banner / mask chip; the remaining lines are the real answer.
            Guardrail guardrail = Guardrail.parse(result.content());
            String answer = guardrail == null ? result.content() : guardrail.strippedContent();
            // Secured: the answer may only claim an approval a tool call on this turn performed, and never a payment.
            String note = secured ? unbackedClaimNote(answer, approvedThisTurn(toolCalls)) : null;
            // Secured: a claim status or amount the answer states must match the record the user may read.
            String statusNote = secured ? statusMismatchNote(answer, this::readClaim) : null;
            if (note != null) {
                answer = answer + "\n\n" + note;
                correction("unbacked-action", who, traceId);
            }
            if (statusNote != null) {
                answer = answer + "\n\n" + statusNote;
                correction("status-mismatch", who, traceId);
            }
            // Secured: documents the gateway blocked as suspicious trigger the fraud check and a flag on the claim.
            String suspicious = secured ? suspiciousDocuments(toolCalls, claimNumber, who, traceId) : null;
            if (suspicious != null) {
                answer = answer + "\n\n" + suspicious;
            }
            // Operator-dashboard metrics: per tool call, passed (200) or refused at the MCP gateway (403/503).
            recordToolCalls(toolCalls);
            recordGuardrail(guardrail);
            // Trace semantics: name the observed steps so the MLflow/Tempo trace reads as the story
            // (guardrails.tool_result when a detector flagged a tool result).
            emitStorySpans(guardrail);
            LOG.infof("chat caller=%s agent=%s env=%s prompt=%s prompt_sha256=%.12s tools=%s guardrail=%s tokens=%s trace=%s", caller.subject(), mcpAuth.agentId(), env,
                    promptVersion, promptSha,
                    toolCalls.stream().map(ToolCall::tool).toList(),
                    guardrail == null ? "none" : guardrail.action(),
                    result.tokenUsage() == null ? "?" : result.tokenUsage().totalTokenCount(), traceId);
            TraceContent.answer(root, answer, null, secured);
            return new AgentAnswer(question, answer, toolCalls, modelName,
                    usage(result.tokenUsage()), caller.subject(), env, null, false, guardrail, traceId);
        } catch (Exception e) {
            String detail = redact(rootMessage(e));
            boolean auth = looksLikeAuthFailure(detail);
            LOG.warnf("assistant call failed (authFailure=%s): %s", auth, detail);
            String error = errorMessage(detail, auth);
            // Rejections the platform answered for this user (usage limit 429, offline, key), by reason.
            metrics.counter("parasol_agent_rejections_total", "reason", reason(error), "user", who,
                    "agent", mcpAuth.agentId(), "env", env).increment();
            TraceContent.answer(root, null, error, secured);
            return new AgentAnswer(question, null, List.of(), modelName, null,
                    caller.subject(), env, error, auth, null, traceId);
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

    static final Pattern CLAIM_ARG = Pattern.compile("\"claimNumber\"\\s*:\\s*\"([^\"]+)\"");
    static final Pattern FRAUD_RISK = Pattern.compile("FRAUD RISK: ([A-Z]+)");
    static final String SUSPICIOUS_NOTE = "Platform note: this claim's documents were flagged as suspicious (they address "
            + "the assistant, so the platform's guardrails blocked them before the model read them). The fraud check ran "
            + "on its own: %s Nothing was approved or paid.";

    /**
     * Secured: when the MCP gateway blocked a claim's documents as suspicious, the portal (a rule, not the model's
     * choice) runs the fraud check for that claim, records the flag on the claim (claims-db: the History tab and the
     * Documents list show it) and returns the note for the answer. A fraud check the model already ran on this turn is
     * reused; the automatic one is added to {@code calls}, so it shows as a chip. Null when no documents were blocked.
     */
    String suspiciousDocuments(List<ToolCall> calls, String openClaim, String who, String traceId) {
        ToolCall blocked = calls.stream().filter(c -> "get_claim_documents".equals(c.tool()) && c.blocked()
                && ToolCallRecorder.GATEWAY_500_REASON.equals(c.reason())).findFirst().orElse(null);
        if (blocked == null) {
            return null;
        }
        Matcher m = CLAIM_ARG.matcher(blocked.arguments() == null ? "" : blocked.arguments());
        String claim = m.find() ? m.group(1) : openClaim;
        if (claim == null || claim.isBlank()) {
            return null;
        }
        String verdict = calls.stream().filter(c -> "fraud_check".equals(c.tool()) && !c.blocked())
                .map(ToolCall::result).filter(r -> r != null && !r.isBlank()).findFirst().orElse(null);
        if (verdict == null) {
            String args = "{\"claimNumber\":\"" + claim + "\"}";
            try {
                verdict = fraudCheck.executeTool(ToolExecutionRequest.builder().name("fraud_check").arguments(args).build())
                        .resultText();
            } catch (RuntimeException e) {
                verdict = "FRAUD RISK: UNKNOWN. The fraud check could not run (" + redact(rootMessage(e)) + ").";
            }
            calls.add(new ToolCall("fraud_check", args, verdict, false, null));
        }
        Matcher r = FRAUD_RISK.matcher(verdict);
        String risk = r.find() ? r.group(1) : "UNKNOWN";
        try {
            claimsDb.flagDocuments(claim, mcpAuth.getAuthorization(null), Map.of("note",
                    "Documents flagged as suspicious by the platform's guardrails (MCP gateway): they address the "
                            + "assistant. Fraud check: " + risk + ". A person must review them."));
        } catch (RuntimeException e) {
            LOG.warnf("documents flag not recorded on %s: %s", claim, redact(rootMessage(e)));
        }
        LOG.warnf("suspicious documents claim=%s fraud_risk=%s caller=%s agent=%s trace=%s", claim, risk, who,
                mcpAuth.agentId(), traceId);
        String brief = verdict.length() > 300 ? verdict.substring(0, 300) + "..." : verdict;
        return String.format(SUSPICIOUS_NOTE, brief.strip());
    }

    /** A correction note the portal appended: logged, counted and named on the trace (guardrails.answer). */
    private void correction(String detector, String who, String traceId) {
        LOG.infof("guardrail action=correct detector=%s user=%s agent=%s trace=%s", detector, who,
                mcpAuth.agentId(), traceId);
        metrics.counter("parasol_guardrail_detections_total", "detector", detector, "action", "correct").increment();
        Span cs = tracer.spanBuilder("guardrails.answer").startSpan();
        cs.setAttribute("guardrail.action", "correct");
        cs.setAttribute("guardrail.detectors", detector);
        cs.end();
    }

    /**
     * parasol_tool_calls_total{tool,user,agent,status}: one count per MCP tool the model invoked on this
     * turn: 200 when it returned a result, 503 when the gateway's guardrails check was unavailable, 500 when
     * the gateway refused a (guardrails-blocked) result with HTTP 500, 403 for any other gateway refusal (the Approve path in ClaimResource counts its own 403s).
     */
    private void recordToolCalls(List<ToolCall> toolCalls) {
        String user = caller.subject();
        for (ToolCall tc : toolCalls) {
            metrics.counter("parasol_tool_calls_total", "tool", tc.tool(), "user", user, "agent", mcpAuth.agentId(),
                    "status", toolStatus(tc))
                    .increment();
        }
    }

    static String toolStatus(ToolCall tc) {
        if (!tc.blocked()) {
            return "200";
        }
        if (ToolCallRecorder.GATEWAY_500_REASON.equals(tc.reason())) {
            return "500";
        }
        return tc.reason() != null && tc.reason().startsWith(ToolCallRecorder.UNAVAILABLE) ? "503" : "403";
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

    /** The chat's answer while an operator has this agent switched off (scripts/agent-switch.sh). */
    static final String AGENT_DISABLED = "This assistant has been disabled by an operator.";

    /** The rejection reason label for {@link #errorMessage}'s message. */
    static String reason(String error) {
        if (AGENT_DISABLED.equals(error)) {
            return "agent_disabled";
        }
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
     * (the inflated-document case), with the action as the span status (block = ERROR).
     */
    private void emitStorySpans(Guardrail guardrail) {
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
                              boolean authFailure, Guardrail guardrail, String traceId) {
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
