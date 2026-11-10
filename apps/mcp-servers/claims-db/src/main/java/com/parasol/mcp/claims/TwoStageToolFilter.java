package com.parasol.mcp.claims;

import io.quarkiverse.mcp.server.FilterContext;
import io.quarkiverse.mcp.server.ToolFilter;
import io.quarkiverse.mcp.server.ToolManager.ToolInfo;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * approve_claim and release_payment exist only where two-stage approval is on (secured overlay,
 * claims.two-stage.enabled): free lists the same tools as before, so its assistant keeps paying through
 * approve_payout. The tools also refuse a call when the setting is off.
 */
@ApplicationScoped
public class TwoStageToolFilter implements ToolFilter {

    @Inject
    PayoutService payouts;

    @Override
    public boolean test(ToolInfo tool, FilterContext context) {
        return payouts.twoStage() || !ClaimsTools.TWO_STAGE_TOOLS.contains(tool.name());
    }
}
