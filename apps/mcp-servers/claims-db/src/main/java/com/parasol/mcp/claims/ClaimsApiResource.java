package com.parasol.mcp.claims;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.Function;
import java.util.stream.Collectors;

import jakarta.inject.Inject;
import jakarta.transaction.Transactional;
import io.opentelemetry.api.trace.Span;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
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
 *
 * <p>Secured ({@code claims.acl.enforce=true}): the same record rule as the tools, decided by the same
 * {@link RecordAccess} from the on-behalf-of token the portal presents for the logged-in user. The list and
 * the dashboard hold only the caller's records; a claim, its timeline or its documents outside them is a 403
 * with the refusal text (logged, counted and traced as {@code ui.<tool>}), never the data.
 */
@Path("/api/claims")
@Produces(MediaType.APPLICATION_JSON)
public class ClaimsApiResource {

    @Inject
    ClaimsRepository repo;

    @Inject
    ClaimDocuments documents;

    @Inject
    RecordAccess access;

    /** Outcome of one record decision: the caller (null when access is off) or the refusal response. */
    private record Decision(RecordAccess.Caller who, Response refused) {
    }

    /** Who is calling (secured), or a 401 when the call carries no valid user token. */
    private Decision caller(String tool, String authorization) {
        if (!access.enforced()) {
            return new Decision(null, null);
        }
        Span span = access.span(tool, null);
        try {
            RecordAccess.Caller who = access.verify(authorization);
            access.allowed(span, who);
            return new Decision(who, null);
        } catch (RecordAccess.Denied d) {
            String msg = access.refuse(span, tool, "-", null, d.getMessage());
            return new Decision(null, Response.status(Response.Status.UNAUTHORIZED)
                    .entity(Map.of("error", "unauthenticated", "message", msg)).build());
        } finally {
            span.end();
        }
    }

    /** Secured: null when the caller may read this claim (or it does not exist), else the 403 refusal. */
    private Response guard(String tool, String number, String authorization) {
        if (!access.enforced()) {
            return null;
        }
        Span span = access.span(tool, null);
        try {
            RecordAccess.Caller who;
            try {
                who = access.verify(authorization);
            } catch (RecordAccess.Denied d) {
                String msg = access.refuse(span, tool, ClaimsRepository.normalize(number), null, d.getMessage());
                return Response.status(Response.Status.UNAUTHORIZED).entity(Map.of("error", "unauthenticated", "message", msg)).build();
            }
            span.setAttribute("claims.claim_number", String.valueOf(ClaimsRepository.normalize(number)));
            var c = repo.find(number);
            if (c.isPresent() && !who.mayRead(c.get())) {
                String msg = access.refuse(span, tool, c.get().claimNumber(), who, "assigned to " + c.get().adjuster());
                return Response.status(Response.Status.FORBIDDEN)
                        .entity(Map.of("error", "not_assigned", "claimNumber", c.get().claimNumber(), "message", msg)).build();
            }
            access.allowed(span, who);
            return null;
        } finally {
            span.end();
        }
    }

    /** All claims the caller may read (secured: their assigned claims; managers and free: all), by claim number. */
    @GET
    public Response all(@HeaderParam("Authorization") String authorization) {
        Decision d = caller("ui.list_claims", authorization);
        if (d.refused() != null) {
            return d.refused();
        }
        return Response.ok(d.who() == null ? repo.all() : repo.all().stream().filter(d.who()::mayRead).toList()).build();
    }

    /**
     * One aggregate read for the portal Dashboard: status counts, how many claims have been paid,
     * and the 10 most recent timeline events across all claims. A literal path, so it wins over the
     * {@code /{number}} template below. One endpoint so the portal does not fan out per claim.
     */
    @GET
    @Path("/dashboard")
    @Transactional
    public Response dashboard(@HeaderParam("Authorization") String authorization) {
        Decision d = caller("ui.dashboard", authorization);
        if (d.refused() != null) {
            return d.refused();
        }
        // Secured: counted over the caller's own records only (an adjuster's dashboard is their caseload).
        Set<String> readable = repo.all().stream().filter(c -> d.who() == null || d.who().mayRead(c))
                .map(ClaimView::claimNumber).collect(Collectors.toSet());
        Map<String, Long> byStatus = repo.all().stream().filter(c -> readable.contains(c.claimNumber()))
                .collect(Collectors.groupingBy(ClaimView::status, Collectors.counting()));
        Map<String, Long> counts = ClaimsRepository.STATUSES.stream()
                .collect(Collectors.toMap(Function.identity(), st -> byStatus.getOrDefault(st, 0L)));
        long paid = ClaimEvent.<ClaimEvent>find("eventType", "PaymentIssued").list().stream()
                .map(e -> e.claimNumber).filter(readable::contains).distinct().count();
        List<RecentEvent> recent = ClaimEvent.<ClaimEvent>find("order by createdAt desc, id desc")
                .list().stream().filter(e -> readable.contains(e.claimNumber)).limit(10)
                .map(e -> new RecentEvent(e.claimNumber, e.eventType, e.note,
                        e.createdAt == null ? null : e.createdAt.toString()))
                .toList();
        return Response.ok(new Dashboard(counts, paid, recent)).build();
    }

    public record Dashboard(Map<String, Long> statusCounts, long paidCount, List<RecentEvent> recentEvents) {
    }

    public record RecentEvent(String claimNumber, String eventType, String note, String createdAt) {
    }

    /** One claim by number, 404 if unknown. */
    @GET
    @Path("/{number}")
    public Response one(@PathParam("number") String number, @HeaderParam("Authorization") String authorization) {
        Response refused = guard("ui.get_claim", number, authorization);
        if (refused != null) {
            return refused;
        }
        return repo.find(number)
                .map(c -> Response.ok(c).build())
                .orElseGet(() -> Response.status(Response.Status.NOT_FOUND).build());
    }

    /** The claim's audit timeline, oldest first (drives the detail-page timeline). */
    @GET
    @Path("/{number}/history")
    @Transactional
    public Response history(@PathParam("number") String number, @HeaderParam("Authorization") String authorization) {
        Response refused = guard("ui.get_claim_history", number, authorization);
        if (refused != null) {
            return refused;
        }
        return Response.ok(repo.history(number).stream()
                .map(e -> new TimelineEntry(e.eventType, e.note, e.createdAt == null ? null : e.createdAt.toString()))
                .toList()).build();
    }

    /** The documents the customer uploaded to the claim (visible text + any hidden note). */
    @GET
    @Path("/{number}/documents")
    public Response docs(@PathParam("number") String number, @HeaderParam("Authorization") String authorization) {
        Response refused = guard("ui.get_claim_documents", number, authorization);
        if (refused != null) {
            return refused;
        }
        return Response.ok(documents.forClaim(number).stream()
                .map(d -> new DocumentView(d.filename(), d.vendor(), d.visibleText(), d.hiddenNote()))
                .toList()).build();
    }

    public record TimelineEntry(String eventType, String note, String createdAt) {
    }

    /** visibleText renders normally; hiddenNote is the white-text block the UI reveals on select-all. */
    public record DocumentView(String filename, String vendor, String visibleText, String hiddenNote) {
    }
}
