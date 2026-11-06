package org.parasol.ai;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.data.message.ChatMessage;
import dev.langchain4j.data.message.SystemMessage;
import dev.langchain4j.data.message.ToolExecutionResultMessage;
import dev.langchain4j.data.message.UserMessage;
import dev.langchain4j.model.ModelProvider;
import dev.langchain4j.model.chat.listener.ChatModelRequestContext;
import dev.langchain4j.model.chat.listener.ChatModelResponseContext;
import dev.langchain4j.model.chat.request.ChatRequest;
import dev.langchain4j.model.chat.response.ChatResponse;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Scope;
import io.opentelemetry.sdk.common.CompletableResultCode;
import io.opentelemetry.sdk.trace.SdkTracerProvider;
import io.opentelemetry.sdk.trace.data.SpanData;
import io.opentelemetry.sdk.trace.export.SimpleSpanProcessor;
import io.opentelemetry.sdk.trace.export.SpanExporter;

/**
 * A secured chat turn's spans carry what MLflow 3.14 shows: the root is the AGENT span with the
 * question and the answer, each model call a CHAT_MODEL span with the messages sent and the reply, each
 * tool call a TOOL span with its arguments and its result under it; personal data is masked.
 */
class TraceContentTest {

    static final ObjectMapper JSON = new ObjectMapper();

    /** In-memory exporter: the spans as they would leave for the collector. */
    static final class Memory implements SpanExporter {
        final List<SpanData> spans = new ArrayList<>();

        @Override
        public CompletableResultCode export(Collection<SpanData> batch) {
            spans.addAll(batch);
            return CompletableResultCode.ofSuccess();
        }

        @Override
        public CompletableResultCode flush() {
            return CompletableResultCode.ofSuccess();
        }

        @Override
        public CompletableResultCode shutdown() {
            return CompletableResultCode.ofSuccess();
        }

        SpanData named(String name) {
            return spans.stream().filter(s -> s.getName().equals(name)).findFirst().orElseThrow(() -> new AssertionError(name));
        }

        List<SpanData> typed(String type) {
            return spans.stream().filter(s -> type.equals(s.getAttributes().get(AttributeKey.stringKey(TraceContent.TYPE)))).toList();
        }
    }

    static String attr(SpanData s, String key) {
        return s.getAttributes().get(AttributeKey.stringKey(key));
    }

    static JsonNode json(SpanData s, String key) throws Exception {
        return JSON.readTree(attr(s, key));
    }

    static ChatModelRequestContext request(List<ChatMessage> messages) {
        return new ChatModelRequestContext(ChatRequest.builder().messages(messages).build(), ModelProvider.OTHER, Map.of());
    }

    static ChatModelResponseContext response(List<ChatMessage> messages, AiMessage reply) {
        return new ChatModelResponseContext(ChatResponse.builder().aiMessage(reply).build(),
                ChatRequest.builder().messages(messages).build(), ModelProvider.OTHER, Map.of());
    }

    @Test
    void securedTurnIsReadableAndMasked() throws Exception {
        Memory memory = new Memory();
        ToolCallCollector collector = new ToolCallCollector();
        PortalSpanProcessor names = new PortalSpanProcessor() {
            @Override
            ToolCallCollector collector() {
                return collector;
            }
        };
        names.secured = true;
        SdkTracerProvider provider = SdkTracerProvider.builder().addSpanProcessor(names)
                .addSpanProcessor(SimpleSpanProcessor.create(memory)).build();
        Tracer tracer = provider.get("test");
        ToolCallRecorder recorder = ToolBlockedTest.recorder(collector);
        recorder.tracer = tracer;
        recorder.secured = true;
        TraceContent content = new TraceContent();
        content.secured = true;

        String question = "Mail the summary of CLM-1006 to sarah.chen@example.com please.";
        Span root = tracer.spanBuilder("ChatMessage").startSpan();
        root.setAttribute("session.id", "rebecca");
        root.setAttribute("user.id", "rebecca");
        try (Scope ignored = root.makeCurrent()) {
            TraceContent.question(root, question, true);
            List<ChatMessage> sent = new ArrayList<>(List.of(SystemMessage.from("You are the claims assistant."),
                    UserMessage.from(AgentService.dated(question, java.time.LocalDate.of(2026, 11, 6)))));
            // model call 1: asks for get_claim
            Span chat1 = tracer.spanBuilder("completion parasol-chat").startSpan();
            AiMessage call = AiMessage.from(List.of(ToolExecutionRequest.builder().id("t1").name("get_claim")
                    .arguments("{\"claimNumber\":\"CLM-1006\"}").build()));
            content.onRequest(request(sent), chat1);
            recorder.onResponse(response(sent, call));
            content.onResponse(response(sent, call), chat1);
            chat1.end();
            // the MCP client's tool span
            tracer.spanBuilder("tools/call get_claim").startSpan().end();
            sent.add(call);
            sent.add(ToolExecutionResultMessage.from("t1", "get_claim",
                    "Claim CLM-1006: claimant Michael Turner, status UnderReview, contact m.turner@example.com"));
            // model call 2: the answer
            Span chat2 = tracer.spanBuilder("completion parasol-chat").startSpan();
            AiMessage reply = AiMessage.from("CLM-1006 is UnderReview.");
            recorder.onRequest(request(sent));
            content.onRequest(request(sent), chat2);
            content.onResponse(response(sent, reply), chat2);
            chat2.end();
            TraceContent.answer(root, reply.text(), null, true);
        }
        root.end();

        SpanData agent = memory.named("ChatMessage");
        assertEquals("AGENT", attr(agent, TraceContent.TYPE));
        assertEquals("Mail the summary of CLM-1006 to [email redacted] please.",
                json(agent, TraceContent.INPUTS).get("question").asText());
        assertEquals("CLM-1006 is UnderReview.", json(agent, TraceContent.OUTPUTS).get("answer").asText());
        assertEquals("rebecca", attr(agent, "session.id"));
        assertEquals("rebecca", attr(agent, "user.id"));

        List<SpanData> chats = memory.typed("CHAT_MODEL");
        assertEquals(2, chats.size());
        JsonNode msgs = json(chats.get(1), TraceContent.INPUTS).get("messages");
        assertEquals("system", msgs.get(0).get("role").asText());
        assertEquals("Today is 2026-11-06. Mail the summary of CLM-1006 to [email redacted] please.",
                msgs.get(1).get("content").asText());
        assertEquals("get_claim", msgs.get(2).get("tool_calls").get(0).get("function").get("name").asText());
        assertEquals("tool", msgs.get(3).get("role").asText());
        assertTrue(msgs.get(3).get("content").asText().endsWith("contact [email redacted]"));
        assertEquals("CLM-1006 is UnderReview.", json(chats.get(1), TraceContent.OUTPUTS)
                .get("choices").get(0).get("message").get("content").asText());
        assertEquals("get_claim", json(chats.get(0), TraceContent.OUTPUTS).get("choices").get(0)
                .get("message").get("tool_calls").get(0).get("function").get("name").asText());

        SpanData tool = memory.named("tool.get_claim");
        assertEquals("TOOL", attr(tool, TraceContent.TYPE));
        assertEquals("CLM-1006", json(tool, TraceContent.INPUTS).get("claimNumber").asText());
        SpanData result = memory.named("tool.get_claim.result");
        assertEquals(tool.getSpanId(), result.getParentSpanId());
        assertTrue(json(result, TraceContent.OUTPUTS).get("result").asText().startsWith("Claim CLM-1006: claimant"));

        // nothing in the exported spans carries the unmasked address
        assertFalse(memory.spans.stream().flatMap(s -> s.getAttributes().asMap().values().stream())
                .anyMatch(v -> String.valueOf(v).contains("@example.com")));
    }

    @Test
    void freeRecordsTextAsIsAndLongTextIsCapped() {
        assertEquals("a@b.co", TraceContent.text("a@b.co", false));
        assertEquals("[email redacted] [Emirates ID redacted] [payment card redacted]",
                TraceContent.mask("a@b.co 784-1985-1234567-1 4111 1111 1111 1111"));
        assertTrue(TraceContent.text("x".repeat(TraceContent.MAX_TEXT + 10), true).endsWith("...[truncated]"));
    }
}
