package org.parasol.model;

/**
 * One chat turn from the portal: the claim the user is viewing and their message.
 * The assistant anchors its tools to {@code claimNumber} (e.g. CLM-1004).
 */
public record ClaimBotQuery(String claimNumber, String query) {
}
