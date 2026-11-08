package org.parasol.resources;

import java.util.List;

import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;
import org.parasol.model.ClaimDtos.ClaimDetailsDto;
import org.parasol.model.ClaimDtos.ClaimDto;
import org.parasol.model.ClaimDtos.Dashboard;
import org.parasol.model.ClaimDtos.DocumentDto;
import org.parasol.model.ClaimDtos.TimelineEntry;

import java.util.Map;

import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;

/**
 * REST client for the claims-db read API. Base URL is configured per environment
 * ({@code quarkus.rest-client.claims-db-api.url}), direct to the claims-db Service.
 */
@RegisterRestClient(configKey = "claims-db-api")
@Path("/api/claims")
@Produces(MediaType.APPLICATION_JSON)
public interface ClaimsDbClient {

    @GET
    List<ClaimDto> all(@HeaderParam("Authorization") String authorization);

    @GET
    @Path("/{number}")
    ClaimDto one(@PathParam("number") String number, @HeaderParam("Authorization") String authorization);

    @GET
    @Path("/{number}/details")
    ClaimDetailsDto details(@PathParam("number") String number, @HeaderParam("Authorization") String authorization);

    @GET
    @Path("/{number}/history")
    List<TimelineEntry> history(@PathParam("number") String number, @HeaderParam("Authorization") String authorization);

    @GET
    @Path("/{number}/documents")
    List<DocumentDto> documents(@PathParam("number") String number, @HeaderParam("Authorization") String authorization);

    /** Record that the claim's documents were blocked as suspicious (secured: the portal's automatic flag). */
    @POST
    @Path("/{number}/documents/flag")
    @Consumes(MediaType.APPLICATION_JSON)
    void flagDocuments(@PathParam("number") String number, @HeaderParam("Authorization") String authorization,
                       Map<String, String> body);

    @GET
    @Path("/dashboard")
    Dashboard dashboard(@HeaderParam("Authorization") String authorization);
}
