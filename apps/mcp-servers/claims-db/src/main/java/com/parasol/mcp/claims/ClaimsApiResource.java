package com.parasol.mcp.claims;

import java.util.List;
import java.util.Map;

import jakarta.inject.Inject;
import jakarta.transaction.Transactional;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

/**
 * Plain REST over the claims dataset, for the Parasol portal to read (the portal no longer keeps
 * its own H2 - it reads claims, timeline and uploaded documents from here so the portal, the MCP
 * tools and the timeline all agree on CLM-1001..CLM-1030). This is NOT an MCP tool and is not
 * reachable through the MCP gateway; it is a read surface for the UI.
 */
@Path("/api/claims")
@Produces(MediaType.APPLICATION_JSON)
public class ClaimsApiResource {

    @Inject
    ClaimsRepository repo;

    @Inject
    ClaimDocuments documents;

    /** All claims, sorted by claim number. */
    @GET
    public List<ClaimView> all() {
        return repo.all();
    }

    /**
     * One aggregate read for the portal Dashboard: status counts, how many claims have been paid,
     * and the 10 most recent timeline events across all claims. A literal path, so it wins over the
     * {@code /{number}} template below. One endpoint so the portal does not fan out per claim.
     */
    @GET
    @Path("/dashboard")
    @Transactional
    public Dashboard dashboard() {
        Map<String, Long> counts = Map.of(
                "Submitted", Claim.count("status", "Submitted"),
                "UnderReview", Claim.count("status", "UnderReview"),
                "Approved", Claim.count("status", "Approved"),
                "Denied", Claim.count("status", "Denied"));
        long paid = ClaimEvent.<ClaimEvent>find("eventType", "PaymentIssued").list().stream()
                .map(e -> e.claimNumber).distinct().count();
        List<RecentEvent> recent = ClaimEvent.<ClaimEvent>find("order by createdAt desc, id desc")
                .page(0, 10).list().stream()
                .map(e -> new RecentEvent(e.claimNumber, e.eventType, e.note,
                        e.createdAt == null ? null : e.createdAt.toString()))
                .toList();
        return new Dashboard(counts, paid, recent);
    }

    public record Dashboard(Map<String, Long> statusCounts, long paidCount, List<RecentEvent> recentEvents) {
    }

    public record RecentEvent(String claimNumber, String eventType, String note, String createdAt) {
    }

    /** One claim by number, 404 if unknown. */
    @GET
    @Path("/{number}")
    public Response one(@PathParam("number") String number) {
        return repo.find(number)
                .map(c -> Response.ok(c).build())
                .orElseGet(() -> Response.status(Response.Status.NOT_FOUND).build());
    }

    /** The claim's audit timeline, oldest first (drives the detail-page timeline). */
    @GET
    @Path("/{number}/history")
    @Transactional
    public List<TimelineEntry> history(@PathParam("number") String number) {
        return repo.history(number).stream()
                .map(e -> new TimelineEntry(e.eventType, e.note, e.createdAt == null ? null : e.createdAt.toString()))
                .toList();
    }

    /** The documents the customer uploaded to the claim (visible text + any hidden note). */
    @GET
    @Path("/{number}/documents")
    public List<DocumentView> docs(@PathParam("number") String number) {
        return documents.forClaim(number).stream()
                .map(d -> new DocumentView(d.filename(), d.vendor(), d.visibleText(), d.hiddenNote()))
                .toList();
    }

    public record TimelineEntry(String eventType, String note, String createdAt) {
    }

    /** visibleText renders normally; hiddenNote is the white-text block the UI reveals on select-all. */
    public record DocumentView(String filename, String vendor, String visibleText, String hiddenNote) {
    }
}
