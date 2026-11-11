# Conforma policy for Parasol images (task verify-conforma), used by the portal release and the vendor onboarding.
# Conforma's built-in checks come first: the image signature and the attestation signatures verify against Tekton
# Chains' keyless identity (Trusted Artifact Signer certificate + Rekor), and the attestations are well formed.
# These rules add the release requirements. Conforma evaluates rules in single-name packages only.
package parasol

import rego.v1

# METADATA
# title: Image is pinned by digest
# description: The promoted image reference must be pinned by digest, not a floating tag.
# custom:
#   short_name: image_pinned_by_digest
#   failure_msg: Image reference is not pinned by digest
deny contains result if {
	not contains(input.image.ref, "@sha256:")
	result := {
		"code": "parasol.image_pinned_by_digest",
		"msg": "Image reference is not pinned by digest",
	}
}

# METADATA
# title: Built by the expected Parasol pipeline
# description: >-
#   A SLSA provenance attestation from Tekton Chains states that the expected pipeline task built this image: the
#   portal by build-container of parasol-portal-secure-build, an onboarded vendor tool by build-onboarded-image of
#   parasol-tool-onboarding. (Chains attests the TaskRun when it finishes; the PipelineRun's own provenance only
#   exists after the whole run, so after this check.)
# custom:
#   short_name: built_by_expected_pipeline
#   failure_msg: No Tekton Chains provenance from the expected Parasol pipeline
deny contains result if {
	not built_by_expected_pipeline
	result := {
		"code": "parasol.built_by_expected_pipeline",
		"msg": sprintf("No Tekton Chains provenance from %s (task %s)", expected_builder),
	}
}

expected_builder := ["parasol-portal-secure-build", "build-container"] if {
	contains(input.image.ref, "/parasol-portal@")
} else := ["parasol-tool-onboarding", "build-onboarded-image"] if {
	contains(input.image.ref, "/currency-converter@")
} else := ["none", "none"]

built_by_expected_pipeline if {
	some att in input.attestations
	att.statement.predicateType == "https://slsa.dev/provenance/v0.2"
	p := att.statement.predicate
	p.builder.id == "https://tekton.dev/chains/v2"
	p.buildType == "tekton.dev/v1/TaskRun"
	p.invocation.environment.labels["tekton.dev/pipeline"] == expected_builder[0]
	p.invocation.environment.labels["tekton.dev/pipelineTask"] == expected_builder[1]
}
