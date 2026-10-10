package org.parasol.resources;

import java.util.UUID;

import org.parasol.ai.AgentService;

import io.quarkus.security.identity.SecurityIdentity;
import io.smallrye.common.annotation.Blocking;
import jakarta.annotation.security.PermitAll;
import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

/**
 * REST surface for the portal's assistant, kept for scripts and tests (the audience uses the chat
 * WebSocket). {@code POST /agent/ask} with a {@code Authorization: Bearer <token>} header is what
 * {@code scripts/night-shift.sh} drives as the policyholder {@code tom.becker}: same shape as the
 * REST agent's endpoint. {@link org.parasol.ai.CallerIdentity} captures the bearer token and
 * forwards it to the MCP gateway; in the free environment no token is sent (anonymous to tools).
 */
@Path("/agent")
@Produces(MediaType.APPLICATION_JSON)
@Consumes(MediaType.APPLICATION_JSON)
public class AgentResource {

    @Inject
    AgentService agent;

    @Inject
    SecurityIdentity identity;

    @POST
    @Path("/ask")
    @PermitAll
    @Blocking
    public Response ask(AskRequest request) {
        if (request == null || request.question() == null || request.question().isBlank()) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(new ErrorBody("question is required")).build();
        }
        AgentService.AgentAnswer answer = agent.answer(UUID.randomUUID().toString(), request.question());
        if (answer.error() != null) {
            return Response.status(Response.Status.BAD_GATEWAY).entity(answer).build();
        }
        return Response.ok(answer).build();
    }

    public record AskRequest(String question) {
    }

    public record ErrorBody(String error) {
    }
}
