# Reference: the parasol-insurance workshop app

Copied on 2026-11-04 from the Red Hat parasol-insurance workshop application (same team, reuse agreed;
its lab copy was temporary). Reference material for the richer claim page, not built or deployed from here:

* `import.sql`, `Claim.java`: 8 claims with a customer narrative (`summary`), location, client contact,
  policy number and photo paths.
* `claim-detail.html`, `claims.html`, `style.css`: the claim page layout (header with client and policy,
  Summary tab, photo gallery on the right).

The photos are in `apps/parasol-portal/app/src/main/webui/src/app/assets/images/claims/`.
Our claim page uses three tabs, Summary (with the customer's attachments at the bottom), Insurance and
History (our timeline), plus the gallery and the assistant.
