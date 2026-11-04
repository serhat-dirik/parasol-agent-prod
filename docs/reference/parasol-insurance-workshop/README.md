# Reference: the parasol-insurance workshop app

Copied on 2026-11-04 from the Red Hat parasol-insurance workshop app (same team, reuse agreed), whose
lab GitLab is temporary. Reference material for the richer claim page, not built or deployed from here:

* `import.sql`, `Claim.java`: 8 claims with a customer narrative (`summary`), location, client contact,
  policy number and photo paths.
* `claim-detail.html`, `claims.html`, `style.css`: the claim page layout (header with client and policy,
  Summary tab, photo gallery on the right).

The photos are in `apps/parasol-portal/app/src/main/webui/src/app/assets/images/claims/`.
Our claim page keeps its Timeline, Documents and assistant; the Summary tab and the gallery are added.
