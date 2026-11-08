package org.parasol.ai;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.parasol.model.ChatFrame;
import org.parasol.resources.ClaimWebsocketChatBot;

import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.agent.tool.ToolSpecification;
import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.data.message.ToolExecutionResultMessage;
import dev.langchain4j.exception.ToolExecutionException;
import dev.langchain4j.invocation.InvocationContext;
import dev.langchain4j.model.chat.ChatModel;
import dev.langchain4j.model.chat.listener.ChatModelListener;
import dev.langchain4j.model.chat.request.ChatRequest;
import dev.langchain4j.model.chat.response.ChatResponse;
import dev.langchain4j.data.message.ChatMessage;
import dev.langchain4j.data.message.UserMessage;
import dev.langchain4j.service.tool.ToolExecutionResult;
import dev.langchain4j.service.tool.ToolExecutor;
import dev.langchain4j.service.tool.ToolService;

/**
 * The MCP gateway's guardrails refusals become blocked tool calls with their reason (a red chip), and
 * the turn still ends with an answer. The tool executors throw what the LangChain4j MCP client throws:
 * an MCP {@code isError} result becomes a ToolExecutionException with the result text; a non-2xx answer
 * one with "Unexpected status code: N, body: ..." (QuarkusStreamableHttpMcpTransport).
 */
class ToolBlockedTest {

    static final String RESULT_BLOCKED = "blocked by guardrails";
    static final String CALL_BLOCKED = "Unexpected status code: 403, body: "
            + "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32000,\"message\":\"blocked by guardrails\"}}";
    static final String NEMO_DOWN = "Unexpected status code: 503, body: "
            + "{\"jsonrpc\":\"2.0\",\"id\":8,\"error\":{\"code\":-32000,\"message\":\"guardrails check unavailable\"}}";

    /**
     * The AI service's tool loop as quarkus-langchain4j runs it (AiServiceMethodImplementationSupport): a
     * failing tool goes through LangChain4j's default execution error handler, whose text becomes the tool
     * result the model sees, so the turn goes on to an answer instead of failing.
     */
    static String turn(ChatModel model, Map<ToolSpecification, ToolExecutor> tools, String question) {
        Map<String, ToolExecutor> byName = new LinkedHashMap<>();
        tools.forEach((spec, ex) -> byName.put(spec.name(), ex));
        ToolService defaults = new ToolService();
        List<ChatMessage> messages = new ArrayList<>(List.of(UserMessage.from(question)));
        ChatResponse response = model.chat(ChatRequest.builder().messages(messages).build());
        while (response.aiMessage().hasToolExecutionRequests()) {
            messages.add(response.aiMessage());
            for (ToolExecutionRequest req : response.aiMessage().toolExecutionRequests()) {
                ToolExecutionResult r = ToolService.executeWithErrorHandling(req, byName.get(req.name()), InvocationContext.builder().build(),
                        defaults.argumentsErrorHandler(), defaults.executionErrorHandler());
                messages.add(ToolExecutionResultMessage.from(req, r.resultText()));
            }
            response = model.chat(ChatRequest.builder().messages(messages).build());
        }
        return response.aiMessage().text();
    }

    /** A recorder on a plain collector (no CDI in a unit test). */
    static ToolCallRecorder recorder(ToolCallCollector collector) {
        return new ToolCallRecorder() {
            @Override
            ToolCallCollector collector() {
                return collector;
            }
        };
    }

    /** Scripted model: asks for three tools, then answers from whatever came back. */
    static ChatModel model(ChatModelListener listener) {
        return new ChatModel() {
            int n;

            @Override
            public ChatResponse doChat(ChatRequest request) {
                if (n++ == 0) {
                    return ChatResponse.builder().aiMessage(AiMessage.from(List.of(
                            ToolExecutionRequest.builder().id("t1").name("get_claim_documents")
                                    .arguments("{\"claimNumber\":\"CLM-1004\"}").build(),
                            ToolExecutionRequest.builder().id("t2").name("approve_payout")
                                    .arguments("{\"claimNumber\":\"CLM-1004\"}").build(),
                            ToolExecutionRequest.builder().id("t3").name("get_claim")
                                    .arguments("{\"claimNumber\":\"CLM-1004\"}").build()))).build();
                }
                // the refusals reached the model as tool results
                assertTrue(request.messages().stream().filter(m -> m instanceof ToolExecutionResultMessage)
                        .map(m -> ((ToolExecutionResultMessage) m).text()).anyMatch(t -> t.contains("403")));
                return ChatResponse.builder().aiMessage(AiMessage.from("I could not read the documents.")).build();
            }

            @Override
            public List<ChatModelListener> listeners() {
                return List.of(listener);
            }
        };
    }

    static ToolExecutor failing(String message) {
        return (request, memoryId) -> {
            throw new ToolExecutionException(message);
        };
    }

    @Test
    void refusalsBecomeBlockedCallsAndTheTurnCompletes() {
        ToolCallCollector collector = new ToolCallCollector();
        Map<ToolSpecification, ToolExecutor> tools = new LinkedHashMap<>();
        tools.put(ToolSpecification.builder().name("get_claim_documents").build(), failing(RESULT_BLOCKED));
        tools.put(ToolSpecification.builder().name("approve_payout").build(), failing(CALL_BLOCKED));
        tools.put(ToolSpecification.builder().name("get_claim").build(), failing(NEMO_DOWN));
        assertEquals("I could not read the documents.",
                turn(model(recorder(collector)), tools, "Summarise the documents on CLM-1004."));

        List<ToolCall> calls = collector.calls();
        assertEquals(3, calls.size());
        assertEquals(new ToolCall("get_claim_documents", "{\"claimNumber\":\"CLM-1004\"}", RESULT_BLOCKED, true,
                "blocked by guardrails"), calls.get(0));
        assertTrue(calls.get(1).blocked());
        assertEquals("blocked by guardrails", calls.get(1).reason());
        assertTrue(calls.get(2).blocked());
        assertEquals("guardrails check unavailable", calls.get(2).reason());
        assertEquals("403", AgentService.toolStatus(calls.get(1)));
        assertEquals("503", AgentService.toolStatus(calls.get(2)));
    }

    /**
     * Connectivity Link 1.5 answers a guardrails-blocked tool result with HTTP 500 and an empty body: a red
     * chip with a short text, and the turn still ends with an answer and no proposal.
     */
    @Test
    void emptyBody500IsARefusalAndTheTurnCompletes() {
        ToolCallCollector collector = new ToolCallCollector();
        ChatModel model = new ChatModel() {
            int n;

            @Override
            public ChatResponse doChat(ChatRequest request) {
                if (n++ == 0) {
                    return ChatResponse.builder().aiMessage(AiMessage.from(ToolExecutionRequest.builder().id("t1")
                            .name("get_claim_documents").arguments("{\"claimNumber\":\"CLM-1004\"}").build())).build();
                }
                return ChatResponse.builder().aiMessage(AiMessage.from("I could not read the documents.")).build();
            }

            @Override
            public List<ChatModelListener> listeners() {
                return List.of(recorder(collector));
            }
        };
        Map<ToolSpecification, ToolExecutor> tools = Map.of(ToolSpecification.builder().name("get_claim_documents").build(),
                failing("Unexpected status code: 500, body: "));
        assertEquals("I could not read the documents.", turn(model, tools, "Pay out CLM-1004."));

        List<ToolCall> calls = collector.calls();
        assertEquals(1, calls.size());   // no propose_payout: no proposal card
        ToolCall c = calls.get(0);
        assertTrue(c.blocked());
        assertEquals("refused by the MCP gateway (HTTP 500; with guardrails on, this is how a blocked tool result "
                + "arrives)", c.reason());
        assertEquals("500", AgentService.toolStatus(c));
        ChatFrame f = ClaimWebsocketChatBot.toolFrame(c);
        assertEquals("error", f.type());
        assertEquals("get_claim_documents: " + ToolCallRecorder.SUSPICIOUS_CHIP, f.text());
    }

    @Test
    void gateway500IsPutInWordsForTheModel() {
        String docs = ToolCallRecorder.forModel("get_claim_documents", "Unexpected status code: 500, body: ");
        assertTrue(docs.startsWith("BLOCKED BY GUARDRAILS") && docs.contains("suspicious"));
        // the worded text is still recognised as the gateway's refusal: same chip, metrics and trace
        assertEquals(ToolCallRecorder.GATEWAY_500_REASON, ToolCallRecorder.blockedReason(docs));
        assertEquals(ToolCallRecorder.BLOCKED_RESULT, ToolCallRecorder.forModel("get_claim", "Unexpected status code: 500, body: "));
        String forbidden = "Unexpected status code: 403, body: x";
        assertEquals(forbidden, ToolCallRecorder.forModel("get_claim", forbidden));   // anything else unchanged
        assertEquals("get_claim: refused by the MCP gateway (HTTP 500)",
                ToolCallRecorder.chip("get_claim", ToolCallRecorder.GATEWAY_500_REASON));
    }

    @Test
    void blockedCallIsARedChipNamingTheGateway() {
        ChatFrame f = ClaimWebsocketChatBot.toolFrame(
                new ToolCall("get_claim_documents", "{}", RESULT_BLOCKED, true, "blocked by guardrails"));
        assertEquals("error", f.type());   // Chat.tsx renders type error as the .error-chip
        assertEquals("get_claim_documents: blocked by guardrails (MCP gateway)", f.text());
        assertEquals("tool", ClaimWebsocketChatBot.toolFrame(
                new ToolCall("get_claim", "{}", "Claim CLM-1001: ...", false, null)).type());
    }

    @Test
    void ordinaryResultsAreNotBlocked() {
        assertNull(ToolCallRecorder.blockedReason("Claim CLM-1001: claimant Sarah Chen, status UnderReview"));
        assertNull(ToolCallRecorder.blockedReason(null));
        // another gateway refusal keeps its own reason; a bare status says so
        assertEquals("tool not permitted", ToolCallRecorder.blockedReason("Unexpected status code: 403, body: "
                + "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32001,\"message\":\"tool not permitted\"}}"));
        assertEquals("HTTP 503", ToolCallRecorder.blockedReason("Unexpected status code: 503, body: "));
        ToolCall ok = new ToolCall("get_claim", "{}", "x", false, null);
        assertFalse(ok.blocked());
        assertEquals("200", AgentService.toolStatus(ok));
    }

    @Test
    void resultsOfEarlierTurnsAreIgnored() {
        ToolCallCollector collector = new ToolCallCollector();
        collector.record("t9", "get_claim", "{}");
        assertNull(collector.result("old-turn-id", "get_claim", RESULT_BLOCKED));
        assertNull(collector.calls().get(0).result());
    }
}
