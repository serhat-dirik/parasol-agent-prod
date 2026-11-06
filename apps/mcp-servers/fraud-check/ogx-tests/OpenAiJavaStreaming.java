///usr/bin/env jbang "$0" "$@" ; exit $?
//JAVA 21
//DEPS com.openai:openai-java:4.90.0

import java.util.List;
import java.util.Map;
import java.util.TreeMap;

import com.openai.client.OpenAIClient;
import com.openai.client.okhttp.OpenAIOkHttpClient;
import com.openai.core.JsonValue;
import com.openai.core.http.StreamResponse;
import com.openai.models.responses.ResponseCreateParams;
import com.openai.models.responses.ResponseStreamEvent;
import com.openai.models.responses.Tool;

/** Check 5: the openai-java SDK streams a Responses API turn from OGX, MCP tool call included. */
public class OpenAiJavaStreaming {
    public static void main(String[] args) {
        String model = System.getenv("MODEL");
        OpenAIClient client = OpenAIOkHttpClient.fromEnv();   // OPENAI_BASE_URL = OGX; OGX ignores the key
        Tool.Mcp mcp = Tool.Mcp.builder()
                .serverLabel("claims-db")
                .serverUrl(System.getenv("GW"))
                .headers(Tool.Mcp.Headers.builder()
                        .putAdditionalProperty("X-Mcp-Virtualserver", JsonValue.from("parasol-secured/claims-db")).build())
                .authorization(System.getenv("TOKEN"))
                .allowedTools(Tool.Mcp.AllowedTools.ofMcp(List.of("get_claim")))
                .requireApproval(Tool.Mcp.RequireApproval.McpToolApprovalSetting.NEVER)
                .build();
        ResponseCreateParams params = ResponseCreateParams.builder()
                .model(model)
                .input("What is the status of claim CLM-1004? Answer in one sentence. /no_think")
                .addTool(mcp)
                .build();
        Map<String, Integer> events = new TreeMap<>();
        StringBuilder text = new StringBuilder();
        String status = "none";
        try (StreamResponse<ResponseStreamEvent> stream = client.responses().createStreaming(params)) {
            for (ResponseStreamEvent e : (Iterable<ResponseStreamEvent>) stream.stream()::iterator) {
                String s = e.toString();   // "ResponseStreamEvent{mcpCallCompleted=...}": the variant name
                events.merge(s.substring(s.indexOf('{') + 1, Math.max(s.indexOf('{') + 1, s.indexOf('='))), 1, Integer::sum);
                e.outputTextDelta().ifPresent(d -> text.append(d.delta()));
                if (e.isCompleted()) {
                    status = e.asCompleted().response().status().map(Object::toString).orElse("?");
                }
            }
        }
        events.forEach((k, v) -> System.out.println("  event " + k + " x" + v));
        System.out.println("  text: " + text.toString().strip().replace('\n', ' '));
        System.out.println("status: " + status);
        boolean ok = "completed".equals(status) && text.length() > 0 && events.keySet().stream().anyMatch(k -> k.startsWith("mcpCallCompleted"));
        System.out.println(ok ? "PASS  openai-java streams an OGX Responses turn with an MCP call" : "FAIL  see above");
        System.exit(ok ? 0 : 1);
    }
}
