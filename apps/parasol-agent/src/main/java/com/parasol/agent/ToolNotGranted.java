package com.parasol.agent;

import java.util.function.Function;

import dev.langchain4j.agent.tool.ToolExecutionRequest;
import dev.langchain4j.data.message.ToolExecutionResultMessage;
import jakarta.enterprise.context.ApplicationScoped;

/**
 * The model asked for a tool it was not offered. In the secured environment that is the gateway's
 * per-user filtering at work (approve_payout is not in an adjuster's tool list), so tell the model,
 * and let it answer the user, instead of failing the request as a "hallucinated" tool.
 */
@ApplicationScoped
public class ToolNotGranted implements Function<ToolExecutionRequest, ToolExecutionResultMessage> {

    @Override
    public ToolExecutionResultMessage apply(ToolExecutionRequest request) {
        return ToolExecutionResultMessage.from(request, "The tool " + request.name()
                + " is not available to this user: the platform did not grant it. Do not retry; tell the user"
                + " you cannot do this for them and that a person with the right role must.");
    }
}
