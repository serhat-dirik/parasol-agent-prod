package org.parasol.ai;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;

import org.junit.jupiter.api.Test;

class UnbackedClaimTest {

    @Test
    void aPaymentClaimIsAlwaysCorrected() {
        assertEquals(AgentService.UNBACKED_PAYMENT_NOTE, AgentService.unbackedClaimNote(
                "Done: the payment for claim CLM-1001 has been released.", true));
        assertEquals(AgentService.UNBACKED_PAYMENT_NOTE, AgentService.unbackedClaimNote("I have paid CLM-1001.", true));
        assertEquals(AgentService.UNBACKED_PAYMENT_NOTE, AgentService.unbackedClaimNote(
                "4,200 AED is 1,143.64 USD. The payout for claim CLM-1001 has been issued.", false));
    }

    @Test
    void anApprovalClaimNeedsApproveClaimOnTheTurn() {
        assertEquals(AgentService.UNBACKED_APPROVAL_NOTE, AgentService.unbackedClaimNote(
                "I have approved claim CLM-1002.", false));
        assertEquals(AgentService.UNBACKED_APPROVAL_NOTE, AgentService.unbackedClaimNote(
                "Claim CLM-1002 has been approved for 4,200 USD.", false));
        assertNull(AgentService.unbackedClaimNote("I have approved claim CLM-1001; a claims manager releases the payment.", true));
    }

    @Test
    void noClaimIsLeftAlone() {
        assertNull(AgentService.unbackedClaimNote("CLM-1001 is UnderReview, amount 4200.00 USD.", false));
        assertNull(AgentService.unbackedClaimNote("I can approve the claim if you want.", false));
        assertNull(AgentService.unbackedClaimNote("Claim CLM-1001 has been approved and is Ready for payment. "
                + "No payment has been made yet; a claims manager will release the payment.", true));
        assertNull(AgentService.unbackedClaimNote(null, false));
    }

    @Test
    void onlyASuccessfulApproveClaimCounts() {
        ToolCall ok = new ToolCall("approve_claim", "{}", "Claim CLM-1001 (claimant Alice Nguyen) approved for USD 4200.00 "
                + "and set to Ready for payment.", false, null);
        ToolCall refused = new ToolCall("approve_claim", "{}", "Claim CLM-1004 is Denied: only a claim UnderReview can be "
                + "approved. Nothing done.", false, null);
        assertTrue(AgentService.approvedThisTurn(List.of(ok)));
        assertFalse(AgentService.approvedThisTurn(List.of(refused)));
    }
}
