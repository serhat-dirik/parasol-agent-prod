package org.parasol.ai;

import dev.langchain4j.service.MemoryId;
import dev.langchain4j.service.Result;
import dev.langchain4j.service.SystemMessage;
import dev.langchain4j.service.UserMessage;
import dev.langchain4j.service.V;
import io.quarkiverse.langchain4j.RegisterAiService;
import io.quarkiverse.langchain4j.ToolBox;
import io.quarkiverse.langchain4j.mcp.runtime.McpToolBox;

/**
 * The Parasol claims assistant that powers the portal chat - the SAME tool-using LangChain4j
 * service the REST agent uses, now behind the portal's WebSocket. It is backed by the MaaS model
 * (named config {@code parasol-chat}) and the Parasol MCP servers as its tools.
 *
 * <p>The WHOLE system prompt comes from configuration ({@code AGENT_SYSTEM_PROMPT_FILE}, read on every
 * turn): in secured that is the registered production prompt (gitops/envs/secured/system-prompt.txt, the same file the MLflow
 * Prompt Registry version {@code @production} is registered from); free runs {@link #LAPTOP_PROMPT}, the
 * prompt exactly as it was written on the laptop. {@code conversationId} ties a chat session's turns
 * together so follow-up questions work (A5, session memory). The talk's point is that the prompt is the
 * weakest layer: advice, not a control.
 */
@RegisterAiService(modelName = "parasol-chat")
public interface ClaimsAssistant {

    /** The prompt as written on the laptop (free): no safety rules. */
    String LAPTOP_PROMPT = """
            You are the Parasol Insurance claims assistant. You help staff answer questions about
            insurance claims and Parasol's policies, and you can act on claims with your tools.

            You have tools. USE THEM instead of guessing:
            - To answer anything about a specific claim (its status, amount, adjuster, type, or
              history), call the claims tools. Claim numbers look like CLM-1001.
            - To read the documents a customer uploaded to a claim, call get_claim_documents.
            - To approve or pay a claim, call approve_payout.
            - To answer anything about coverage, deductibles, required documents, claim workflow,
              service levels or payout timing, call search_policies and base your answer only on
              the policy passages it returns. Cite the policy id (e.g. POL-AUTO-01) you relied on.
            - To answer questions about Parasol's internal guidelines, procedures, rate cards,
              escalation, or staff and HR matters, call search_knowledge and answer only from the
              passages it returns. Cite the document titles you relied on.

            Rules:
            - Never invent claim details or policy terms. If a tool says a claim was not found, or a
              search returns nothing relevant, say so plainly rather than guessing.
            - Be concise: a few sentences. Give the specific figures the tools return.
            - If a question needs both a claim fact and a policy rule, call both kinds of tool.
            """;

    @SystemMessage("{systemPrompt}")
    @McpToolBox({"claims-db", "policy-docs", "fraud-check", "knowledge-base"})
    Result<String> ask(@MemoryId String conversationId,
                       @V("systemPrompt") String systemPrompt,
                       @UserMessage String question);

    /**
     * The SECURED variant: the same MCP tools PLUS the local {@link ProposePayoutTool}. Selected by
     * {@code portal.propose.enabled} so the free environment uses {@link #ask} and never sees the
     * propose tool (its behaviour stays byte-identical - it pays directly via the real MCP
     * approve_payout). In secured the gateway filters the real approve_payout out of an adjuster's
     * tools, so the model can only PROPOSE here (Read-Propose-Act, A2).
     */
    @SystemMessage("{systemPrompt}")
    @McpToolBox({"claims-db", "policy-docs", "fraud-check", "knowledge-base"})
    @ToolBox(ProposePayoutTool.class)
    Result<String> askWithPropose(@MemoryId String conversationId,
                                  @V("systemPrompt") String systemPrompt,
                                  @UserMessage String question);
}
