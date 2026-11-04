package com.parasol.mcp.claims;

import io.quarkus.hibernate.orm.panache.PanacheEntityBase;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * What the claim page shows beyond the claim record: the customer's account of the event, where and when,
 * contact, the policy and its coverage, and the photos the customer attached.
 *
 * <p>UI only, on purpose: served by {@link ClaimsApiResource} ({@code /api/claims/{number}/details}) and never
 * by an MCP tool, so the model's view of a claim ({@link ClaimView}) and every tool output stay byte-for-byte
 * what the evaluation gate and the showcases were built on.
 */
@Entity
@Table(name = "claim_details")
public class ClaimDetails extends PanacheEntityBase {

    @Id
    @Column(name = "claim_number")
    public String claimNumber;

    /** When it happened, as the customer reported it, e.g. "May 14th, 2026, at about 8:40 AM". */
    @Column(name = "event_time")
    public String eventTime;

    public String location;

    /** The customer's account of the event, as submitted with the claim. */
    @Column(length = 4000)
    public String summary;

    @Column(name = "client_email")
    public String clientEmail;

    @Column(name = "client_phone")
    public String clientPhone;

    @Column(name = "policy_number")
    public String policyNumber;

    /** Policy cover in words, e.g. "Comprehensive auto". */
    public String coverage;

    public String deductible;

    @Column(name = "coverage_limit")
    public String coverageLimit;

    /** Photo file names the portal ships, comma-separated (empty for claims without photos). */
    public String photos;
}
