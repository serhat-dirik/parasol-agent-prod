package org.parasol.resources;

import java.util.ArrayList;
import java.util.List;

import org.parasol.ai.AgentService;
import org.parasol.ai.CallerIdentity;
import org.parasol.ai.ToolCall;
import org.parasol.model.ChatFrame;
import org.parasol.model.ClaimBotQuery;

import io.opentelemetry.instrumentation.annotations.WithSpan;
import io.quarkus.logging.Log;
import io.quarkus.oidc.AccessTokenCredential;
import io.quarkus.security.identity.SecurityIdentity;
import io.quarkus.websockets.next.OnError;
import io.quarkus.websockets.next.OnOpen;
import io.quarkus.websockets.next.OnTextMessage;
import io.quarkus.websockets.next.WebSocket;
import io.quarkus.websockets.next.WebSocketConnection;
import io.smallrye.common.annotation.Blocking;
import io.smallrye.mutiny.Multi;
import jakarta.inject.Inject;

/**
 * The portal chat, now the agent: each user message runs the tool-using {@link AgentService},
 * and every frame the UI needs is streamed back - a grey chip per MCP tool the model called, then
 * the answer (or a red error chip). The connection id is the conversation id, so follow-up
 * questions in the same chat share memory (A5).
 */
@WebSocket(path = "/ws/query")
public class ClaimWebsocketChatBot {

    @Inject
    AgentService agent;

    @Inject
    CallerIdentity caller;

    @Inject
    SecurityIdentity identity;

    @OnOpen
    public void onOpen(WebSocketConnection connection) {
        Log.infof("Chat connection %s opened", connection.id());
    }

    @OnError
    public ChatFrame onError(Throwable error) {
        Log.error("Error during chat", error);
        return ChatFrame.error("Error during chat: " + error.getMessage());
    }

    @OnTextMessage
    @Blocking
    @WithSpan("ChatMessage")
    public Multi<ChatFrame> onMessage(ClaimBotQuery query, WebSocketConnection connection) {
        Log.infof("Chat query on %s: claim=%s q=%s", connection.id(), query.claimNumber(), query.query());
        // Carry the logged-in user's OIDC token to the MCP gateway so it filters tools per that user
        // (secured). There is no JAX-RS filter on the WebSocket path, so set it from the session here.
        if (identity != null && !identity.isAnonymous()) {
            AccessTokenCredential cred = identity.getCredential(AccessTokenCredential.class);
            if (cred != null && cred.getToken() != null) {
                caller.setBearerToken(cred.getToken());
            }
        }
        String question = (query.claimNumber() == null || query.claimNumber().isBlank())
                ? query.query()
                : "The user is viewing claim " + query.claimNumber() + ". " + query.query();

        AgentService.AgentAnswer answer = agent.answer(connection.id(), question);

        List<ChatFrame> frames = new ArrayList<>();
        for (ToolCall call : answer.toolCalls()) {
            // The local propose tool surfaces as a Propose card, not a grey chip.
            if ("propose_payout".equals(call.tool())) {
                continue;
            }
            frames.add(ChatFrame.tool(call.tool(), call.arguments()));
        }
        // A2 (secured): a proposed payout becomes a card with Approve (claims-managers only).
        AgentService.Proposal p = answer.proposal();
        if (p != null) {
            String json = String.format("{\"proposed\":%s,\"claimed\":%s}",
                    p.proposed() == null ? "null" : p.proposed(),
                    p.claimed() == null ? "null" : p.claimed());
            frames.add(ChatFrame.propose(p.claimNumber(), json));
        }
        // Guardrails signal (secured path): mask -> grey chip, flag/block -> amber banner, before the answer.
        AgentService.Guardrail g = answer.guardrail();
        if (g != null) {
            if ("mask".equals(g.action())) {
                frames.add(ChatFrame.mask(g.msg() == null ? "personal data masked" : g.msg(), g.masked()));
            } else {
                frames.add(ChatFrame.guardrail(g.msg(), g.score()));
            }
        }
        if (answer.error() != null) {
            frames.add(ChatFrame.error(answer.error()));
        } else if (answer.answer() != null && !answer.answer().isBlank()) {
            frames.add(ChatFrame.answer(answer.answer()));
        }
        frames.add(ChatFrame.done());
        return Multi.createFrom().iterable(frames);
    }
}
