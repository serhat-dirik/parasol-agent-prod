package com.parasol.mcp.claims;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.List;
import java.util.Optional;
import java.util.stream.Collectors;

import io.quarkiverse.mcp.server.Tool;
import io.quarkiverse.mcp.server.ToolArg;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The claims-db MCP tools - "your APIs, as tools" (M23).
 *
 * <p>Three read-only tools over the seeded CLM-1001..CLM-1030 dataset. Descriptions are
 * written FOR THE MODEL: they name the exact claim-number format and the valid statuses so a
 * temperature-0 agent calls them with the right arguments. Each tool returns either a compact
 * record (serialized to JSON) or a single grounded sentence the model can quote verbatim.
 */
@ApplicationScoped
public class ClaimsTools {

    @Inject
    ClaimsRepository repo;

    @Inject
    PayoutService payouts;

    @Inject
    ClaimDocuments documents;

    @Tool(name = "get_claim",
            description = "Look up a single Parasol Insurance claim by its claim number "
                    + "(for example CLM-1001). Returns the claimant, line of business (auto/home/life), "
                    + "workflow status, claimed amount in USD, assigned adjuster and incident date. "
                    + "Use this to answer questions about the status or details of a specific claim.")
    public String getClaim(
            @ToolArg(description = "The claim number, e.g. CLM-1001") String claimNumber) {
        Optional<ClaimView> claim = repo.find(claimNumber);
        if (claim.isEmpty()) {
            return "No claim found with number " + ClaimsRepository.normalize(claimNumber) + ".";
        }
        ClaimView c = claim.get();
        return String.format(
                "Claim %s: claimant %s, line of business %s, status %s, amount %s USD, "
                        + "adjuster %s, incident date %s.",
                c.claimNumber(), c.claimant(), c.type(), c.status(), c.amount(),
                c.adjuster(), c.incidentDate());
    }

    @Tool(name = "approve_payout",
            description = "Approve a Parasol Insurance claim for payment and issue the payout. "
                    + "Sets the claim status to Approved and records the payment in the claim timeline. "
                    + "Call this when asked to approve, pay, pay out or settle a claim. "
                    + "If no amount is given the full claimed amount is paid.")
    public String approvePayout(
            @ToolArg(description = "The claim number, e.g. CLM-1004") String claimNumber,
            @ToolArg(description = "Amount in USD to pay; omit to pay the full claimed amount",
                    required = false) Double amount,
            @ToolArg(description = "The user who authorized this approval; omit when the assistant "
                    + "approves autonomously", required = false) String actor) {
        BigDecimal value = amount == null ? null : BigDecimal.valueOf(amount).setScale(2, RoundingMode.HALF_UP);
        return payouts.approve(claimNumber, value, actor == null || actor.isBlank() ? "claims-assistant" : actor);
    }

    @Tool(name = "list_claims_by_status",
            description = "List the Parasol claims currently in a given workflow status. "
                    + "Valid statuses are exactly: Submitted, UnderReview, Approved, Denied. "
                    + "Returns each matching claim with its number, claimant, type, amount and adjuster.")
    public List<ClaimView> listClaimsByStatus(
            @ToolArg(description = "One of: Submitted, UnderReview, Approved, Denied") String status) {
        return repo.byStatus(status);
    }

    @Tool(name = "get_claim_documents",
            description = "Return the text of the documents a customer uploaded to a claim "
                    + "(for example a repair estimate). Use this when asked to read, summarise or "
                    + "check the documents, uploads or attachments on a claim.")
    public String getClaimDocuments(
            @ToolArg(description = "The claim number, e.g. CLM-1004") String claimNumber) {
        List<ClaimDocuments.ClaimDocument> docs = documents.forClaim(claimNumber);
        if (docs.isEmpty()) {
            return "No documents have been uploaded to claim "
                    + ClaimsRepository.normalize(claimNumber) + ".";
        }
        return docs.stream()
                .map(d -> "Document: " + d.filename() + " (uploaded by " + d.vendor() + ")\n" + d.fullText())
                .collect(Collectors.joining("\n\n---\n\n"));
    }

    @Tool(name = "get_claim_history",
            description = "Return the audit timeline for a claim (submitted, adjuster assigned, "
                    + "documents requested/received, under review, approved/denied, payment issued), "
                    + "oldest event first. Use this when asked what has happened to a claim over time.")
    public String getClaimHistory(
            @ToolArg(description = "The claim number, e.g. CLM-1001") String claimNumber) {
        if (!repo.exists(claimNumber)) {
            return "No claim found with number " + ClaimsRepository.normalize(claimNumber) + ".";
        }
        List<ClaimEvent> events = repo.history(claimNumber);
        if (events.isEmpty()) {
            return "Claim " + ClaimsRepository.normalize(claimNumber)
                    + " exists but has no recorded timeline events.";
        }
        String lines = events.stream()
                .map(e -> String.format("- %s: %s (%s)", e.createdAt, e.eventType, e.note))
                .collect(Collectors.joining("\n"));
        return "Timeline for claim " + ClaimsRepository.normalize(claimNumber) + ":\n" + lines;
    }
}
