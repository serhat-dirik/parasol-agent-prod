package org.parasol.resources;

import java.util.List;

import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;
import org.parasol.model.ClaimDtos.ClaimDto;
import org.parasol.model.ClaimDtos.DocumentDto;
import org.parasol.model.ClaimDtos.TimelineEntry;

import jakarta.ws.rs.GET;
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
    List<ClaimDto> all();

    @GET
    @Path("/{number}")
    ClaimDto one(@PathParam("number") String number);

    @GET
    @Path("/{number}/history")
    List<TimelineEntry> history(@PathParam("number") String number);

    @GET
    @Path("/{number}/documents")
    List<DocumentDto> documents(@PathParam("number") String number);
}
