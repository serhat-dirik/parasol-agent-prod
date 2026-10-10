package org.parasol.ai;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Reads display claims out of a bearer JWT WITHOUT validating it. Used only for log lines and
 * the {@code caller} field in responses, never for authorization decisions: those happen at the
 * MCP gateway, which does validate the token.
 */
final class JwtPeek {

    private static final Pattern USERNAME = Pattern.compile("\"preferred_username\"\\s*:\\s*\"([^\"]+)\"");
    private static final Pattern SUB = Pattern.compile("\"sub\"\\s*:\\s*\"([^\"]+)\"");

    private JwtPeek() {
    }

    static String preferredUsername(String authorization) {
        if (authorization == null) {
            return null;
        }
        String token = authorization.startsWith("Bearer ") ? authorization.substring(7) : authorization;
        String[] parts = token.split("\\.");
        if (parts.length < 2) {
            return null;
        }
        try {
            String payload = new String(Base64.getUrlDecoder().decode(parts[1]), StandardCharsets.UTF_8);
            Matcher m = USERNAME.matcher(payload);
            if (m.find()) {
                return m.group(1);
            }
            m = SUB.matcher(payload);
            return m.find() ? m.group(1) : null;
        } catch (IllegalArgumentException e) {
            return null;
        }
    }
}
