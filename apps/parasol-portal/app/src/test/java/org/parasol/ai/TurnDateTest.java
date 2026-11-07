package org.parasol.ai;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.util.Optional;

import org.junit.jupiter.api.Test;

class TurnDateTest {

    /** The registered production prompt (the release registers and pins this file's text). */
    static final Path SECURED_PROMPT = Path.of("../../../gitops/envs/secured/system-prompt.txt");

    /** An unsigned token with the display claims Keycloak puts in the portal's access token. */
    static String bearer(String json) {
        java.util.Base64.Encoder b64 = java.util.Base64.getUrlEncoder().withoutPadding();
        return "Bearer " + b64.encodeToString("{\"alg\":\"none\"}".getBytes()) + "."
                + b64.encodeToString(json.getBytes()) + ".sig";
    }

    @Test
    void contextNoteFollowsTheQuestion() {
        String token = bearer("{\"preferred_username\":\"rebecca\",\"given_name\":\"Rebecca\","
                + "\"name\":\"Rebecca Torres\",\"groups\":[\"/adjusters\"]}");
        assertEquals("who am i\n\n(Signed in: Rebecca Torres (rebecca), groups adjusters. Open claim: CLM-1001. "
                        + "Today is 2026-11-07.)",
                AgentService.withContext("who am i", token, "CLM-1001", LocalDate.of(2026, 11, 7)));
    }

    @Test
    void noTokenNoClaimLeavesOnlyTheDate() {
        assertEquals("What is the status of CLM-1001?\n\n(Today is 2026-11-06.)",
                AgentService.withContext("What is the status of CLM-1001?", null, " ", LocalDate.of(2026, 11, 6)));
    }

    @Test
    void systemPromptIsTheRegisteredTextUnchanged() throws Exception {
        assumeTrue(Files.isReadable(SECURED_PROMPT), "repository checkout only");
        AgentService service = new AgentService();
        service.systemPromptFile = Optional.of(SECURED_PROMPT.toString());
        String registered = Files.readString(SECURED_PROMPT);
        assertEquals(registered, service.systemPrompt());
        assertEquals(AgentService.sha256(registered), AgentService.sha256(service.systemPrompt()));
        assertFalse(service.systemPrompt().contains("Today is"));
        assertEquals(ClaimsAssistant.LAPTOP_PROMPT, new AgentService() {
            {
                systemPromptFile = Optional.empty();
            }
        }.systemPrompt());
    }
}
