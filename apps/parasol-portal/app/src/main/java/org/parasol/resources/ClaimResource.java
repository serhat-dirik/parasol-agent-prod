package org.parasol.resources;

import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.function.Supplier;

import org.eclipse.microprofile.jwt.JsonWebToken;
import org.eclipse.microprofile.rest.client.inject.RestClient;
import org.parasol.ai.CallerIdentity;
import org.parasol.ai.McpBearerTokenProvider;
import org.parasol.model.ClaimDtos.ClaimDetailsDto;
import org.parasol.model.ClaimDtos.ClaimDto;
import org.parasol.model.ClaimDtos.Dashboard;
import org.parasol.model.ClaimDtos.DocumentDto;
import org.parasol.model.ClaimDtos.Me;
import org.parasol.model.ClaimDtos.TimelineEntry;
import org.parasol.model.ClaimDtos.Usage;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;

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
import jakarta.ws.rs.WebApplicationException;
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

    @Inject
    Tracer tracer;

    @Inject
    McpBearerTokenProvider mcpAuth;

    /*
     * The UI's reads go to claims-db with the same identity the agent's tools use: the logged-in user's token
     * exchanged by the agent (secured). claims-db decides, with the rule it applies to the tools, which records
     * this user may see; a claim outside them comes back as claims-db's 403 refusal, which the UI renders as
     * "not assigned to you" (no data). One enforcement point, no copy of the rule here.
     */

    @GET
    @Path("/claims")
    public List<ClaimDto> all() {
        return read(() -> claims.all(readAuthorization()));
    }

    @GET
    @Path("/claims/{number}")
    public ClaimDto one(@PathParam("number") String number) {
        return read(() -> claims.one(number, readAuthorization()));
    }

    @GET
    @Path("/claims/{number}/details")
    public ClaimDetailsDto details(@PathParam("number") String number) {
        return read(() -> claims.details(number, readAuthorization()));
    }

    @GET
    @Path("/claims/{number}/history")
    public List<TimelineEntry> history(@PathParam("number") String number) {
        return read(() -> claims.history(number, readAuthorization()));
    }

    @GET
    @Path("/claims/{number}/documents")
    public List<DocumentDto> documents(@PathParam("number") String number) {
        return read(() -> claims.documents(number, readAuthorization()));
    }

    /** Dashboard aggregate (status counts, paid count, recent events) over the records this user may read. */
    @GET
    @Path("/dashboard")
    public Dashboard dashboard() {
        return read(() -> claims.dashboard(readAuthorization()));
    }

    /** The Authorization the agent presents for this user (null in free: claims-db does not check there). */
    private String readAuthorization() {
        forwardToken();
        return mcpAuth.getAuthorization(null);
    }

    /** claims-db's refusal (403 not_assigned, 401) is passed to the UI as it is: status and explanation, no record. */
    private static <T> T read(Supplier<T> call) {
        try {
            return call.get();
        } catch (WebApplicationException e) {
            Response r = e.getResponse();
            String body = r.hasEntity() ? r.readEntity(String.class) : "";
            throw new WebApplicationException(Response.status(r.getStatus())
                    .type(MediaType.APPLICATION_JSON).entity(body).build());
        }
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
     * Two-stage approval, stage 2: a claims manager releases the payment of a claim the assistant (or anyone with
     * approve_claim) set to Ready for payment. The write happens HERE on the button click, never from the model path
     * (release_payment is in no model's tool list): the real {@code release_payment} MCP tool is called with a token
     * exchanged on the manager's behalf, so the MCP gateway authorizes it for claims-managers and 403s anyone else.
     * Adjusters have no button; a forced call is refused (403).
     */
    @POST
    @Path("/claims/{number}/release")
    @Blocking
    public Response release(@PathParam("number") String number) {
        Span root = Span.current();
        String traceId = root.getSpanContext().getTraceId();
        // The release's trace reads like the chat's: who released, through which agent (MLflow user + tags).
        String who = identity.isAnonymous() ? "anonymous" : identity.getPrincipal().getName();
        root.setAttribute("user.id", who);
        root.setAttribute("enduser.id", who);
        root.setAttribute("gen_ai.agent.name", mcpAuth.agentId());
        root.setAttribute("claim.number", number);
        root.setAttribute("mlflow.traceTag.agent", mcpAuth.agentId());
        root.setAttribute("mlflow.traceTag.action", "release_payment " + number);
        if (!groups().contains("claims-managers")) {
            // Runs before forwardToken()/CallerIdentity is populated: attribute the refusal to the authenticated user.
            toolCall("release_payment", "403", who);
            gatewayAuthz("release_payment", true);
            return Response.status(Response.Status.FORBIDDEN)
                    .entity(Map.of("error", "release_payment is not permitted for this role", "traceId", traceId)).build();
        }
        forwardToken();
        String args = String.format("{\"claimNumber\":\"%s\"}", number);
        try {
            String result = claimsDb.executeTool(
                    ToolExecutionRequest.builder().name("release_payment").arguments(args).build()).resultText();
            toolCall("release_payment", "200");
            gatewayAuthz("release_payment", false);
            // claims-db answers a claim that is not Ready for payment in words: nothing was paid.
            boolean paid = result != null && result.startsWith("Payment released");
            return Response.status(paid ? Response.Status.OK : Response.Status.CONFLICT)
                    .entity(Map.of("result", String.valueOf(result), "traceId", traceId, "releasedBy", who,
                            "agent", mcpAuth.agentId())).build();
        } catch (RuntimeException e) {
            // A call without the tool role is refused at the MCP gateway (403).
            String msg = String.valueOf(e.getMessage());
            boolean denied = msg.toLowerCase().contains("403");
            toolCall("release_payment", denied ? "403" : "200");
            gatewayAuthz("release_payment", denied);
            return Response.status(Response.Status.BAD_GATEWAY)
                    .entity(Map.of("error", msg, "traceId", traceId)).build();
        }
    }

    /** parasol_tool_calls_total{tool,user,agent,status}: the per-tool authz outcome for the operator dashboard. */
    private void toolCall(String tool, String status) {
        toolCall(tool, status, caller.subject());
    }

    /** As {@link #toolCall(String, String)} but with an explicit user, for paths where the caller
     * identity is known from SecurityIdentity before the forwarded token populates CallerIdentity. */
    private void toolCall(String tool, String status, String user) {
        metrics.counter("parasol_tool_calls_total", "tool", tool, "user", user, "agent", mcpAuth.agentId(),
                        "status", status)
                .increment();
    }

    /**
     * gateway.authz span: the identity-bound tool-authorization decision at the MCP gateway, for the
     * trace. A denial carries the tool name as an attribute and the 403 as the span status, so the
     * trace shows the refusal plainly (an adjuster forcing release_payment); an allow is an OK span.
     */
    private void gatewayAuthz(String tool, boolean denied) {
        Span s = tracer.spanBuilder("gateway.authz").startSpan();
        try {
            s.setAttribute("tool.name", tool);
            s.setAttribute("authz.decision", denied ? "deny" : "allow");
            s.setAttribute("enduser.id", identity.isAnonymous() ? "anonymous" : identity.getPrincipal().getName());
            s.setAttribute("gen_ai.agent.name", mcpAuth.agentId());
            if (denied) {
                s.setAttribute("http.status_code", 403L);
                s.setStatus(StatusCode.ERROR, "403 forbidden");
            }
        } finally {
            s.end();
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
                "contractors", "night-shift contractor");
        for (String g : groups) {
            String key = g.startsWith("/") ? g.substring(1) : g;
            if (labels.containsKey(key)) {
                return labels.get(key);
            }
        }
        return "staff";
    }
}
