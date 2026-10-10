package org.parasol.resources;

import java.util.Collection;
import java.util.List;
import java.util.Map;

import org.eclipse.microprofile.jwt.JsonWebToken;
import org.eclipse.microprofile.rest.client.inject.RestClient;
import org.parasol.model.ClaimDtos.ClaimDto;
import org.parasol.model.ClaimDtos.DocumentDto;
import org.parasol.model.ClaimDtos.Me;
import org.parasol.model.ClaimDtos.TimelineEntry;

import io.quarkus.security.identity.SecurityIdentity;
import jakarta.annotation.security.PermitAll;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;

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
