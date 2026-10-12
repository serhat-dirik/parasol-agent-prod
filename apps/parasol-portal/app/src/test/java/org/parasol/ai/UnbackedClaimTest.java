package org.parasol.ai;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

import org.junit.jupiter.api.Test;

class UnbackedClaimTest {

    @Test
    void claimWithoutProposeGetsTheNote() {
        assertEquals(AgentService.UNBACKED_NOTE, AgentService.unbackedClaimNote(
                "4,200 AED is 1,143.64 USD. The payout for claim CLM-1001 has been proposed with this amount.", false));
        assertEquals(AgentService.UNBACKED_NOTE, AgentService.unbackedClaimNote("I've submitted the payout for approval.", false));
        assertEquals(AgentService.UNBACKED_NOTE, AgentService.unbackedClaimNote("I have approved the payout on CLM-1002.", false));
    }

    @Test
    void backedClaimOrNoClaimIsLeftAlone() {
        assertNull(AgentService.unbackedClaimNote("I have proposed the payout on CLM-1008 for a manager.", true));
        assertNull(AgentService.unbackedClaimNote("CLM-1001 is UnderReview, amount 4200.00 USD.", false));
        assertNull(AgentService.unbackedClaimNote("I can propose a payout if you want.", false));
        assertNull(AgentService.unbackedClaimNote(null, false));
    }
}
