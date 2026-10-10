package org.parasol.ai;

import java.util.Collection;
import java.util.Optional;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.eclipse.microprofile.jwt.JsonWebToken;

import io.quarkiverse.langchain4j.ModelName;
import io.quarkiverse.langchain4j.auth.ModelAuthProvider;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Instance;
import jakarta.inject.Inject;

/**
 * Chooses which MaaS key the model call presents, per logged-in user (layer 5, per-tier budgets).
 *
 * <p>Secured only: when the two tiered keys are configured (Secret {@code maas-portal-keys}), the
 * provider returns the policyholder key for a user in the Keycloak {@code policyholders} group and
 * the staff key for everyone else, so {@code tom.becker}'s night-shift storm drains only the
 * policyholder bucket (its own MaaSSubscription) and Rebecca keeps working. In the free environment
 * neither tiered key is set, so it falls back to the single configured api-key and the SAME image
 * behaves as before. No active identity (startup tool discovery, readiness ping) -> staff key.
 */
@ApplicationScoped
@ModelName("parasol-chat")
public class PortalModelAuth implements ModelAuthProvider {

    @ConfigProperty(name = "maas.key.staff")
    Optional<String> staffKey;

    @ConfigProperty(name = "maas.key.policyholder")
    Optional<String> policyholderKey;

    /** The single key used when no tiers are configured (free). */
    @ConfigProperty(name = "quarkus.langchain4j.openai.parasol-chat.api-key")
    Optional<String> staticKey;

    @Inject
    Instance<JsonWebToken> jwt;

    @Override
    public String getAuthorization(Input input) {
        boolean tiered = present(staffKey) || present(policyholderKey);
        if (tiered) {
            String key = isPolicyholder()
                    ? policyholderKey.filter(PortalModelAuth::notBlank).orElse(staffKey.orElse(null))
                    : staffKey.filter(PortalModelAuth::notBlank).orElse(policyholderKey.orElse(null));
            return notBlank(key) ? "Bearer " + key : null;
        }
        return staticKey.filter(PortalModelAuth::notBlank).map(k -> "Bearer " + k).orElse(null);
    }

    private boolean isPolicyholder() {
        try {
            Object groups = jwt.get().getClaim("groups");
            if (groups instanceof Collection<?> c) {
                return c.stream().map(String::valueOf)
                        .map(g -> g.startsWith("/") ? g.substring(1) : g)
                        .anyMatch("policyholders"::equals);
            }
        } catch (RuntimeException noActiveToken) {
            // startup / readiness: no request token -> staff tier
        }
        return false;
    }

    private static boolean present(Optional<String> o) {
        return o.filter(PortalModelAuth::notBlank).isPresent();
    }

    private static boolean notBlank(String s) {
        return s != null && !s.isBlank();
    }
}
