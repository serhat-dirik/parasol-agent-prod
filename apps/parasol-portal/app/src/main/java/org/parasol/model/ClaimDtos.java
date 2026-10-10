package org.parasol.model;

import java.util.List;

/**
 * DTOs the portal exchanges with the browser and the claims-db REST API. The portal no longer
 * keeps its own claims in H2: it reads CLM-1001..CLM-1030, their timelines and uploaded documents
 * from claims-db, so the portal, the MCP tools and the timeline all agree.
 */
public final class ClaimDtos {

    private ClaimDtos() {
    }

    /** A claim as the list and detail pages render it (matches claims-db ClaimView JSON). */
    public record ClaimDto(String claimNumber, String claimant, String type, String status,
                           String amount, String incidentDate, String adjuster) {
    }

    /** One timeline entry on the detail page. */
    public record TimelineEntry(String eventType, String note, String createdAt) {
    }

    /** A customer-uploaded document; hiddenNote is the white-text block revealed on select-all. */
    public record DocumentDto(String filename, String vendor, String visibleText, String hiddenNote) {
    }

    /** The logged-in user for the top bar. */
    public record Me(String username, String name, String role, List<String> groups) {
    }

    /** Dashboard aggregate (from claims-db): status counts, paid count, and recent events. */
    public record Dashboard(java.util.Map<String, Long> statusCounts, long paidCount,
                            List<RecentEvent> recentEvents) {
    }

    public record RecentEvent(String claimNumber, String eventType, String note, String createdAt) {
    }

    /** The logged-in user's assistant usage today (from the portal's Micrometer meters). */
    public record Usage(long requests, long tokens) {
    }
}
