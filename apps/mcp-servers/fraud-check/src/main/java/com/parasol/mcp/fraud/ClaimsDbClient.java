package com.parasol.mcp.fraud;

import java.util.List;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;

import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

/**
 * Typed view of the claims-db read API (the same endpoints the portal UI reads). The fraud-check
 * agent is a CLIENT of claims-db: it never keeps its own copy of the data, so the record amount and
 * the uploaded document text it judges are exactly what the rest of the demo shows.
 */
@RegisterRestClient(configKey = "claims-db")
@Produces(MediaType.APPLICATION_JSON)
public interface ClaimsDbClient {

    /** One claim by number; the claims-db returns 404 (WebApplicationException) if unknown. */
    @GET
    @Path("/api/claims/{number}")
    ClaimRecord claim(@PathParam("number") String number);

    /** The documents the customer uploaded to the claim (visible text + any hidden note). */
    @GET
    @Path("/api/claims/{number}/documents")
    List<Document> documents(@PathParam("number") String number);

    /** Claim record projection - only the fields the fraud check needs. {@code amount} is a string
     *  (e.g. "8400.00") exactly as the claims-db serialises it. */
    record ClaimRecord(String claimNumber, String claimant, String type, String status,
                       String amount, String incidentDate, String adjuster) {
    }

    /** An uploaded document: visibleText is the rendered estimate; hiddenNote is the white-text block. */
    record Document(String filename, String vendor, String visibleText, String hiddenNote) {
    }
}
