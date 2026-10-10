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

    private static final Pattern GROUPS = Pattern.compile("\"groups\"\\s*:\\s*\\[([^\\]]*)\\]");
    private static final Pattern GROUP_VALUE = Pattern.compile("\"([^\"]+)\"");

    /** The token's "groups" claim values (unvalidated peek), or empty. Group names may start with "/". */
    static java.util.List<String> groups(String authorization) {
        String payload = payload(authorization);
        if (payload == null) {
            return java.util.List.of();
        }
        Matcher g = GROUPS.matcher(payload);
        if (!g.find()) {
            return java.util.List.of();
        }
        java.util.List<String> out = new java.util.ArrayList<>();
        Matcher v = GROUP_VALUE.matcher(g.group(1));
        while (v.find()) {
            String name = v.group(1);
            out.add(name.startsWith("/") ? name.substring(1) : name);
        }
        return out;
    }

    private static String payload(String authorization) {
        if (authorization == null) {
            return null;
        }
        String token = authorization.startsWith("Bearer ") ? authorization.substring(7) : authorization;
        String[] parts = token.split("\\.");
        if (parts.length < 2) {
            return null;
        }
        try {
            return new String(Base64.getUrlDecoder().decode(parts[1]), StandardCharsets.UTF_8);
        } catch (IllegalArgumentException e) {
            return null;
        }
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
