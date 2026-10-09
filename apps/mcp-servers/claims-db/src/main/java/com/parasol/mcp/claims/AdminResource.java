package com.parasol.mcp.claims;

import java.util.Map;

import jakarta.inject.Inject;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;

/**
 * Demo hygiene only: {@code POST /admin/reset} undoes every payout made through the
 * {@code approve_payout} tool so the dataset is back to its seeded state between takes.
 * Not an MCP tool, not reachable through the gateway.
 */
@Path("/admin")
@Produces(MediaType.APPLICATION_JSON)
public class AdminResource {

    @Inject
    PayoutService payouts;

    @POST
    @Path("/reset")
    public Map<String, Object> reset() {
        int restored = payouts.reset();
        return Map.of("reset", true, "claimsRestored", restored);
    }
}
