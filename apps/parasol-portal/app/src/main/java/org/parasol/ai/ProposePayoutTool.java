package org.parasol.ai;

import org.eclipse.microprofile.rest.client.inject.RestClient;
import org.parasol.model.ClaimDtos.ClaimDto;
import org.parasol.resources.ClaimsDbClient;

import dev.langchain4j.agent.tool.P;
import dev.langchain4j.agent.tool.Tool;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The secured write path: a LOCAL (non-MCP) tool that PROPOSES a payout instead of making one
 * (Read-Propose-Act, A2). It is attached only to the assistant's secured method
 * ({@link ClaimsAssistant#askWithPropose}), so the free environment never sees it and keeps paying
 * directly through the real MCP {@code approve_payout}. In secured the MCP gateway filters the real
 * {@code approve_payout} out of an adjuster's tools, so this is the only write-ish tool the model
 * can call: it records the proposal (claimed vs proposed) for the portal to render as a card and
 * returns a sentence telling the model it needs a claims manager's approval. It NEVER moves money.
 */
@ApplicationScoped
public class ProposePayoutTool {

    @Inject
    @RestClient
    ClaimsDbClient claims;

    @Inject
    ProposalHolder holder;

    @Tool(name = "propose_payout",
            value = "Propose a payout on a claim for a claims manager to approve. Use this to approve, "
                    + "pay, pay out or settle a claim. It does NOT pay the claim - it submits a proposal "
                    + "that a claims manager must approve. Pass the amount in USD if one is given.")
    public String proposePayout(
            @P("The claim number, e.g. CLM-1004") String claimNumber,
            @P(value = "Amount in USD to pay; omit to propose the full claimed amount", required = false) Double amount) {
        // Idempotent within a request: if the model already proposed (it tends to retry because the
        // proposal does not "approve" the claim), return a terminal instruction so it stops looping.
        if (holder.has()) {
            return "This payout is ALREADY proposed and is awaiting a claims manager's approval. "
                    + "Do NOT call propose_payout again. Reply to the user that the payout has been "
                    + "proposed and a claims manager must approve it.";
        }
        Double claimed = null;
        try {
            ClaimDto c = claims.one(claimNumber);
            if (c != null && c.amount() != null) {
                claimed = Double.parseDouble(c.amount());
            }
        } catch (RuntimeException lookupFailed) {
            // proceed without the claimed figure; the card simply omits the comparison
        }
        double proposed = amount != null ? amount : (claimed != null ? claimed : 0);
        holder.record(claimNumber, proposed, claimed);
        String claimedStr = claimed == null ? "the claimed amount" : fmt(claimed);
        return "Proposal submitted: pay " + fmt(proposed) + " on claim " + claimNumber
                + " (claimed " + claimedStr + "). A claims manager must approve before any payment is made. "
                + "This is complete - do NOT call any more tools. Tell the user the payout has been "
                + "proposed and is awaiting a claims manager's approval.";
    }

    private static String fmt(double v) {
        return String.format("%,.0f", v);
    }
}
