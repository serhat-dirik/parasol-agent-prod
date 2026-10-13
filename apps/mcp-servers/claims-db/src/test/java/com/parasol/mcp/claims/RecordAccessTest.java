package com.parasol.mcp.claims;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Signature;
import java.util.Base64;
import java.util.List;
import java.util.Optional;

import org.junit.jupiter.api.Test;

/** Plain JUnit: token verification and the assigned-claims rule, with a locally generated signing key. */
class RecordAccessTest {

    static final String ISS = "https://sso.example.com/realms/parasol";
    static final Base64.Encoder B64 = Base64.getUrlEncoder().withoutPadding();

    static String jwt(KeyPair kp, String payload) throws Exception {
        String h = B64.encodeToString("{\"alg\":\"RS256\",\"kid\":\"k1\"}".getBytes(StandardCharsets.UTF_8));
        String p = B64.encodeToString(payload.getBytes(StandardCharsets.UTF_8));
        Signature s = Signature.getInstance("SHA256withRSA");
        s.initSign(kp.getPrivate());
        s.update((h + "." + p).getBytes(StandardCharsets.US_ASCII));
        return "Bearer " + h + "." + p + "." + B64.encodeToString(s.sign());
    }

    static String claims(String aud, long exp) {
        return "{\"iss\":\"" + ISS + "\",\"aud\":" + aud + ",\"exp\":" + exp + ",\"azp\":\"parasol-claims-agent\","
                + "\"preferred_username\":\"rebecca\",\"name\":\"Rebecca Torres\",\"groups\":[\"adjusters\"]}";
    }

    @Test
    void verifiesTokenAndAppliesAssignedClaimsRule() throws Exception {
        KeyPair kp = KeyPairGenerator.getInstance("RSA").generateKeyPair();
        RecordAccess a = new RecordAccess();
        // in-cluster token URL, public issuer: the issuer check uses claims.acl.issuer
        a.tokenUrl = Optional.of("https://keycloak.keycloak.svc:8443/realms/parasol/protocol/openid-connect/token");
        a.issuer = Optional.of(ISS);
        a.keys.put("k1", kp.getPublic());
        long exp = System.currentTimeMillis() / 1000 + 300;

        RecordAccess.Caller c = a.verify(jwt(kp, claims("[\"x\",\"parasol-secured/claims-db\"]", exp)));
        assertEquals("rebecca", c.user());
        assertEquals("parasol-claims-agent", c.agent());
        ClaimView mine = new ClaimView("CLM-1001", "Alice Nguyen", "auto", "UnderReview", "4200.00", "2026-05-14", "Rebecca Torres");
        ClaimView other = new ClaimView("CLM-1029", "Amara Okafor", "home", "UnderReview", "19250.00", "2026-04-11", "Angela Davis");
        assertTrue(c.mayRead(mine));
        assertFalse(c.mayRead(other));
        assertTrue(new RecordAccess.Caller("marcus", "Marcus Johnson", List.of("claims-managers"), "a").mayRead(other));

        assertThrows(RecordAccess.Denied.class, () -> a.verify(jwt(kp, claims("\"parasol-secured/policy-docs\"", exp))));
        assertThrows(RecordAccess.Denied.class, () -> a.verify(jwt(kp, claims("\"parasol-secured/claims-db\"", 1))));
        KeyPair other2 = KeyPairGenerator.getInstance("RSA").generateKeyPair();
        assertThrows(RecordAccess.Denied.class, () -> a.verify(jwt(other2, claims("\"parasol-secured/claims-db\"", exp))));
        assertThrows(RecordAccess.Denied.class, () -> a.verify(null));
        a.issuer = Optional.empty();   // issuer derived from the (in-cluster) token URL: the public token no longer matches
        assertThrows(RecordAccess.Denied.class, () -> a.verify(jwt(kp, claims("\"parasol-secured/claims-db\"", exp))));
    }
}
