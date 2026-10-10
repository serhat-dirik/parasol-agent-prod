package org.parasol.ai;

import jakarta.enterprise.context.RequestScoped;

/**
 * Per-request record of a payout the assistant PROPOSED (Read-Propose-Act, A2). Populated by the
 * local {@link ProposePayoutTool}; read by {@link AgentService} to emit a propose frame so the UI
 * shows the card (proposed vs claimed, with an Approve button for claims-managers). Secured only.
 */
@RequestScoped
public class ProposalHolder {

    private String claimNumber;
    private Double proposed;
    private Double claimed;

    void record(String claimNumber, Double proposed, Double claimed) {
        this.claimNumber = claimNumber;
        this.proposed = proposed;
        this.claimed = claimed;
    }

    public boolean has() {
        return claimNumber != null;
    }

    public String claimNumber() {
        return claimNumber;
    }

    public Double proposed() {
        return proposed;
    }

    public Double claimed() {
        return claimed;
    }
}
