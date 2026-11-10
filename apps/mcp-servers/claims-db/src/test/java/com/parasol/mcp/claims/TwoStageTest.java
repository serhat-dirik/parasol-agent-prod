package com.parasol.mcp.claims;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;

/** Two-stage approval (secured overlay) and the unchanged one-step payout (free). */
@QuarkusTest
class TwoStageTest {

    @Inject
    ClaimsTools tools;

    @Inject
    PayoutService payouts;

    @Inject
    ClaimsRepository repo;

    @AfterEach
    void restore() {
        payouts.twoStage(false);
        payouts.reset();
    }

    private String status(String claim) {
        return repo.find(claim).orElseThrow().status();
    }

    @Test
    void approveThenReleasePaysTheApprovedAmount() {
        payouts.twoStage(true);
        String approved = tools.approveClaim("CLM-1001", 4000.0);
        assertTrue(approved.contains("Ready for payment"), approved);
        assertEquals("ReadyForPayment", status("CLM-1001"));
        assertTrue(tools.approvePayout("CLM-1001", null, null).contains("not available"));   // one-step path closed
        String released = tools.releasePayment("CLM-1001");
        assertTrue(released.contains("4000.00 USD issued"), released);
        assertEquals("Approved", status("CLM-1001"));
        assertTrue(tools.releasePayment("CLM-1001").contains("Nothing paid"));                // only once
        assertTrue(tools.getClaimHistory("CLM-1001").contains("Claim approved for USD 4000.00 by claims-assistant"));
        payouts.reset();
        assertEquals("UnderReview", status("CLM-1001"));
    }

    @Test
    void approvalNeedsUnderReviewAndAtMostTheClaimedAmount() {
        payouts.twoStage(true);
        assertTrue(tools.approveClaim("CLM-1004", null).contains("only a claim UnderReview"));   // Denied (Showcase 2)
        assertTrue(tools.approveClaim("CLM-1001", 84000.0).contains("exceeds the claimed"));
        assertEquals("UnderReview", status("CLM-1001"));
        assertTrue(tools.releasePayment("CLM-1001").contains("Ready for payment"));               // not approved yet
        assertEquals("UnderReview", status("CLM-1001"));
    }

    @Test
    void freeKeepsTheOneStepPayoutAndRefusesTheNewTools() {
        assertTrue(tools.approveClaim("CLM-1001", null).contains("not enabled"));
        assertTrue(tools.releasePayment("CLM-1001").contains("not enabled"));
        assertTrue(tools.approvePayout("CLM-1001", null, null).startsWith("Payout approved"));
        assertEquals("Approved", status("CLM-1001"));
    }

    @Test
    void readyForPaymentIsAStatusTheListToolAccepts() {
        payouts.twoStage(true);
        tools.approveClaim("CLM-1001", null);
        assertEquals(1, tools.listClaimsByStatus("Ready for payment").size());
    }
}
