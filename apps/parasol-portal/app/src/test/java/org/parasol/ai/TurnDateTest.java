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

    @Test
    void userMessageStartsWithTodaysDate() {
        assertEquals("Today is 2026-11-06. What is the status of CLM-1001?",
                AgentService.dated("What is the status of CLM-1001?", LocalDate.of(2026, 11, 6)));
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
