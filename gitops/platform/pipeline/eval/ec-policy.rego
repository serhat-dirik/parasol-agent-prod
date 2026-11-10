# Conforma (Enterprise Contract) policy for the Parasol portal release (task verify-enterprise-contract).
# Conforma's built-in checks come first: the image signature and the attestation signatures verify against the
# Tekton Chains key, and the attestations are well formed. These rules add the release requirements.
# Conforma evaluates rules in single-name packages only.
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
# title: Built by the Parasol release pipeline
# description: >-
#   A SLSA provenance attestation from Tekton Chains states that the build-container TaskRun of a
#   parasol-portal-secure-build run built this image. (Chains attests the TaskRun when it finishes; the PipelineRun's
#   own provenance only exists after the whole run, so after this check.)
# custom:
#   short_name: built_by_release_pipeline
#   failure_msg: No Tekton Chains provenance from the parasol-portal-secure-build pipeline
deny contains result if {
	not built_by_release_pipeline
	result := {
		"code": "parasol.built_by_release_pipeline",
		"msg": "No Tekton Chains provenance from the parasol-portal-secure-build pipeline",
	}
}

built_by_release_pipeline if {
	some att in input.attestations
	att.statement.predicateType == "https://slsa.dev/provenance/v0.2"
	p := att.statement.predicate
	p.builder.id == "https://tekton.dev/chains/v2"
	p.buildType == "tekton.dev/v1/TaskRun"
	p.invocation.environment.labels["tekton.dev/pipeline"] == "parasol-portal-secure-build"
	p.invocation.environment.labels["tekton.dev/pipelineTask"] == "build-container"
}
