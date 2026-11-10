package org.parasol.ai;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;

import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.data.message.AiMessage;
import dev.langchain4j.data.message.ChatMessage;
import dev.langchain4j.data.message.SystemMessage;
import dev.langchain4j.data.message.ToolExecutionResultMessage;
import dev.langchain4j.data.message.UserMessage;
import dev.langchain4j.model.chat.listener.ChatModelRequestContext;
import dev.langchain4j.model.chat.listener.ChatModelResponseContext;
import io.opentelemetry.api.trace.Span;
import io.quarkiverse.langchain4j.runtime.listeners.ChatModelSpanContributor;
import jakarta.enterprise.context.ApplicationScoped;

/**
 * Makes each turn readable in MLflow. MLflow 3.14 ingests OTLP spans and reads three attributes
 * (mlflow/tracing/constant.py SpanAttributeKey; JSON strings, un-nested by sanitize_attributes on ingest):
 * {@code mlflow.spanType} (AGENT, CHAT_MODEL, TOOL), {@code mlflow.spanInputs} and {@code mlflow.spanOutputs};
 * the root span's inputs and outputs become the trace's Request and Response.
 *
 * <p>quarkus-langchain4j hands every {@link ChatModelSpanContributor} bean the span of each model call, so
 * this bean records the messages sent (OpenAI chat format) and the reply. Secured stores the text after the
 * same personal-data masking the guardrails proxy applies before the model (see {@link #mask}); every
 * recorded text is masked, which covers at least what the model saw. Each text is capped so a batch of
 * spans stays well below the collector's message size limit.
 */
@ApplicationScoped
public class TraceContent implements ChatModelSpanContributor {

    static final String TYPE = "mlflow.spanType";
    static final String INPUTS = "mlflow.spanInputs";
    static final String OUTPUTS = "mlflow.spanOutputs";

    static final int MAX_TEXT = 4000;

    private static final ObjectMapper JSON = new ObjectMapper();

    /**
     * The guardrails proxy's personal-data patterns (gitops/platform/guardrails/guardrails-rules.yaml,
     * pii.json) and its replacement text. The portal does not see the masked message the proxy forwards, so
     * it applies the same patterns before recording.
     * ponytail: a copy of three regexes; a pattern added to pii.json must be added here too.
     */
    static final Map<String, Pattern> PII = Map.of(
            "email", Pattern.compile("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"),
            "Emirates ID", Pattern.compile("\\b784-?\\d{4}-?\\d{7}-?\\d\\b"),
            "payment card", Pattern.compile("\\b\\d{4}[ -]?\\d{4}[ -]?\\d{4}[ -]?\\d{4}\\b"));

    /** Secured (the controlled environment): record masked text. Free records nothing anyway (no exporter). */
    @ConfigProperty(name = "portal.secured", defaultValue = "false")
    boolean secured;

    static String mask(String text) {
        if (text == null) {
            return null;
        }
        String t = text;
        for (Map.Entry<String, Pattern> p : PII.entrySet()) {
            t = p.getValue().matcher(t).replaceAll("[" + p.getKey() + " redacted]");
        }
        return t;
    }

    /** The text to record: capped, and masked on the secured side. */
    static String text(String text, boolean secured) {
        if (text == null) {
            return null;
        }
        String t = secured ? mask(text) : text;
        return t.length() > MAX_TEXT ? t.substring(0, MAX_TEXT) + " ...[truncated]" : t;
    }

    static String json(Object value) {
        try {
            return JSON.writeValueAsString(value);
        } catch (JsonProcessingException e) {
            return String.valueOf(value);
        }
    }

    /** Type, inputs and (optional) outputs on a span, the inputs and outputs as JSON. */
    static void record(Span span, String type, Object inputs, Object outputs) {
        span.setAttribute(TYPE, type);
        if (inputs != null) {
            span.setAttribute(INPUTS, json(inputs));
        }
        if (outputs != null) {
            span.setAttribute(OUTPUTS, json(outputs));
        }
    }

    /** The turn's root span: the AGENT span, the question as its inputs (the trace's Request). */
    static void question(Span root, String question, boolean secured) {
        Map<String, Object> in = new LinkedHashMap<>();
        in.put("question", text(question, secured));
        record(root, "AGENT", in, null);
    }

    /** The answer the user got (or the error the chat showed) as the root's outputs (the trace's Response). */
    static void answer(Span root, String answer, String error, boolean secured) {
        Map<String, Object> out = new LinkedHashMap<>();
        if (error != null) {
            out.put("error", error);
        } else {
            out.put("answer", text(answer == null ? "" : answer, secured));
        }
        root.setAttribute(OUTPUTS, json(out));
    }

    /** One chat message in the OpenAI format MLflow renders as a conversation. */
    static Map<String, Object> message(ChatMessage m, boolean secured) {
        Map<String, Object> out = new LinkedHashMap<>();
        if (m instanceof SystemMessage s) {
            out.put("role", "system");
            out.put("content", text(s.text(), secured));
        } else if (m instanceof UserMessage u) {
            out.put("role", "user");
            out.put("content", text(u.hasSingleText() ? u.singleText() : String.valueOf(u.contents()), secured));
        } else if (m instanceof AiMessage a) {
            out.put("role", "assistant");
            out.put("content", text(a.text(), secured));
            if (a.hasToolExecutionRequests()) {
                List<Map<String, Object>> calls = new ArrayList<>();
                for (ToolExecutionRequest r : a.toolExecutionRequests()) {
                    calls.add(Map.of("id", String.valueOf(r.id()), "type", "function",
                            "function", Map.of("name", r.name(), "arguments", text(r.arguments(), secured))));
                }
                out.put("tool_calls", calls);
            }
        } else if (m instanceof ToolExecutionResultMessage t) {
            out.put("role", "tool");
            out.put("tool_call_id", String.valueOf(t.id()));
            out.put("name", t.toolName());
            out.put("content", text(t.text(), secured));
        } else {
            out.put("role", String.valueOf(m.type()).toLowerCase());
            out.put("content", text(String.valueOf(m), secured));
        }
        return out;
    }

    static Map<String, Object> chatInputs(List<ChatMessage> messages, boolean secured) {
        return Map.of("messages", messages.stream().map(m -> message(m, secured)).toList());
    }

    static Map<String, Object> chatOutputs(AiMessage reply, String finishReason, boolean secured) {
        Map<String, Object> choice = new LinkedHashMap<>();
        choice.put("index", 0);
        choice.put("message", message(reply, secured));
        choice.put("finish_reason", finishReason);
        return Map.of("choices", List.of(choice));
    }

    @Override
    public void onRequest(ChatModelRequestContext ctx, Span span) {
        record(span, "CHAT_MODEL", chatInputs(ctx.chatRequest().messages(), secured), null);
    }

    @Override
    public void onResponse(ChatModelResponseContext ctx, Span span) {
        AiMessage reply = ctx.chatResponse().aiMessage();
        if (reply != null) {
            String finish = ctx.chatResponse().finishReason() == null ? null
                    : ctx.chatResponse().finishReason().name().toLowerCase();
            span.setAttribute(OUTPUTS, json(chatOutputs(reply, finish, secured)));
        }
    }
}
