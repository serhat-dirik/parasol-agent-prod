package org.parasol.ai;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.Optional;
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
 * <p>Resolution order, first match wins:
 * <ol>
 *   <li>The caller's own bearer token, captured from the incoming {@code POST /agent/ask}
 *       request ({@link CallerIdentity}). The agent acts as the person asking.</li>
 *   <li>A service identity obtained from Keycloak with the password grant
 *       ({@code MCP_AUTH_TOKEN_URL}, {@code MCP_AUTH_CLIENT_ID}, {@code MCP_AUTH_USERNAME},
 *       {@code MCP_AUTH_PASSWORD}), cached until shortly before expiry. Used for the readiness
 *       ping and for a "one agent per user" deployment where the user is fixed by configuration.</li>
 *   <li>A static token ({@code MCP_BEARER_TOKEN}).</li>
 *   <li>Nothing: no header is sent. This is the "free" environment, where the MCP servers are
 *       reached directly and nobody asks who is calling.</li>
 * </ol>
 */
@ApplicationScoped
public class McpBearerTokenProvider implements McpClientAuthProvider {

    private static final Logger LOG = Logger.getLogger(McpBearerTokenProvider.class);
    private static final Pattern ACCESS_TOKEN = Pattern.compile("\"access_token\"\\s*:\\s*\"([^\"]+)\"");
    private static final Pattern EXPIRES_IN = Pattern.compile("\"expires_in\"\\s*:\\s*(\\d+)");

    @ConfigProperty(name = "mcp-auth.token-url")
    Optional<String> tokenUrl;

    @ConfigProperty(name = "mcp-auth.client-id", defaultValue = "parasol-agent")
    String clientId;

    @ConfigProperty(name = "mcp-auth.client-secret")
    Optional<String> clientSecret;

    @ConfigProperty(name = "mcp-auth.username")
    Optional<String> username;

    @ConfigProperty(name = "mcp-auth.password")
    Optional<String> password;

    @ConfigProperty(name = "mcp-auth.static-token")
    Optional<String> staticToken;

    private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();

    private volatile String cachedToken;
    private volatile Instant cachedUntil = Instant.EPOCH;

    @Override
    public String getAuthorization(Input input) {
        String caller = callerAuthorization();
        if (caller != null) {
            return caller;
        }
        if (tokenUrl.isPresent() && username.isPresent() && password.isPresent()) {
            String token = serviceToken();
            if (token != null) {
                return "Bearer " + token;
            }
        }
        return staticToken.filter(t -> !t.isBlank()).map(t -> "Bearer " + t).orElse(null);
    }

    /** What identity the agent would present right now (for /agent/info and logs). */
    public String describe() {
        if (callerAuthorization() != null) {
            return "caller token forwarded";
        }
        if (tokenUrl.isPresent() && username.isPresent()) {
            return "service identity " + username.get() + " via " + tokenUrl.get();
        }
        if (staticToken.filter(t -> !t.isBlank()).isPresent()) {
            return "static token";
        }
        return "none (anonymous to tools)";
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
            // Not inside a REST request (readiness ping, startup tool discovery): fall through.
        }
        return null;
    }

    private String serviceToken() {
        if (cachedToken != null && Instant.now().isBefore(cachedUntil)) {
            return cachedToken;
        }
        synchronized (this) {
            if (cachedToken != null && Instant.now().isBefore(cachedUntil)) {
                return cachedToken;
            }
            try {
                StringBuilder form = new StringBuilder("grant_type=password")
                        .append("&client_id=").append(enc(clientId))
                        .append("&username=").append(enc(username.get()))
                        .append("&password=").append(enc(password.get()))
                        .append("&scope=openid");
                clientSecret.filter(s -> !s.isBlank()).ifPresent(s -> form.append("&client_secret=").append(enc(s)));
                HttpRequest req = HttpRequest.newBuilder(URI.create(tokenUrl.get()))
                        .timeout(Duration.ofSeconds(10))
                        .header("Content-Type", "application/x-www-form-urlencoded")
                        .POST(HttpRequest.BodyPublishers.ofString(form.toString()))
                        .build();
                HttpResponse<String> res = http.send(req, HttpResponse.BodyHandlers.ofString());
                if (res.statusCode() != 200) {
                    LOG.warnf("Keycloak token request failed: HTTP %d", res.statusCode());
                    return null;
                }
                Matcher t = ACCESS_TOKEN.matcher(res.body());
                if (!t.find()) {
                    LOG.warn("Keycloak token response had no access_token");
                    return null;
                }
                long expires = 300;
                Matcher e = EXPIRES_IN.matcher(res.body());
                if (e.find()) {
                    expires = Long.parseLong(e.group(1));
                }
                cachedToken = t.group(1);
                cachedUntil = Instant.now().plusSeconds(Math.max(30, expires - 30));
                LOG.infof("Obtained service identity token for %s (valid %ds)", username.get(), expires);
                return cachedToken;
            } catch (Exception ex) {
                LOG.warnf("Keycloak token request error: %s", ex.getMessage());
                return null;
            }
        }
    }

    private static String enc(String s) {
        return URLEncoder.encode(s, StandardCharsets.UTF_8);
    }
}
