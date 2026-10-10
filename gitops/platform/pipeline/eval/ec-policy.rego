# Conforma / Enterprise Contract policy for the Parasol portal lifecycle gate.
# The cryptographic gate is EC's built-in verification: the image must carry a valid cosign
# signature AND a signed in-toto attestation from the cluster key (both produced by Tekton Chains)
# and the image must be accessible. This rego adds one release rule: the image must be pinned by
# digest. A correctly signed-and-attested, digest-pinned image passes; an unsigned/unattested or
# tag-only image fails EC before it can be promoted.
package release.parasol

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
