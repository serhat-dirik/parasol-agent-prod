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
 * provider returns the policyholder key for a policyholder and the staff key for everyone else, so
 * {@code tom.becker}'s night-shift storm drains only the policyholder bucket (20k/10m) and Rebecca
 * (staff, 200k/10m) keeps working. In the free environment neither tiered key is set, so it falls
 * back to the single configured api-key and the SAME image behaves as before.
 *
 * <p>Policyholder is decided from the CALLER's forwarded token (works on both the chat WebSocket and
 * {@code POST /agent/ask}): the token's {@code groups} claim containing {@code policyholders}, OR a
 * configured list of policyholder usernames ({@code maas.policyholder.users}) - needed because the
 * night-shift token is minted by a client whose token carries no groups claim.
 */
@ApplicationScoped
@ModelName("parasol-chat")
public class PortalModelAuth implements ModelAuthProvider {

    private static final Logger LOG = Logger.getLogger(PortalModelAuth.class);

    @ConfigProperty(name = "maas.key.staff")
    Optional<String> staffKey;

    @ConfigProperty(name = "maas.key.policyholder")
    Optional<String> policyholderKey;

    /** The single key used when no tiers are configured (free). */
    @ConfigProperty(name = "quarkus.langchain4j.openai.parasol-chat.api-key")
    Optional<String> staticKey;

    /** Usernames always treated as policyholders (fallback when the token has no groups claim). */
    @ConfigProperty(name = "maas.policyholder.users", defaultValue = "tom.becker")
    List<String> policyholderUsers;

    @Inject
    Instance<CallerIdentity> caller;

    @Override
    public String getAuthorization(Input input) {
        boolean tiered = present(staffKey) || present(policyholderKey);
        if (tiered) {
            boolean policyholder = isPolicyholder();
            String key = policyholder
                    ? policyholderKey.filter(PortalModelAuth::notBlank).orElse(staffKey.orElse(null))
                    : staffKey.filter(PortalModelAuth::notBlank).orElse(policyholderKey.orElse(null));
            LOG.debugf("model key tier=%s", policyholder ? "policyholder" : "staff");
            return notBlank(key) ? "Bearer " + key : null;
        }
        return staticKey.filter(PortalModelAuth::notBlank).map(k -> "Bearer " + k).orElse(null);
    }

    private boolean isPolicyholder() {
        String auth = callerToken();
        if (auth == null) {
            return false;
        }
        if (JwtPeek.groups(auth).contains("policyholders")) {
            return true;
        }
        String user = JwtPeek.preferredUsername(auth);
        return user != null && Set.copyOf(policyholderUsers).contains(user);
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
