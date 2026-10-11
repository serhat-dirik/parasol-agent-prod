package org.parasol.ai;

import java.util.List;
import java.util.Optional;
import java.util.Set;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import io.quarkiverse.langchain4j.ModelName;
import io.quarkiverse.langchain4j.auth.ModelAuthProvider;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Instance;
import jakarta.inject.Inject;

/**
 * Chooses which MaaS key the model call presents, per logged-in user (layer 5, per-tier budgets).
 *
 * <p>Secured only: when the two tiered keys are configured (Secret {@code maas-portal-keys}), the
 * provider returns the contractor key for a night-shift contractor and the staff key for everyone else,
 * so {@code nina.contractor}'s night-shift storm drains only the contractor bucket (20k/10m) and Rebecca
 * (staff, 200k/10m) keeps working. In the free environment neither tiered key is set, so it falls
 * back to the single configured api-key and the SAME image behaves as before.
 *
 * <p>Contractor is decided from the CALLER's forwarded token (works on both the chat WebSocket and
 * {@code POST /agent/ask}): the token's {@code groups} claim containing {@code contractors}, OR a
 * configured list of contractor usernames ({@code maas.contractor.users}) - needed because the
 * night-shift token is minted by a client whose token carries no groups claim.
 */
@ApplicationScoped
@ModelName("parasol-chat")
public class PortalModelAuth implements ModelAuthProvider {

    private static final Logger LOG = Logger.getLogger(PortalModelAuth.class);

    @ConfigProperty(name = "maas.key.staff")
    Optional<String> staffKey;

    @ConfigProperty(name = "maas.key.contractor")
    Optional<String> contractorKey;

    /** The single key used when no tiers are configured (free). */
    @ConfigProperty(name = "quarkus.langchain4j.openai.parasol-chat.api-key")
    Optional<String> staticKey;

    /** Usernames always treated as contractors (fallback when the token has no groups claim). */
    @ConfigProperty(name = "maas.contractor.users", defaultValue = "nina.contractor")
    List<String> contractorUsers;

    @Inject
    Instance<CallerIdentity> caller;

    @Override
    public String getAuthorization(Input input) {
        boolean tiered = present(staffKey) || present(contractorKey);
        if (tiered) {
            boolean contractor = isContractor();
            String key = contractor
                    ? contractorKey.filter(PortalModelAuth::notBlank).orElse(staffKey.orElse(null))
                    : staffKey.filter(PortalModelAuth::notBlank).orElse(contractorKey.orElse(null));
            LOG.debugf("model key tier=%s", contractor ? "contractor" : "staff");
            return notBlank(key) ? "Bearer " + key : null;
        }
        return staticKey.filter(PortalModelAuth::notBlank).map(k -> "Bearer " + k).orElse(null);
    }

    private boolean isContractor() {
        String auth = callerToken();
        if (auth == null) {
            return false;
        }
        if (JwtPeek.groups(auth).contains("contractors")) {
            return true;
        }
        String user = JwtPeek.preferredUsername(auth);
        return user != null && Set.copyOf(contractorUsers).contains(user);
    }

    private String callerToken() {
        try {
            if (caller.isResolvable()) {
                String auth = caller.get().authorization();
                if (auth != null && !auth.isBlank()) {
                    return auth;
                }
            }
        } catch (RuntimeException noActiveRequest) {
            // startup / readiness: no caller -> staff tier
        }
        return null;
    }

    private static boolean present(Optional<String> o) {
        return o.filter(PortalModelAuth::notBlank).isPresent();
    }

    private static boolean notBlank(String s) {
        return s != null && !s.isBlank();
    }
}
