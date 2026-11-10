package com.parasol.mcp.claims;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.transaction.Transactional;

/**
 * The ONE write path in claims-db: approving a payout.
 *
 * <p>Added for the Dev Day talk "AI Agents: From localhost to Production". The read-only
 * workshop server had no way to do damage; this gives the agent a tool that moves money, so
 * identity, tool authorization and guardrails have something real to protect.
 *
 * <p>The server itself enforces nothing about WHO is calling. That is deliberate: in the
 * "free" environment nothing stops an adjuster (or an injected instruction) from paying out
 * a denied claim. In the "secured" environment the MCP gateway decides, per identity, whether
 * the tool is even visible or callable. Authorization belongs to the platform layer, not to
 * each tool's code.
 *
 * <p>Demo hygiene: events written here use ids above {@link #DEMO_EVENT_ID_BASE} and the
 * original status of every touched claim is remembered, so {@link #reset()} can put the
 * dataset back between takes without restarting the pod.
 */
@ApplicationScoped
public class PayoutService {

    private static final Logger LOG = Logger.getLogger(PayoutService.class);

    static final long DEMO_EVENT_ID_BASE = 1000L;

    static final String READY_FOR_PAYMENT = "ReadyForPayment";

    /** Original status per claim touched by a payout, for reset(). */
    private final Map<String, String> originalStatus = new ConcurrentHashMap<>();

    /** The amount stage 1 approved, per claim, for stage 2 (release_payment); cleared by reset(). */
    private final Map<String, BigDecimal> approvedAmount = new ConcurrentHashMap<>();

    /**
     * Two-stage approval (secured overlay): approve_claim (UnderReview -> ReadyForPayment) then release_payment
     * (ReadyForPayment -> Approved + PaymentIssued). With it on, the one-step approve_payout refuses. Off in free,
     * where approve_payout is the only write and pays at once.
     */
    @ConfigProperty(name = "claims.two-stage.enabled", defaultValue = "false")
    boolean twoStage;

    public boolean twoStage() {
        return twoStage;
    }

    void twoStage(boolean on) {   // tests
        twoStage = on;
    }

    @Transactional
    public String approve(String claimNumber, BigDecimal amount, String actor) {
        String number = ClaimsRepository.normalize(claimNumber);
        Claim claim = Claim.findById(number);
        if (claim == null) {
            return "No claim found with number " + number + ".";
        }
        if (twoStage) {
            return "approve_payout is not available: payments are made in two stages. approve_claim approves claim "
                    + number + "; a claims manager then releases the payment (release_payment).";
        }
        if (paidThisSession(number)) {
            return "Claim " + number + " already has a payment issued in this session; nothing done.";
        }
        BigDecimal paid = amount == null ? claim.amount : amount;
        String previous = claim.status;
        originalStatus.putIfAbsent(number, previous);

        claim.status = "Approved";
        claim.persist();

        long nextId = nextEventId();
        LocalDateTime now = LocalDateTime.now().withNano(0);
        // When a named user drove the approval, record them: secured reads "Approved by marcus via
        // parasol-claims-agent" (user + agent from the exchanged token), a bare username reads
        // "Approved by marcus via assistant". The autonomous model
        // path passes no actor (or "claims-assistant"), so it keeps the amount-first wording.
        boolean namedUser = actor != null && !actor.isBlank() && !actor.equals("claims-assistant");
        String approvedNote = namedUser
                ? "Approved by " + actor + (actor.contains(" via ") ? "" : " via assistant")
                : "Approved for " + paid.toPlainString() + " via claims assistant";
        addEvent(nextId, number, "Approved",
                approvedNote + (previous.equals("Denied") ? " - previous status was Denied" : ""),
                now);
        addEvent(nextId + 1, number, "PaymentIssued",
                "Payment of " + paid.toPlainString() + " USD issued to policyholder", now.plusSeconds(1));

        LOG.warnf("PAYOUT claim=%s amount=%s previousStatus=%s actor=%s", number, paid, previous, actor);
        return String.format(
                "Payout approved: claim %s (claimant %s) set to Approved and payment of %s USD issued."
                        + " Previous status was %s.",
                number, claim.claimant, paid.toPlainString(), previous);
    }

    /**
     * Stage 1: the claim is valid and the amount agreed. UnderReview -> ReadyForPayment; no money moves. The amount
     * defaults to the claimed amount and may not exceed it.
     */
    @Transactional
    public String approveClaim(String claimNumber, BigDecimal amount, String actor) {
        String number = ClaimsRepository.normalize(claimNumber);
        Claim claim = Claim.findById(number);
        if (claim == null) {
            return "No claim found with number " + number + ".";
        }
        if (!"UnderReview".equals(claim.status)) {
            return "Claim " + number + " is " + claim.status + ": only a claim UnderReview can be approved. Nothing done.";
        }
        BigDecimal agreed = amount == null || amount.signum() <= 0 ? claim.amount : amount;
        if (agreed.compareTo(claim.amount) > 0) {
            return "Claim " + number + ": USD " + agreed.toPlainString() + " exceeds the claimed USD "
                    + claim.amount.toPlainString() + ". Not approved.";
        }
        originalStatus.putIfAbsent(number, claim.status);
        approvedAmount.put(number, agreed);
        claim.status = READY_FOR_PAYMENT;
        claim.persist();
        String by = actor == null || actor.isBlank() ? "claims-assistant" : actor;
        addEvent(nextEventId(), number, "ClaimApproved",
                "Claim approved for USD " + agreed.toPlainString() + " by " + by, LocalDateTime.now().withNano(0));
        LOG.warnf("CLAIM APPROVED claim=%s amount=%s actor=%s", number, agreed, by);
        return String.format("Claim %s (claimant %s) approved for USD %s and set to Ready for payment. No payment has "
                + "been made: a claims manager releases the payment.", number, claim.claimant, agreed.toPlainString());
    }

    /** Stage 2: only from ReadyForPayment -> Approved, and the approved amount is paid. */
    @Transactional
    public String releasePayment(String claimNumber, String actor) {
        String number = ClaimsRepository.normalize(claimNumber);
        Claim claim = Claim.findById(number);
        if (claim == null) {
            return "No claim found with number " + number + ".";
        }
        if (!READY_FOR_PAYMENT.equals(claim.status)) {
            return "Claim " + number + " is " + claim.status + ": a payment is released only for a claim that is "
                    + "Ready for payment (approved first). Nothing paid.";
        }
        if (paidThisSession(number)) {
            return "Claim " + number + " already has a payment issued in this session; nothing done.";
        }
        BigDecimal paid = approvedAmount.getOrDefault(number, claim.amount);
        originalStatus.putIfAbsent(number, claim.status);
        claim.status = "Approved";
        claim.persist();
        String by = actor == null || actor.isBlank() ? "claims-assistant" : actor;
        long id = nextEventId();
        LocalDateTime now = LocalDateTime.now().withNano(0);
        addEvent(id, number, "Approved", "Payment released by " + by, now);
        addEvent(id + 1, number, "PaymentIssued", "Payment of " + paid.toPlainString() + " USD issued to policyholder",
                now.plusSeconds(1));
        LOG.warnf("PAYMENT RELEASED claim=%s amount=%s actor=%s", number, paid, by);
        return String.format("Payment released: claim %s (claimant %s) set to Approved and payment of %s USD issued.",
                number, claim.claimant, paid.toPlainString());
    }

    private static boolean paidThisSession(String number) {
        return history(number).stream().anyMatch(e -> "PaymentIssued".equals(e.eventType)
                && e.id != null && e.id >= DEMO_EVENT_ID_BASE);
    }

    static final String DOCUMENTS_FLAGGED = "DocumentsFlagged";

    /**
     * Record that the claim's documents were flagged as suspicious (the secured portal does this when the MCP
     * gateway's guardrails blocked them). A timeline event, so the History tab shows it and reset() removes it;
     * once per claim and session. False when the claim does not exist.
     */
    @Transactional
    public boolean flagDocuments(String claimNumber, String note) {
        String number = ClaimsRepository.normalize(claimNumber);
        if (Claim.findById(number) == null) {
            return false;
        }
        if (documentsFlag(number) == null) {
            addEvent(nextEventId(), number, DOCUMENTS_FLAGGED, note, LocalDateTime.now().withNano(0));
            LOG.warnf("DOCUMENTS FLAGGED claim=%s note=%s", number, note);
        }
        return true;
    }

    /** The note of the claim's documents flag in this session, else null. */
    public String documentsFlag(String claimNumber) {
        return history(ClaimsRepository.normalize(claimNumber)).stream()
                .filter(e -> DOCUMENTS_FLAGGED.equals(e.eventType) && e.id != null && e.id >= DEMO_EVENT_ID_BASE)
                .map(e -> e.note).findFirst().orElse(null);
    }

    /** Undo every payout made in this session (status + timeline events). */
    @Transactional
    public int reset() {
        long removed = ClaimEvent.delete("id >= ?1", DEMO_EVENT_ID_BASE);
        originalStatus.forEach((number, status) -> {
            Claim c = Claim.findById(number);
            if (c != null) {
                c.status = status;
                c.persist();
            }
        });
        int restored = originalStatus.size();
        originalStatus.clear();
        approvedAmount.clear();
        LOG.infof("RESET removed %d demo events, restored %d claim statuses", removed, restored);
        return restored;
    }

    private static List<ClaimEvent> history(String number) {
        return ClaimEvent.list("claimNumber", number);
    }

    private static long nextEventId() {
        ClaimEvent last = ClaimEvent.find("id >= ?1 order by id desc", DEMO_EVENT_ID_BASE).firstResult();
        return last == null ? DEMO_EVENT_ID_BASE : last.id + 1;
    }

    private static void addEvent(long id, String number, String type, String note, LocalDateTime at) {
        ClaimEvent e = new ClaimEvent();
        e.id = id;
        e.claimNumber = number;
        e.eventType = type;
        e.note = note;
        e.createdAt = at;
        e.persist();
    }
}
