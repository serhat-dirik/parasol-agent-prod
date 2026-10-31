package org.parasol.ai;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

class AgentSwitchTest {

    @Test
    void disabledClientIsARefusal() {
        // what Keycloak 26 answers a disabled federated-jwt client
        assertTrue(McpBearerTokenProvider.refusedAgent(401,
                "{\"error\":\"invalid_client\",\"error_description\":\"Invalid client or Invalid client credentials\"}"));
    }

    @Test
    void otherExchangeOutcomesAreNot() {
        assertFalse(McpBearerTokenProvider.refusedAgent(200, "{\"access_token\":\"x\",\"expires_in\":300}"));
        assertFalse(McpBearerTokenProvider.refusedAgent(400,
                "{\"error\":\"invalid_request\",\"error_description\":\"Invalid token\"}"));
        assertFalse(McpBearerTokenProvider.refusedAgent(403, "{\"error\":\"access_denied\"}"));
        assertFalse(McpBearerTokenProvider.refusedAgent(401, "{\"error\":\"invalid_token\"}"));
        assertFalse(McpBearerTokenProvider.refusedAgent(503, "<html>Service Unavailable</html>"));
        assertFalse(McpBearerTokenProvider.refusedAgent(401, null));
    }

    @Test
    void disabledMessageHasItsOwnReason() {
        assertEquals("agent_disabled", AgentService.reason(AgentService.AGENT_DISABLED));
        assertEquals("offline", AgentService.reason("The assistant is offline."));
        assertEquals("usage_limit", AgentService.reason("You have reached your usage limit (429). Please try again later."));
    }
}
