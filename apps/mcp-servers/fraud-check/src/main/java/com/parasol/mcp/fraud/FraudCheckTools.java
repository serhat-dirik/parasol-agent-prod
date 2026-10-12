package com.parasol.mcp.fraud;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.eclipse.microprofile.rest.client.inject.RestClient;

import io.quarkiverse.mcp.server.Tool;
import io.quarkiverse.mcp.server.ToolArg;
import io.opentelemetry.api.trace.Span;
import io.vertx.core.http.HttpServerRequest;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Instance;
import jakarta.inject.Inject;
import jakarta.ws.rs.WebApplicationException;

/**
 * The fraud-check agent's single MCP tool. This service is a SECOND agent behind the MCP gateway:
 * the claims assistant calls {@code fraud_check} agent-to-agent through the gateway, with the
 * caller's own Keycloak token, so the same per-identity authz applies (the gateway's AuthPolicy
 * checks {@code tool:fraud_check} on the {@code parasol-secured/fraud-check} resource client).
 *
 * <p>The verdict is DETERMINISTIC on purpose. A money-risk decision must be reliable and reproducible,
 * and the demo's thesis is "do not trust the model for money": the inflation flag is a hard numeric
 * rule over the real claim record and the uploaded document, not a model opinion. (Swap-ready: a
 * LangChain4j {@code @RegisterAiService} could phrase the rationale from these same facts - one
 * env/dependency change - but the RISK level stays rule-driven.)
 */
@ApplicationScoped
public class FraudCheckTools {

    @Inject
    @RestClient
    ClaimsDbClient claimsDb;

    @ConfigProperty(name = "fraud.inflation-threshold", defaultValue = "1.5")
    double inflationThreshold;

    @Inject
    GatewayTools gateway;

    @Inject
    Instance<HttpServerRequest> request;

    @Tool(name = "fraud_check",
            description = "Assess the fraud risk of a Parasol Insurance claim before any payout. "
                    + "Looks up the claim record and the documents the customer uploaded, then "
                    + "compares the amount requested in the documents against the amount on the "
                    + "claim record and checks the documents for anything suspicious. "
                    + "Returns a risk verdict (HIGH, MEDIUM or LOW) with the specific figures and the "
                    + "reasons. Call this before approving or paying a claim, especially when a "
                    + "document asks for a different or larger amount than the claim record. "
                    + "The claim number looks like CLM-1004.")
    public String fraudCheck(
            @ToolArg(description = "The claim number to assess, e.g. CLM-1004") String claimNumber) {
        if (gateway.enabled()) {
            return viaGateway(claimNumber);
        }
        ClaimsDbClient.ClaimRecord record;
        List<ClaimsDbClient.Document> docs;
        try {
            record = claimsDb.claim(claimNumber);
            docs = claimsDb.documents(claimNumber);
        } catch (WebApplicationException e) {
            if (e.getResponse() != null && e.getResponse().getStatus() == 404) {
                return "FRAUD RISK: UNKNOWN. No claim found with number " + claimNumber
                        + "; nothing to assess.";
            }
            throw e;
        }
        return assess(record, docs, inflationThreshold).format();
    }

    /**
     * Secured: read the claim and its documents through the MCP gateway as THIS agent on behalf of the
     * user (claims agent -> fraud agent -> tools), never with a token of its own and never directly.
     */
    private String viaGateway(String claimNumber) {
        String auth = request.get().getHeader("Authorization");
        if (auth == null || !auth.startsWith("Bearer ")) {
            return "FRAUD RISK: UNKNOWN. No caller identity on this request; nothing assessed.";
        }
        String subject = auth.substring(7).trim();
        Span.current().setAttribute("enduser.id", GatewayTools.user(subject));
        Span.current().setAttribute("gen_ai.agent.name", gateway.agentId());
        String token = gateway.onBehalfOf(subject);
        if (token == null) {
            return "FRAUD RISK: UNKNOWN. The fraud-check agent could not act on behalf of "
                    + GatewayTools.user(subject) + "; nothing assessed.";
        }
        String claim = gateway.callClaimsDb(token, "get_claim", claimNumber);
        Matcher amount = RECORD_AMOUNT.matcher(claim);
        if (!amount.find()) {
            return "FRAUD RISK: UNKNOWN. No claim found with number " + claimNumber + "; nothing to assess.";
        }
        ClaimsDbClient.ClaimRecord record = new ClaimsDbClient.ClaimRecord(claimNumber.trim().toUpperCase(),
                null, null, null, amount.group(1), null, null);
        return assess(record, documents(gateway.callClaimsDb(token, "get_claim_documents", claimNumber)),
                inflationThreshold).format();
    }

    /** "... amount 8400.00 USD ..." in the get_claim sentence. */
    private static final Pattern RECORD_AMOUNT = Pattern.compile("amount ([0-9][0-9,]*(?:\\.[0-9]+)?) USD");

    /** A paragraph addressed to the assistant: the hidden note, as the tool text carries it. */
    private static final Pattern ADDRESSED = Pattern.compile(
            "(?i)note to the claims assistant|assistant action required|automated processing note");

    /**
     * Split the get_claim_documents text back into documents. Each document is visible text followed by
     * any hidden note (the tool returns the full text, as "select all" would); a paragraph addressed to
     * the assistant is the hidden note.
     */
    static List<ClaimsDbClient.Document> documents(String text) {
        List<ClaimsDbClient.Document> docs = new ArrayList<>();
        if (text == null || text.startsWith("No documents")) {
            return docs;
        }
        for (String chunk : text.split("\n\n---\n\n")) {
            StringBuilder visible = new StringBuilder();
            StringBuilder hidden = new StringBuilder();
            for (String para : chunk.split("\n\n")) {
                (ADDRESSED.matcher(para).find() ? hidden : visible).append(para).append("\n\n");
            }
            docs.add(new ClaimsDbClient.Document(null, null, visible.toString().strip(), hidden.toString().strip()));
        }
        return docs;
    }

    // ---- pure, testable logic -------------------------------------------------------------------

    /** A single AED/number amount followed on the line. Grabs the digits (with thousands commas). */
    private static final Pattern AMOUNT = Pattern.compile("AED\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)",
            Pattern.CASE_INSENSITIVE);

    /** The risk verdict. {@code risk} leads the formatted output so a UI chip can read the level. */
    public record Verdict(String risk, String claimNumber, BigDecimal recordAmount,
                          BigDecimal documentTotal, BigDecimal ratio, List<String> reasons) {

        public String format() {
            StringBuilder sb = new StringBuilder();
            sb.append("FRAUD RISK: ").append(risk).append(". Claim ").append(claimNumber);
            if (recordAmount != null) {
                sb.append(" (record amount ").append(recordAmount.toPlainString()).append(")");
            }
            sb.append(".\n");
            if (reasons.isEmpty()) {
                sb.append("- No fraud indicators found.");
            } else {
                for (String r : reasons) {
                    sb.append("- ").append(r).append("\n");
                }
                sb.setLength(sb.length() - 1);
            }
            if ("HIGH".equals(risk)) {
                sb.append("\nRecommendation: do NOT approve the document amount; route to a human"
                        + " fraud reviewer.");
            }
            return sb.toString();
        }
    }

    /**
     * Assess a claim from its record and uploaded documents. Flags, in order:
     *  - the document total is >= threshold times the claim record amount (amount inflation);
     *  - a document carries a hidden note addressed to the assistant (tampering / injection vehicle).
     * HIGH if the amount is inflated; MEDIUM if only a hidden note is present; LOW otherwise.
     */
    public static Verdict assess(ClaimsDbClient.ClaimRecord record,
                                 List<ClaimsDbClient.Document> docs, double threshold) {
        String claimNumber = record == null ? "?" : record.claimNumber();
        BigDecimal recordAmount = parseAmount(record == null ? null : record.amount());
        BigDecimal docTotal = maxDocumentAmount(docs);
        boolean hiddenNote = docs != null && docs.stream()
                .anyMatch(d -> d.hiddenNote() != null && !d.hiddenNote().isBlank());

        List<String> reasons = new ArrayList<>();
        BigDecimal ratio = null;
        boolean inflated = false;
        if (recordAmount != null && recordAmount.signum() > 0 && docTotal != null) {
            ratio = docTotal.divide(recordAmount, 2, RoundingMode.HALF_UP);
            if (ratio.doubleValue() >= threshold) {
                inflated = true;
                reasons.add(String.format(
                        "Amount mismatch: the uploaded document requests AED %s, which is %sx the"
                                + " claim record amount of AED %s. The record is authoritative; the"
                                + " document total looks inflated.",
                        docTotal.toPlainString(), ratio.toPlainString(), recordAmount.toPlainString()));
            }
        } else if (docTotal != null && recordAmount != null) {
            reasons.add(String.format("Document requests AED %s against a record amount of AED %s.",
                    docTotal.toPlainString(), recordAmount.toPlainString()));
        }
        if (hiddenNote) {
            reasons.add("The uploaded document carries a hidden note addressed to the claims"
                    + " assistant (white-text / out-of-band instruction). Legitimate estimates do"
                    + " not instruct the processor - treat as tampering.");
        }

        String risk = inflated ? "HIGH" : (hiddenNote ? "MEDIUM" : "LOW");
        return new Verdict(risk, claimNumber, recordAmount, docTotal, ratio, reasons);
    }

    /** Largest AED amount across all documents' visible text - the estimate's TOTAL line. */
    static BigDecimal maxDocumentAmount(List<ClaimsDbClient.Document> docs) {
        if (docs == null) {
            return null;
        }
        BigDecimal max = null;
        for (ClaimsDbClient.Document d : docs) {
            if (d.visibleText() == null) {
                continue;
            }
            Matcher m = AMOUNT.matcher(d.visibleText());
            while (m.find()) {
                BigDecimal v = new BigDecimal(m.group(1).replace(",", ""));
                if (max == null || v.compareTo(max) > 0) {
                    max = v;
                }
            }
        }
        return max;
    }

    static BigDecimal parseAmount(String raw) {
        if (raw == null || raw.isBlank()) {
            return null;
        }
        try {
            return new BigDecimal(raw.replace(",", "").trim());
        } catch (NumberFormatException e) {
            return null;
        }
    }
}
