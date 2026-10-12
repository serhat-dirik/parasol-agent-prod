package com.parasol.mcp.claims;

import java.math.BigInteger;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.PublicKey;
import java.security.Signature;
import java.security.spec.RSAPublicKeySpec;
import java.time.Duration;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import io.micrometer.core.instrument.MeterRegistry;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.StatusCode;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Record-level access for the claims tools (secured): an adjuster reads only the claims assigned to
 * them; claims-managers read every claim. The caller is the user in the on-behalf-of token the agent
 * presents through the MCP gateway, verified here against Keycloak's signing keys (signature, issuer,
 * expiry, audience parasol-secured/claims-db): what the user types in the chat cannot widen it.
 * Off unless {@code claims.acl.enforce=true} (free keeps the unfiltered baseline).
 *
 * <p>Every refusal is one log line ({@code CLAIMS ACL denied ...}), one count of
 * {@code parasol_claims_access_denied_total{tool,user,agent}} and attributes on the current server span,
 * which joins the portal's chat trace in MLflow.
 */
@ApplicationScoped
public class RecordAccess {

    private static final Logger LOG = Logger.getLogger(RecordAccess.class);
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final Base64.Decoder B64 = Base64.getUrlDecoder();
    static final String MANAGERS = "claims-managers";
    static final String AUDIENCE = "parasol-secured/claims-db";

    /** The verified caller: user, display name (matches the claim's adjuster), groups, agent (azp). */
    public record Caller(String user, String name, List<String> groups, String agent) {
        boolean manager() {
            return groups.contains(MANAGERS);
        }

        boolean mayRead(ClaimView c) {
            return manager() || (name != null && name.equalsIgnoreCase(c.adjuster()));
        }
    }

    /** Thrown when the call carries no valid token: deny by default. */
    public static class Denied extends RuntimeException {
        Denied(String m) {
            super(m);
        }
    }

    @ConfigProperty(name = "claims.acl.enforce", defaultValue = "false")
    boolean enforce;

    /** e.g. https://sso.apps.example.com/realms/parasol/protocol/openid-connect/token (agent-config tokenUrl). */
    @ConfigProperty(name = "claims.acl.token-url")
    Optional<String> tokenUrl;

    @Inject
    MeterRegistry metrics;

    final Map<String, PublicKey> keys = new ConcurrentHashMap<>();   // kid -> key (package-private for the test)
    private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
    private volatile long lastFetch;

    public boolean enforced() {
        return enforce;
    }

    String issuer() {
        return tokenUrl.map(u -> u.split("/protocol/")[0]).orElseThrow(() -> new Denied("claims.acl.token-url not set"));
    }

    /** Verify the bearer token of this call; throws {@link Denied} when it is missing or invalid. */
    public Caller verify(String authorization) {
        if (authorization == null || !authorization.startsWith("Bearer ")) {
            throw new Denied("no caller token");
        }
        try {
            String[] p = authorization.substring(7).trim().split("\\.");
            JsonNode header = JSON.readTree(B64.decode(p[0]));
            JsonNode claims = JSON.readTree(B64.decode(p[1]));
            if (!"RS256".equals(header.path("alg").asText())) {
                throw new Denied("unsupported token algorithm");
            }
            Signature sig = Signature.getInstance("SHA256withRSA");
            sig.initVerify(key(header.path("kid").asText()));
            sig.update((p[0] + "." + p[1]).getBytes(StandardCharsets.US_ASCII));
            if (!sig.verify(B64.decode(p[2]))) {
                throw new Denied("bad token signature");
            }
            if (claims.path("exp").asLong() * 1000 < System.currentTimeMillis()) {
                throw new Denied("token expired");
            }
            if (!issuer().equals(claims.path("iss").asText())) {
                throw new Denied("token from another issuer");
            }
            JsonNode aud = claims.path("aud");
            boolean audOk = aud.isArray() ? contains(aud, AUDIENCE) : AUDIENCE.equals(aud.asText());
            if (!audOk) {
                throw new Denied("token not issued for claims-db");
            }
            List<String> groups = claims.path("groups").isArray()
                    ? JSON.convertValue(claims.path("groups"), JSON.getTypeFactory().constructCollectionType(List.class, String.class))
                    : List.of();
            return new Caller(claims.path("preferred_username").asText(null), claims.path("name").asText(null),
                    groups, claims.path("azp").asText(null));
        } catch (Denied d) {
            throw d;
        } catch (Exception e) {
            throw new Denied("invalid token (" + e.getClass().getSimpleName() + ")");
        }
    }

    private static boolean contains(JsonNode array, String value) {
        for (JsonNode n : array) {
            if (value.equals(n.asText())) {
                return true;
            }
        }
        return false;
    }

    /** The realm's signing key by kid; the JWKS is re-read on an unknown kid, at most every 30 s. */
    private PublicKey key(String kid) throws Exception {
        PublicKey k = keys.get(kid);
        if (k == null && System.currentTimeMillis() - lastFetch > 30_000) {
            lastFetch = System.currentTimeMillis();
            HttpResponse<String> r = http.send(HttpRequest.newBuilder(URI.create(issuer() + "/protocol/openid-connect/certs"))
                    .timeout(Duration.ofSeconds(10)).build(), HttpResponse.BodyHandlers.ofString());
            for (JsonNode j : JSON.readTree(r.body()).path("keys")) {
                if ("RSA".equals(j.path("kty").asText()) && "sig".equals(j.path("use").asText("sig"))) {
                    keys.put(j.path("kid").asText(), KeyFactory.getInstance("RSA").generatePublic(new RSAPublicKeySpec(
                            new BigInteger(1, B64.decode(j.path("n").asText())), new BigInteger(1, B64.decode(j.path("e").asText())))));
                }
            }
            k = keys.get(kid);
        }
        if (k == null) {
            throw new Denied("unknown signing key");
        }
        return k;
    }

    /** Record and explain one refusal: log line, metric, and the attributes on the current server span. */
    public String refuse(String tool, String claimNumber, Caller who, String reason) {
        String user = who == null ? "-" : who.user();
        String agent = who == null ? "-" : who.agent();
        LOG.infof("CLAIMS ACL denied tool=%s claim=%s user=%s via %s reason=%s", tool, claimNumber, user, agent, reason);
        metrics.counter("parasol_claims_access_denied_total", "tool", tool, "user", user, "agent", agent).increment();
        Span s = Span.current();
        s.setAttribute("claims.access", "denied");
        s.setAttribute("claims.claim_number", String.valueOf(claimNumber));
        s.setAttribute("claims.access_reason", reason);
        s.setAttribute("enduser.id", user);
        s.setAttribute("gen_ai.agent.name", agent);
        s.setStatus(StatusCode.ERROR, "record access denied");
        return "Access denied: " + (who == null ? "this call carries no valid user token"
                : (who.name() == null ? user : who.name() + " (" + user + ")") + " may not read claim " + claimNumber
                        + ". Adjusters can read only the claims assigned to them; a claims manager can read every claim.");
    }

    /** Mark the current server span as an allowed record read (the other half of the evidence). */
    public void allowed(Caller who) {
        Span s = Span.current();
        s.setAttribute("claims.access", "allowed");
        s.setAttribute("enduser.id", String.valueOf(who.user()));
        s.setAttribute("gen_ai.agent.name", String.valueOf(who.agent()));
    }
}
