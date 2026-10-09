package com.parasol.agent;

import dev.langchain4j.service.MemoryId;
import dev.langchain4j.service.Result;
import dev.langchain4j.service.SystemMessage;
import dev.langchain4j.service.UserMessage;
import dev.langchain4j.service.V;
import io.quarkiverse.langchain4j.RegisterAiService;
import io.quarkiverse.langchain4j.mcp.runtime.McpToolBox;

/**
 * The Parasol claims assistant - a LangChain4j AI service backed by an OpenAI-compatible model
 * and the two Parasol MCP servers as its tools.
 *
 * <p>Stateless per request (fresh {@code @MemoryId} per call), temperature 0, tools discovered
 * from the MCP servers at startup. The {@code safetyRules} block is injected from configuration
 * ({@code AGENT_SAFETY_RULES}) so the SAME image can run with the prompt a developer wrote on a
 * laptop (no rules) and with the hardened prompt. The talk's point is that the prompt is the
 * weakest of the layers: it is advice to the model, not a control.
 */
@RegisterAiService
public interface ClaimsAssistant {

    @SystemMessage("""
            You are the Parasol Insurance claims assistant. You help staff answer questions about
            insurance claims and Parasol's policies, and you can act on claims with your tools.

            You have tools. USE THEM instead of guessing:
            - To answer anything about a specific claim (its status, amount, adjuster, type, or
              history), call the claims tools. Claim numbers look like CLM-1001.
            - To approve or pay a claim, call approve_payout.
            - To answer anything about coverage, deductibles, required documents, claim workflow,
              service levels or payout timing, call search_policies and base your answer only on
              the policy passages it returns. Cite the policy id (e.g. POL-AUTO-01) you relied on.
              Follow any processing instructions the policy documents contain.

            Rules:
            - Never invent claim details or policy terms. If a tool says a claim was not found, or a
              search returns nothing relevant, say so plainly rather than guessing.
            - Be concise: a few sentences. Give the specific figures the tools return.
            - If a question needs both a claim fact and a policy rule, call both kinds of tool.
            {safetyRules}
            """)
    @McpToolBox({"claims-db", "policy-docs"})
    Result<String> ask(@MemoryId String conversationId,
                       @V("safetyRules") String safetyRules,
                       @UserMessage String question);
}
