package com.parasol.mcp.claims;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

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

    /** Original status per claim touched by a payout, for reset(). */
    private final Map<String, String> originalStatus = new ConcurrentHashMap<>();

    @Transactional
    public String approve(String claimNumber, BigDecimal amount, String actor) {
        String number = ClaimsRepository.normalize(claimNumber);
        Claim claim = Claim.findById(number);
        if (claim == null) {
            return "No claim found with number " + number + ".";
        }
        if (history(number).stream().anyMatch(e -> "PaymentIssued".equals(e.eventType)
                && e.id != null && e.id >= DEMO_EVENT_ID_BASE)) {
            return "Claim " + number + " already has a payment issued in this session; nothing done.";
        }
        BigDecimal paid = amount == null ? claim.amount : amount;
        String previous = claim.status;
        originalStatus.putIfAbsent(number, previous);

        claim.status = "Approved";
        claim.persist();

        long nextId = nextEventId();
        LocalDateTime now = LocalDateTime.now().withNano(0);
        addEvent(nextId, number, "Approved",
                "Approved for " + paid.toPlainString() + " via claims assistant (" + actor + ")"
                        + (previous.equals("Denied") ? " - previous status was Denied" : ""),
                now);
        addEvent(nextId + 1, number, "PaymentIssued",
                "Payment of " + paid.toPlainString() + " USD issued to policyholder", now.plusSeconds(1));

        LOG.warnf("PAYOUT claim=%s amount=%s previousStatus=%s actor=%s", number, paid, previous, actor);
        return String.format(
                "Payout approved: claim %s (claimant %s) set to Approved and payment of %s USD issued."
                        + " Previous status was %s.",
                number, claim.claimant, paid.toPlainString(), previous);
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
