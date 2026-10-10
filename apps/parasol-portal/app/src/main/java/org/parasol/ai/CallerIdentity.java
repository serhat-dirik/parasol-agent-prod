package org.parasol.ai;

import java.io.IOException;

import jakarta.enterprise.context.RequestScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.container.ContainerRequestContext;
import jakarta.ws.rs.container.ContainerRequestFilter;
import jakarta.ws.rs.core.HttpHeaders;
import jakarta.ws.rs.ext.Provider;

/**
 * Captures the caller's {@code Authorization} header on every REST request so the agent can act
 * AS THE CALLER towards its tools (see {@link McpBearerTokenProvider}).
 *
 * <p>This is the single most important change between the "free" and the "secured" environment:
 * the agent no longer talks to its tools as an anonymous service, it carries the human's identity
 * to the MCP gateway, and the gateway decides per person which tools exist and which calls pass.
 */
@RequestScoped
public class CallerIdentity {

    private String authorization;
    private String subject;

    public String authorization() {
        return authorization;
    }

    /** Best-effort display name of the caller (the JWT's preferred_username or sub), for logs. */
    public String subject() {
        return subject == null ? "anonymous" : subject;
    }

    void set(String authorization) {
        this.authorization = authorization;
        this.subject = JwtPeek.preferredUsername(authorization);
    }

    /**
     * Set the caller from a raw OIDC access token (the chat WebSocket path, where there is no
     * JAX-RS request filter to capture an Authorization header). The agent then carries the
     * logged-in user's token to the MCP gateway, so the gateway filters tools per that user.
     */
    public void setBearerToken(String rawAccessToken) {
        if (rawAccessToken != null && !rawAccessToken.isBlank()) {
            set("Bearer " + rawAccessToken);
        }
    }

    @Provider
    public static class Capture implements ContainerRequestFilter {

        @Inject
        CallerIdentity identity;

        @Override
        public void filter(ContainerRequestContext ctx) throws IOException {
            String auth = ctx.getHeaderString(HttpHeaders.AUTHORIZATION);
            if (auth != null && !auth.isBlank()) {
                identity.set(auth.trim());
            }
        }
    }
}
