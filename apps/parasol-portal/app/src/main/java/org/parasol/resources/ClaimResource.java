package org.parasol.resources;

import java.util.Collection;
import java.util.List;
import java.util.Map;

import java.util.Map;

import org.eclipse.microprofile.jwt.JsonWebToken;
import org.eclipse.microprofile.rest.client.inject.RestClient;
import org.parasol.ai.CallerIdentity;
import org.parasol.model.ClaimDtos.ClaimDto;
import org.parasol.model.ClaimDtos.Dashboard;
import org.parasol.model.ClaimDtos.DocumentDto;
import org.parasol.model.ClaimDtos.Me;
import org.parasol.model.ClaimDtos.TimelineEntry;
import org.parasol.model.ClaimDtos.Usage;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;

import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.mcp.client.McpClient;
import io.quarkus.oidc.AccessTokenCredential;
import io.quarkus.security.identity.SecurityIdentity;
import io.quarkiverse.langchain4j.mcp.runtime.McpClientName;
import io.smallrye.common.annotation.Blocking;
import jakarta.annotation.security.PermitAll;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

/**
 * The portal's read API for its own UI: claims, timeline and uploaded documents (proxied from the
 * claims-db REST API so the UI, the tools and the timeline agree), plus {@code /api/me} for the
 * top bar. Access requires login (enforced by the HTTP auth policy), which is the "different
 * people, different rights, visible on screen" beat.
 */
@Produces(MediaType.APPLICATION_JSON)
@Path("/api")
public class ClaimResource {

    @Inject
    @RestClient
    ClaimsDbClient claims;

    @Inject
    SecurityIdentity identity;

    @Inject
    JsonWebToken jwt;

    @Inject
    CallerIdentity caller;

    @Inject
    @McpClientName("claims-db")
    McpClient claimsDb;

    @Inject
    MeterRegistry metrics;

    @GET
    @Path("/claims")
    public List<ClaimDto> all() {
        return claims.all();
    }

    @GET
    @Path("/claims/{number}")
    public ClaimDto one(@PathParam("number") String number) {
        return claims.one(number);
    }

    @GET
    @Path("/claims/{number}/history")
    public List<TimelineEntry> history(@PathParam("number") String number) {
        return claims.history(number);
    }

    @GET
    @Path("/claims/{number}/documents")
    public List<DocumentDto> documents(@PathParam("number") String number) {
        return claims.documents(number);
    }

    /** Dashboard aggregate (status counts, paid count, recent events), proxied from claims-db. */
    @GET
    @Path("/dashboard")
    public Dashboard dashboard() {
        return claims.dashboard();
    }

    /** The logged-in user's assistant usage, read from the portal's own Micrometer meters. */
    @GET
    @Path("/me/usage")
    @PermitAll
    public Usage myUsage() {
        String user = identity.isAnonymous() ? "anonymous" : identity.getPrincipal().getName();
        long tokens = sum("parasol_agent_tokens_total", user);
        long requests = sum("parasol_agent_model_calls_total", user);
        return new Usage(requests, tokens);
    }

    /** Sum the counters of a given meter name whose "user" tag matches, across other tags. */
    private long sum(String meterName, String user) {
        double total = 0;
        for (Counter c : metrics.find(meterName).tag("user", user).counters()) {
            total += c.count();
        }
        return (long) total;
    }

    /**
     * A2 "Act": a claims manager approves a proposed payout. The write happens HERE on the button
     * click (not from the model path), invoking the real {@code approve_payout} MCP tool with the
     * manager's own token - so in secured the MCP gateway authorizes it for a claims-manager and
     * 403s anyone else. Adjusters have no Approve button; a forced call is refused at the gateway.
     */
    @POST
    @Path("/claims/{number}/approve")
    @Blocking
    public Response approve(@PathParam("number") String number, @QueryParam("amount") Double amount) {
        if (!groups().contains("claims-managers")) {
            return Response.status(Response.Status.FORBIDDEN)
                    .entity(Map.of("error", "approve_payout is not permitted for this role")).build();
        }
        forwardToken();
        String args = amount == null
                ? String.format("{\"claimNumber\":\"%s\"}", number)
                : String.format("{\"claimNumber\":\"%s\",\"amount\":%s}", number, amount);
        try {
            String result = claimsDb.executeTool(
                    ToolExecutionRequest.builder().name("approve_payout").arguments(args).build()).resultText();
            return Response.ok(Map.of("result", result)).build();
        } catch (RuntimeException e) {
            return Response.status(Response.Status.BAD_GATEWAY)
                    .entity(Map.of("error", String.valueOf(e.getMessage()))).build();
        }
    }

    /** Put the logged-in user's OIDC token in the request context so the MCP call carries it. */
    private void forwardToken() {
        if (!identity.isAnonymous()) {
            AccessTokenCredential cred = identity.getCredential(AccessTokenCredential.class);
            if (cred != null && cred.getToken() != null) {
                caller.setBearerToken(cred.getToken());
            }
        }
    }

    /** The logged-in user, for the top bar ("Rebecca Torres, claims adjuster"). */
    @GET
    @Path("/me")
    @PermitAll
    public Me me() {
        if (identity.isAnonymous()) {
            return new Me(null, null, "guest", List.of());
        }
        List<String> groups = groups();
        String name = claimString("name");
        if (name == null) {
            name = identity.getPrincipal().getName();
        }
        return new Me(identity.getPrincipal().getName(), name, roleFor(groups), groups);
    }

    @SuppressWarnings("unchecked")
    private List<String> groups() {
        Object g = jwt.getClaim("groups");
        if (g instanceof Collection<?> c) {
            return c.stream().map(String::valueOf).toList();
        }
        // Fall back to SecurityIdentity roles when the groups claim is absent.
        return identity.getRoles().stream().toList();
    }

    private String claimString(String name) {
        Object v = jwt.getClaim(name);
        return v == null ? null : String.valueOf(v);
    }

    /** Map a Keycloak group to the role label shown in the top bar. */
    private static String roleFor(List<String> groups) {
        Map<String, String> labels = Map.of(
                "claims-managers", "claims manager",
                "adjusters", "claims adjuster",
                "developers", "developer",
                "policyholders", "policyholder");
        for (String g : groups) {
            String key = g.startsWith("/") ? g.substring(1) : g;
            if (labels.containsKey(key)) {
                return labels.get(key);
            }
        }
        return "staff";
    }
}
