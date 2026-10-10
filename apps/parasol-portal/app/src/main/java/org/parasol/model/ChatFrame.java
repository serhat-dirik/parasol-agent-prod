package org.parasol.model;

/**
 * One frame streamed back over the chat WebSocket. {@code type} drives the UI:
 *   tool      a grey chip "called {text}({data})"            (text = tool name, data = JSON args)
 *   answer    the assistant's text answer                    (text = answer)
 *   propose   a write the assistant proposes, needs approval (text = tool name, data = JSON args) [A2]
 *   error     a red chip / message                           (text = message)
 *   guardrail an amber banner                                (text = message, data = score)
 *   mask      a "personal data masked" chip                  (text = message, data = masked types)
 *   done      end of this turn
 */
public record ChatFrame(String type, String text, String data) {
    public static ChatFrame tool(String name, String args) { return new ChatFrame("tool", name, args); }
    public static ChatFrame answer(String text)            { return new ChatFrame("answer", text, null); }
    public static ChatFrame error(String text)             { return new ChatFrame("error", text, null); }
    public static ChatFrame done()                         { return new ChatFrame("done", null, null); }
}
