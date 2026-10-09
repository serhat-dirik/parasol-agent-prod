package com.parasol.agent;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import dev.langchain4j.mcp.client.McpClient;
import dev.langchain4j.model.output.TokenUsage;
import io.micrometer.core.instrument.MeterRegistry;
import io.quarkiverse.langchain4j.mcp.runtime.McpClientName;
import dev.langchain4j.service.Result;
import dev.langchain4j.service.tool.ToolExecution;
import io.smallrye.common.annotation.Blocking;
import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

/**
 * REST surface for the Parasol agent.
 *
 * <pre>
 *   POST /agent/ask    ask the agent a claims/policy question; returns the answer,
 *                      the tools it called (name + arguments + result), and token usage
 *   GET  /agent/info   the model + MCP wiring the agent is configured with (no model call)
 * </pre>
 *
 * <p>{@code /ask} is {@code @Blocking}: the model + MCP tool round-trips take seconds, so the
 * call runs on a worker thread, never the event loop. Model failures (including an expired MaaS
 * key -&gt; HTTP 401) are caught and returned as a clean {@code 502} with an {@code authFailure}
 * flag, so a short-lived key degrades gracefully instead of throwing a stack trace at the caller.
 */
@Path("/agent")
@Produces(MediaType.APPLICATION_JSON)
@Consumes(MediaType.APPLICATION_JSON)
public class AgentResource {

    private static final Logger LOG = Logger.getLogger(AgentResource.class);

    @Inject
    ClaimsAssistant assistant;

    @Inject
    ToolCallCollector toolCallCollector;

    @ConfigProperty(name = "quarkus.langchain4j.openai.chat-model.model-name", defaultValue = "unknown")
    String modelName;

    @ConfigProperty(name = "quarkus.langchain4j.mcp.claims-db.url", defaultValue = "")
    String claimsDbUrl;

    @ConfigProperty(name = "quarkus.langchain4j.mcp.policy-docs.url", defaultValue = "")
    String policyDocsUrl;

    /** Extra rules appended to the system prompt (AGENT_SAFETY_RULES). Empty = the laptop prompt. */
    @ConfigProperty(name = "agent.safety-rules")
    Optional<String> safetyRulesConfig;

    private String safetyRules() {
        return safetyRulesConfig.orElse("");
    }

    /** Version label shown in /agent/info and responses (AGENT_VERSION). */
    @ConfigProperty(name = "agent.version", defaultValue = "dev")
    String version;

    /**
     * The "v3 bug": how many times to re-ask the model when the answer does not look complete.
     * 0 (the default) means never. v3 ships with a large value and a completeness check that can
     * never be satisfied, so a single question turns into a token storm. See storm() below.
     */
    @ConfigProperty(name = "agent.retry.max", defaultValue = "0")
    int retryMax;

    @ConfigProperty(name = "agent.retry.until-contains", defaultValue = "PaymentIssued")
    String retryUntilContains;

    @Inject
    CallerIdentity caller;

    @Inject
    McpBearerTokenProvider mcpAuth;

    @Inject
    MeterRegistry metrics;

    @Inject
    @McpClientName("claims-db")
    McpClient claimsDb;

    @Inject
    @McpClientName("policy-docs")
    McpClient policyDocs;

    /** Ask the agent a question. The model decides which MCP tools to call to answer it. */
    @POST
    @Path("/ask")
    @Blocking
    public Response ask(AskRequest request) {
        if (request == null || request.question() == null || request.question().isBlank()) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(new AskError("question is required", null, false, modelName))
                    .build();
        }
        try {
            // Fresh memory id per request: no cross-request history, but the tool-calling
            // round-trip within THIS request still has somewhere to hold its messages.
            Result<String> result = assistant.ask(UUID.randomUUID().toString(), safetyRules(), request.question());
            count(result.tokenUsage());
            // The v3 retry bug: keep asking until the answer "looks complete". With the shipped
            // settings it never does, so one question becomes retryMax model round-trips.
            int attempts = 1;
            while (retryMax > 0 && attempts <= retryMax
                    && (result.content() == null || !result.content().contains(retryUntilContains))) {
                LOG.infof("answer incomplete (attempt %d/%d), retrying", attempts, retryMax);
                result = assistant.ask(UUID.randomUUID().toString(), safetyRules(), request.question());
                count(result.tokenUsage());
                attempts++;
            }
            // The ChatModelListener records MCP tool calls (name + arguments) into the request-
            // scoped collector; Result.toolExecutions() only covers local @Tool beans, so prefer
            // the collector and fall back to toolExecutions() if it captured nothing.
            List<ToolCall> toolCalls = toolCallCollector.calls();
            if (toolCalls.isEmpty()) {
                toolCalls = result.toolExecutions().stream()
                        .map(AgentResource::toToolCall)
                        .toList();
            }
            LOG.infof("ask caller=%s version=%s tools=%s tokens=%s", caller.subject(), version,
                    toolCalls.stream().map(ToolCall::tool).toList(),
                    result.tokenUsage() == null ? "?" : result.tokenUsage().totalTokenCount());
            return Response.ok(new AskResponse(
                    request.question(),
                    result.content(),
                    toolCalls,
                    modelName,
                    usage(result.tokenUsage()),
                    caller.subject(),
                    version)).build();
        } catch (Exception e) {
            String detail = redactCredentials(rootMessage(e));
            boolean auth = looksLikeAuthFailure(detail);
            // The throwable is deliberately NOT handed to the logger: printStackTrace writes every
            // cause's raw getMessage(), which is the exact text the gateway echoes the key back in,
            // and it lands BELOW the line a reader greps for. Log the redacted detail plus the cause
            // chain (types only) - same diagnostic value, no credential on any line.
            LOG.warnf("Agent model call failed (authFailure=%s): %s [%s]", auth, detail, causeChain(e));
            String error = auth
                    ? "model authentication failed - check the MaaS key (GENAI_API_KEY); it may be expired"
                    : "the model call failed";
            return Response.status(Response.Status.BAD_GATEWAY)
                    .entity(new AskError(error, detail, auth, modelName))
                    .build();
        }
    }

    /** What the agent is wired to talk to. Handy for a smoke check without spending a token. */
    @GET
    @Path("/info")
    public Response info() {
        return Response.ok(new AgentInfo(modelName, claimsDbUrl, policyDocsUrl, version,
                mcpAuth.describe(), !safetyRules().isBlank(), retryMax)).build();
    }

    /**
     * The tools the agent can see RIGHT NOW, as the caller. In the secured environment the MCP
     * gateway filters this list per identity, so an adjuster and a claims manager get different
     * answers from the same agent. In the free environment everybody sees everything.
     */
    @GET
    @Path("/tools")
    @Blocking
    public Response tools() {
        try {
            List<String> claims = claimsDb.listTools().stream().map(t -> t.name()).sorted().toList();
            List<String> policies = policyDocs.listTools().stream().map(t -> t.name()).sorted().toList();
            return Response.ok(Map.of(
                    "caller", caller.subject(),
                    "identity", mcpAuth.describe(),
                    "claims-db", claims,
                    "policy-docs", policies)).build();
        } catch (Exception e) {
            String detail = redactCredentials(rootMessage(e));
            LOG.warnf("tools/list failed for caller=%s: %s", caller.subject(), detail);
            return Response.status(Response.Status.BAD_GATEWAY)
                    .entity(Map.of("caller", caller.subject(), "error", detail)).build();
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

    private static ToolCall toToolCall(ToolExecution execution) {
        return new ToolCall(
                execution.request().name(),
                execution.request().arguments(),
                execution.result());
    }

    private static Usage usage(TokenUsage tokenUsage) {
        if (tokenUsage == null) {
            return null;
        }
        return new Usage(
                tokenUsage.inputTokenCount(),
                tokenUsage.outputTokenCount(),
                tokenUsage.totalTokenCount());
    }

    /**
     * Blank credential material out of an upstream message before it is logged or returned.
     *
     * <p>WHY THIS EXISTS. The model gateway echoes the rejected key back <em>in full</em> inside its
     * own 401 body ({@code Virtual Key expected. Received=<the key>, expected to start with 'sk-'}).
     * That body becomes {@code detail}, and {@code detail} goes to two places a person reads: the
     * pod log, and {@link AskError#detail()} - which is serialised into the 502 JSON the attendee
     * gets back from {@code POST /agent/ask}. So the credential was one wording change away from
     * being printed in an attendee's terminal.
     *
     * <p>Redaction, never truncation. The near-miss that prompted this was a {@code cut -c1-200} on
     * the log line that cleared the echoed key by TEN characters - safety by accident of arithmetic.
     * A character count is not a defence; naming the thing is.
     *
     * <p>Deliberately shape-based and deliberately narrow. It blanks the value of the gateway's
     * {@code Received=} field and any {@code sk-} or JWT shaped token, and leaves the rest of the
     * sentence alone: the reader still has to be able to tell the three key faults apart (expired /
     * wrong kind of credential / scoped to a different model), and the last of those is diagnosed
     * from a {@code models=[...]} list that must survive. The {@code sk-}/{@code eyJ} prefix is kept
     * on purpose so "you sent a JWT where an API key was expected" is still readable after redaction.
     */
    static String redactCredentials(String message) {
        if (message == null) {
            return null;
        }
        String out = RECEIVED_FIELD.matcher(message).replaceAll("Received=<redacted>");
        out = BEARER_TOKEN.matcher(out).replaceAll("$1 <redacted>");
        return KEY_SHAPED.matcher(out).replaceAll("$1<redacted>");
    }

    /** The gateway's echo-back field. Value ends at the comma (or space) that resumes the sentence. */
    private static final java.util.regex.Pattern RECEIVED_FIELD =
            java.util.regex.Pattern.compile("Received=[^,\\s]*");

    /** An Authorization header quoted back at us by a client library that logs the request. */
    private static final java.util.regex.Pattern BEARER_TOKEN =
            java.util.regex.Pattern.compile("(?i)(Bearer)\\s+[A-Za-z0-9._~+/=-]{8,}");

    /** The two credential shapes this workshop actually handles: a MaaS virtual key, and a JWT. */
    private static final java.util.regex.Pattern KEY_SHAPED =
            java.util.regex.Pattern.compile("(sk-|eyJ)[A-Za-z0-9._~+/=-]{8,}");

    /**
     * The exception chain as class names only, root-ward - e.g. {@code RuntimeException -> HttpException}.
     * Types, never messages: this is the part of a stack trace that is safe to log verbatim.
     */
    static String causeChain(Throwable t) {
        StringBuilder chain = new StringBuilder();
        Throwable current = t;
        while (current != null) {
            if (chain.length() > 0) {
                chain.append(" -> ");
            }
            chain.append(current.getClass().getSimpleName());
            current = current.getCause() == current ? null : current.getCause();
        }
        return chain.toString();
    }

    /** Unwrap to the deepest cause so the caller sees the real reason (e.g. the HTTP 401). */
    static String rootMessage(Throwable t) {
        Throwable current = t;
        while (current.getCause() != null && current.getCause() != current) {
            current = current.getCause();
        }
        String message = current.getMessage();
        return message == null ? current.getClass().getSimpleName() : message;
    }

    static boolean looksLikeAuthFailure(String detail) {
        if (detail == null) {
            return false;
        }
        String lower = detail.toLowerCase();
        return lower.contains("401") || lower.contains("403")
                || lower.contains("unauthorized") || lower.contains("authentication")
                || lower.contains("invalid api key") || lower.contains("invalid_api_key");
    }

    /** Request body for {@code POST /agent/ask}. */
    public record AskRequest(String question) {
    }

    /** Token accounting for one answer (null fields when the provider does not report usage). */
    public record Usage(Integer inputTokens, Integer outputTokens, Integer totalTokens) {
    }

    /** Success body for {@code POST /agent/ask}. */
    public record AskResponse(String question, String answer, List<ToolCall> toolCalls,
                              String model, Usage tokenUsage, String caller, String version) {
    }

    /** Error body for {@code POST /agent/ask} (bad input or an upstream model failure). */
    public record AskError(String error, String detail, boolean authFailure, String model) {
    }

    /** Body for {@code GET /agent/info}. */
    public record AgentInfo(String model, String claimsDbMcpUrl, String policyDocsMcpUrl,
                            String version, String toolIdentity, boolean safetyRules, int retryMax) {
    }
}
