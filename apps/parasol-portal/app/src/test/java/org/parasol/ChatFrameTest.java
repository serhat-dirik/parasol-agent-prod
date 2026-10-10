package org.parasol;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;
import org.parasol.model.ChatFrame;

/**
 * Smoke test for the chat frame factories the WebSocket streams to the UI. Plain JUnit (no app
 * boot) so it stays fast and offline; the end-to-end chat path is verified on-cluster in the browser.
 */
class ChatFrameTest {

    @Test
    void factoriesSetTypeAndFields() {
        ChatFrame tool = ChatFrame.tool("approve_payout", "{\"claimNumber\":\"CLM-1004\"}");
        assertEquals("tool", tool.type());
        assertEquals("approve_payout", tool.text());
        assertEquals("{\"claimNumber\":\"CLM-1004\"}", tool.data());

        assertEquals("answer", ChatFrame.answer("ok").type());
        assertEquals("error", ChatFrame.error("nope").type());
        assertEquals("done", ChatFrame.done().type());
    }
}
