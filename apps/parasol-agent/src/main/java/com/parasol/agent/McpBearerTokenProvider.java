package com.parasol.agent;

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
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import io.quarkiverse.langchain4j.mcp.auth.McpClientAuthProvider;
import io.quarkus.arc.Arc;
import io.quarkus.arc.InstanceHandle;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.context.ContextNotActiveException;

/**
 * Supplies the {@code Authorization} header for every call the agent makes to its MCP servers.
 *
 * <p>Secured (agent identity configured: {@code MCP_AUTH_TOKEN_URL} + {@code MCP_AUTH_ASSERTION_FILE}):
 * the agent acts ON BEHALF OF the person asking. It exchanges the caller's token at Keycloak
 * (OAuth 2.0 token exchange, RFC 8693), authenticating as its own client with its pod's projected
 * ServiceAccount token as a client assertion (no client secret). The result has sub = the user,
 * azp = the agent, and only the tool roles that are both the user's and inside the agent's ceiling.
 * Exchanged tokens are cached per caller token until shortly before expiry. Without a caller (startup
 * tool discovery), the agent presents its own service-account token (client_credentials), which
 * carries no tool roles.
 *
 * <p>Otherwise: the caller's token is forwarded unchanged if there is one, else a static token
 * ({@code MCP_BEARER_TOKEN}), else nothing (the "free" environment: nobody asks who is calling).
 */
@ApplicationScoped
public class McpBearerTokenProvider implements McpClientAuthProvider {

    private static final Logger LOG = Logger.getLogger(McpBearerTokenProvider.class);
    private static final Pattern ACCESS_TOKEN = Pattern.compile("\"access_token\"\\s*:\\s*\"([^\"]+)\"");
    private static final Pattern EXPIRES_IN = Pattern.compile("\"expires_in\"\\s*:\\s*(\\d+)");
    private static final Pattern ERROR = Pattern.compile("\"error_description\"\\s*:\\s*\"([^\"]*)\"");
    private static final String TOKEN_EXCHANGE = "urn:ietf:params:oauth:grant-type:token-exchange";
    private static final String ACCESS_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:access_token";
    private static final String JWT_BEARER = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer";

    @ConfigProperty(name = "mcp-auth.token-url")
    Optional<String> tokenUrl;

    /** The agent's Keycloak client id: its identity in tokens (azp), metrics, logs and traces. */
    @ConfigProperty(name = "mcp-auth.agent-id", defaultValue = "none")
    String agentId;

    /** Projected ServiceAccount token (audience = the realm issuer), re-read on every use (kubelet rotates it). */
    @ConfigProperty(name = "mcp-auth.assertion-file")
    Optional<String> assertionFile;

    @ConfigProperty(name = "mcp-auth.static-token")
    Optional<String> staticToken;

    private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();

    private record Cached(String token, Instant until) {
    }

    private final Map<String, Cached> exchanged = new ConcurrentHashMap<>();
    private volatile Cached own;

    @Override
    public String getAuthorization(Input input) {
        String caller = callerAuthorization();
        if (!agentIdentity()) {
            return caller != null ? caller
                    : staticToken.filter(t -> !t.isBlank()).map(t -> "Bearer " + t).orElse(null);
        }
        String token = caller != null ? onBehalfOf(caller.substring(caller.indexOf(' ') + 1).trim()) : ownToken();
        // Fail closed: no exchanged token means no token at all (the gateway then answers 401).
        return token == null ? null : "Bearer " + token;
    }

    /** The agent's name as it appears in tokens (azp), metrics and traces; "none" when it has no identity. */
    public String agentId() {
        return agentIdentity() ? agentId : "none";
    }

    /** What identity the agent would present right now (for /agent/info and logs). */
    public String describe() {
        boolean caller = callerAuthorization() != null;
        if (agentIdentity()) {
            return caller ? "caller token exchanged on behalf of the caller by " + agentId
                    : "own service-account token of " + agentId;
        }
        if (caller) {
            return "caller token forwarded";
        }
        return staticToken.filter(t -> !t.isBlank()).isPresent() ? "static token" : "none (anonymous to tools)";
    }

    private boolean agentIdentity() {
        return tokenUrl.filter(s -> !s.isBlank()).isPresent() && assertionFile.filter(s -> !s.isBlank()).isPresent();
    }

    private static String callerAuthorization() {
        try {
            InstanceHandle<CallerIdentity> handle = Arc.container().instance(CallerIdentity.class);
            if (handle.isAvailable()) {
                String auth = handle.get().authorization();
                if (auth != null && !auth.isBlank()) {
                    return auth;
                }
            }
        } catch (ContextNotActiveException e) {
            // Not inside a request (startup tool discovery): fall through.
        }
        return null;
    }

    /** Exchange the caller's token for one the agent may use on the caller's behalf (cached per caller token). */
    private String onBehalfOf(String subjectToken) {
        Cached c = exchanged.get(subjectToken);
        if (c != null && Instant.now().isBefore(c.until())) {
            return c.token();
        }
        Cached fresh = request("grant_type=" + TOKEN_EXCHANGE
                + "&subject_token=" + enc(subjectToken)
                + "&subject_token_type=" + enc(ACCESS_TOKEN_TYPE)
                + "&requested_token_type=" + enc(ACCESS_TOKEN_TYPE), "token exchange");
        if (fresh == null) {
            return null;
        }
        if (exchanged.size() > 500) {   // ponytail: sweep on insert, a real cache if callers ever number thousands
            Instant now = Instant.now();
            exchanged.values().removeIf(v -> now.isAfter(v.until()));
        }
        exchanged.put(subjectToken, fresh);
        return fresh.token();
    }

    private String ownToken() {
        Cached c = own;
        if (c != null && Instant.now().isBefore(c.until())) {
            return c.token();
        }
        own = request("grant_type=client_credentials", "client credentials");
        return own == null ? null : own.token();
    }

    private Cached request(String form, String what) {
        try {
            String assertion = Files.readString(Path.of(assertionFile.get())).trim();
            HttpRequest req = HttpRequest.newBuilder(URI.create(tokenUrl.get()))
                    .timeout(Duration.ofSeconds(10))
                    .header("Content-Type", "application/x-www-form-urlencoded")
                    .POST(HttpRequest.BodyPublishers.ofString(form
                            + "&client_assertion_type=" + enc(JWT_BEARER)
                            + "&client_assertion=" + enc(assertion)))
                    .build();
            HttpResponse<String> res = http.send(req, HttpResponse.BodyHandlers.ofString());
            Matcher t = ACCESS_TOKEN.matcher(res.body());
            if (res.statusCode() != 200 || !t.find()) {
                Matcher e = ERROR.matcher(res.body());
                LOG.warnf("%s as %s failed: HTTP %d %s", what, agentId, res.statusCode(), e.find() ? e.group(1) : "");
                return null;
            }
            long expires = 300;
            Matcher e = EXPIRES_IN.matcher(res.body());
            if (e.find()) {
                expires = Long.parseLong(e.group(1));
            }
            return new Cached(t.group(1), Instant.now().plusSeconds(Math.max(10, expires - 30)));
        } catch (IOException | InterruptedException | RuntimeException ex) {
            LOG.warnf("%s as %s error: %s", what, agentId, ex.getMessage());
            return null;
        }
    }

    private static String enc(String s) {
        return URLEncoder.encode(s, StandardCharsets.UTF_8);
    }
}
