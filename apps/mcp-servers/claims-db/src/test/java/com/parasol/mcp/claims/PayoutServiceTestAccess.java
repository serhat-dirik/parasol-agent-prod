package com.parasol.mcp.claims;

import jakarta.transaction.Transactional;

/** Test helper: how many documents flags a claim has in this session. */
final class PayoutServiceTestAccess {
    private PayoutServiceTestAccess() {
    }

    @Transactional
    static long flags(String claim) {
        return ClaimEvent.count("claimNumber = ?1 and eventType = ?2 and id >= ?3", claim,
                PayoutService.DOCUMENTS_FLAGGED, PayoutService.DEMO_EVENT_ID_BASE);
    }
}
