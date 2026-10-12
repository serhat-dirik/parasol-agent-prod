package com.parasol.mcp.fraud;

import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The fraud-check agent's own tool calls (secured): claims-db tools THROUGH the MCP gateway, on behalf
 * of the user. The incoming token (exchanged by the claims agent: sub = user, azp = parasol-claims-agent)
 * is exchanged AGAIN at Keycloak as this agent (azp = parasol-fraud-agent), authenticating with the pod's
 * projected ServiceAccount token. The fraud agent's ceiling is read-only (get_claim, get_claim_documents,
 * get_claim_history), so even a manager's token can never approve a payout through it.
 */
@ApplicationScoped
public class GatewayTools {

    private static final Logger LOG = Logger.getLogger(GatewayTools.class);
    private static final Pattern ACCESS_TOKEN = Pattern.compile("\"access_token\"\\s*:\\s*\"([^\"]+)\"");
    private static final Pattern EXPIRES_IN = Pattern.compile("\"expires_in\"\\s*:\\s*(\\d+)");
    private static final Pattern ERROR = Pattern.compile("\"error_description\"\\s*:\\s*\"([^\"]*)\"");
    private static final Pattern USER = Pattern.compile("\"preferred_username\"\\s*:\\s*\"([^\"]+)\"");
    private static final String ACCEPT = "application/json, text/event-stream";

    @ConfigProperty(name = "fraud.gateway-url")
    Optional<String> gatewayUrl;

    @ConfigProperty(name = "fraud.token-url")
    Optional<String> tokenUrl;

    @ConfigProperty(name = "fraud.assertion-file")
    Optional<String> assertionFile;

    @ConfigProperty(name = "fraud.agent-id", defaultValue = "parasol-fraud-agent")
    String agentId;

    @Inject
    ObjectMapper json;

    @Inject
    Tracer tracer;

    @Inject
    OpenTelemetry otel;

    private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();

    private record Cached(String token, Instant until) {
    }

    private final Map<String, Cached> exchanged = new ConcurrentHashMap<>();

    /** True when this agent has an identity and a gateway to call through (secured). */
    public boolean enabled() {
        return gatewayUrl.filter(s -> !s.isBlank()).isPresent() && tokenUrl.filter(s -> !s.isBlank()).isPresent()
                && assertionFile.filter(s -> !s.isBlank()).isPresent();
    }

    public String agentId() {
        return agentId;
    }

    /** preferred_username of a bearer token (unvalidated peek, for attribution only), or "anonymous". */
    static String user(String bearer) {
        try {
            String payload = new String(Base64.getUrlDecoder().decode(bearer.split("\\.")[1]), StandardCharsets.UTF_8);
            Matcher m = USER.matcher(payload);
            return m.find() ? m.group(1) : "anonymous";
        } catch (RuntimeException e) {
            return "anonymous";
        }
    }

    /** Exchange the caller's token as this agent (cached per incoming token), or null on failure. */
    public String onBehalfOf(String subjectToken) {
        Cached c = exchanged.get(subjectToken);
        if (c != null && Instant.now().isBefore(c.until())) {
            return c.token();
        }
        try {
            String assertion = Files.readString(Path.of(assertionFile.get())).trim();
            String form = "grant_type=" + enc("urn:ietf:params:oauth:grant-type:token-exchange")
                    + "&subject_token=" + enc(subjectToken)
                    + "&subject_token_type=" + enc("urn:ietf:params:oauth:token-type:access_token")
                    + "&client_assertion_type=" + enc("urn:ietf:params:oauth:client-assertion-type:jwt-bearer")
                    + "&client_assertion=" + enc(assertion);
            HttpResponse<String> res = http.send(HttpRequest.newBuilder(URI.create(tokenUrl.get()))
                    .timeout(Duration.ofSeconds(10))
                    .header("Content-Type", "application/x-www-form-urlencoded")
                    .POST(HttpRequest.BodyPublishers.ofString(form)).build(), HttpResponse.BodyHandlers.ofString());
            Matcher t = ACCESS_TOKEN.matcher(res.body());
            if (res.statusCode() != 200 || !t.find()) {
                Matcher e = ERROR.matcher(res.body());
                LOG.warnf("token exchange as %s failed: HTTP %d %s", agentId, res.statusCode(), e.find() ? e.group(1) : "");
                return null;
            }
            Matcher e = EXPIRES_IN.matcher(res.body());
            long expires = e.find() ? Long.parseLong(e.group(1)) : 300;
            if (exchanged.size() > 500) {   // ponytail: sweep on insert, a real cache if callers ever number thousands
                Instant now = Instant.now();
                exchanged.values().removeIf(v -> now.isAfter(v.until()));
            }
            exchanged.put(subjectToken, new Cached(t.group(1), Instant.now().plusSeconds(Math.max(10, expires - 30))));
            return t.group(1);
        } catch (IOException | InterruptedException | RuntimeException ex) {
            LOG.warnf("token exchange as %s error: %s", agentId, ex.getMessage());
            return null;
        }
    }

    /**
     * Call one claims-db tool through the MCP gateway (initialize, initialized, tools/call) and return
     * its text result. A gateway refusal (403) or a tool error becomes an IllegalStateException.
     */
    public String callClaimsDb(String token, String tool, String claimNumber) {
        Span span = tracer.spanBuilder("tool." + tool).startSpan();
        span.setAttribute("tool.name", tool);
        span.setAttribute("gen_ai.agent.name", agentId);
        span.setAttribute("enduser.id", user(token));
        try (Scope ignored = span.makeCurrent()) {
            HttpResponse<String> init = post(token, null,
                    "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\","
                            + "\"capabilities\":{},\"clientInfo\":{\"name\":\"" + agentId + "\",\"version\":\"1\"}}}");
            check(init, tool);
            String session = init.headers().firstValue("mcp-session-id").orElse(null);
            post(token, session, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
            String args = json.writeValueAsString(Map.of("claimNumber", claimNumber));
            HttpResponse<String> res = post(token, session, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\","
                    + "\"params\":{\"name\":\"" + tool + "\",\"arguments\":" + args + "}}");
            check(res, tool);
            JsonNode body = json.readTree(rpcBody(res.body()));
            if (body.has("error")) {
                throw new IllegalStateException(tool + ": " + body.get("error").path("message").asText());
            }
            StringBuilder text = new StringBuilder();
            for (JsonNode c : body.path("result").path("content")) {
                text.append(c.path("text").asText());
            }
            return text.toString();
        } catch (IOException | InterruptedException e) {
            span.setStatus(StatusCode.ERROR, e.getMessage());
            throw new IllegalStateException(tool + " via gateway: " + e.getMessage(), e);
        } catch (RuntimeException e) {
            span.setStatus(StatusCode.ERROR, e.getMessage());
            throw e;
        } finally {
            span.end();
        }
    }

    private HttpResponse<String> post(String token, String session, String body) throws IOException, InterruptedException {
        HttpRequest.Builder b = HttpRequest.newBuilder(URI.create(gatewayUrl.get()))
                .timeout(Duration.ofSeconds(30))
                .header("Authorization", "Bearer " + token)
                .header("Content-Type", "application/json")
                .header("Accept", ACCEPT)
                .header("X-Mcp-Virtualserver", "parasol-secured/claims-db");
        if (session != null) {
            b.header("mcp-session-id", session);
        }
        // trace context, so the claims-db spans join this agent-to-agent trace
        otel.getPropagators().getTextMapPropagator().inject(Context.current(), b, HttpRequest.Builder::header);
        return http.send(b.POST(HttpRequest.BodyPublishers.ofString(body)).build(), HttpResponse.BodyHandlers.ofString());
    }

    private static void check(HttpResponse<String> res, String tool) {
        if (res.statusCode() >= 300) {
            throw new IllegalStateException("gateway refused " + tool + " (HTTP " + res.statusCode() + "): "
                    + res.body().strip());
        }
    }

    /** A streamable-HTTP response is either plain JSON or an SSE stream whose data: line is the JSON. */
    private static String rpcBody(String body) {
        String b = body.strip();
        if (b.startsWith("{")) {
            return b;
        }
        for (String line : b.split("\n")) {
            if (line.startsWith("data:")) {
                return line.substring(5).strip();
            }
        }
        return "{}";
    }

    private static String enc(String s) {
        return URLEncoder.encode(s, StandardCharsets.UTF_8);
    }
}
