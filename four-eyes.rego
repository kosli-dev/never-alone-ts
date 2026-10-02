package policy

import rego.v1

# Four-eyes principle enforcement: every commit must have independent review.
# This policy evaluates per-commit attestation data from Kosli.
#
# Positive-assertion model: allow is true only when input.trails is a non-empty
# array AND every trail explicitly satisfies trail_compliant. Any failure to
# evaluate (malformed input, helper bug, missing field) leaves trails outside
# the compliant set and allow stays false. There is no defensive guard rule
# because the structure is fail-closed by construction.
default allow := false

allow if {
	is_array(input.trails)
	count(input.trails) > 0
	every trail in input.trails {
		trail_compliant(trail)
	}
}

# ---------------------------------------------------------------------------
# Compliance — a trail is compliant if any of these positive conditions hold
# ---------------------------------------------------------------------------

# A commit is compliant when an associated PR in the evaluated repository has
# independent approval, on the PR's final commit, covering every author. There
# is no exemption based on the git author string: whoever writes the commit
# sets it, so matching on it would let anyone skip review.
trail_compliant(trail) if {
	attest := pr_attest(trail)
	some pr in attest.pull_requests
	pr_in_repo(pr)
	all_authors_resolved(pr)
	has_independent_approval(trail, pr)
}

# ---------------------------------------------------------------------------
# Attestation data
#
# Used with `kosli evaluate trails` (plural). Each trail in input.trails
# represents one commit. The PR attestation payload is found by type, not by
# name, so any attestation with attestation_type == "pull_request" qualifies.
#
# Attested via: kosli attest pullrequest github --name <name> --commit <sha>
# ---------------------------------------------------------------------------

# Extract PR attestation payload from a trail by type.
pr_attest(trail) := attest if {
	some _, attest in trail.compliance_status.attestations_statuses
	attest.attestation_type == "pull_request"
}

# The repository whose PRs count, as "owner/repo". Required: a PR elsewhere,
# such as in a fork, is one whose approvers the author may choose.
repository := lower(data.params.repository) if is_string(data.params.repository)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# A username is resolved when it is a non-empty GitHub login. "ghost" is the
# placeholder GitHub shows for deleted accounts, so it identifies no one.
is_resolved_username(u) if {
	is_string(u)
	u != ""
	u != "ghost"
}

# GitHub usernames of everyone who wrote PR branch commits: the named author,
# and the signer, who is who actually made the commit.
pr_commit_authors(pr) := {u |
	some c in pr.commits
	some u in [object.get(c, "author_username", null), object.get(c, "signer_username", null)]
	is_resolved_username(u)
}

# The approval was given on the PR's final commit. Commit dates are not used:
# whoever writes a commit sets them.
approved_on_head(approver, pr) if {
	is_string(pr.head_sha)
	pr.head_sha != ""
	approver.commit_sha == pr.head_sha
}

# The PR URL is https://<host>/<owner>/<repo>/pull/<number>.
pr_in_repo(pr) if {
	parts := split(pr.url, "/")
	count(parts) == 7
	parts[5] == "pull"
	lower(concat("/", [parts[3], parts[4]])) == repository
}

# Every commit on the PR has an author linked to a GitHub account and a
# verified signature, by a known account or by GitHub. Without the signature
# the author is only what the commit says, which its writer chooses.
all_authors_resolved(pr) if {
	every c in pr.commits {
		is_resolved_username(object.get(c, "author_username", null))
		signed_by_known_identity(c)
	}
}

signed_by_known_identity(c) if {
	c.verified == true
	is_resolved_username(object.get(c, "signer_username", null))
}

signed_by_known_identity(c) if {
	c.verified == true
	c.signed_by_github == true
}

# A commit is the merge commit when the PR's merge_commit field matches the
# trail name (which is the commit SHA). Covers squash, regular, and rebase merges.
is_merge_commit(trail, pr) if {
	trail.name == pr.merge_commit
}

# Regular commit: PR branch authors + PR author all need independent approval on the final commit.
has_independent_approval(trail, pr) if {
	not is_merge_commit(trail, pr)
	all_authors := pr_commit_authors(pr) | {pr.author}
	count(all_authors) > 0

	# At least one approver must exist to satisfy four-eyes.
	count(pr.approvers) > 0
	every author in all_authors {
		some approver in pr.approvers
		approver.state == "APPROVED"
		is_resolved_username(approver.username)
		approver.username != author
		approved_on_head(approver, pr)
	}
}

# Merge commit: only PR branch commit authors need independent approval.
# The merge button clicker did not write code and requires no separate review.
has_independent_approval(trail, pr) if {
	is_merge_commit(trail, pr)
	all_authors := pr_commit_authors(pr)
	count(all_authors) > 0

	# At least one approver must exist to satisfy four-eyes.
	count(pr.approvers) > 0
	every author in all_authors {
		some approver in pr.approvers
		approver.state == "APPROVED"
		is_resolved_username(approver.username)
		approver.username != author
		approved_on_head(approver, pr)
	}
}

# ---------------------------------------------------------------------------
# Violations — human-readable diagnostic output
#
# These are derived for debugging and reporting only. allow does NOT depend
# on this set: a sprintf failure here cannot affect the compliance decision.
# A trail appears in violations if and only if it is not in trail_compliant.
# ---------------------------------------------------------------------------

violations contains "Policy error: input.trails is missing or not an array — cannot evaluate" if {
	not is_array(object.get(input, "trails", null))
}

violations contains "Policy error: input.trails is empty — nothing to evaluate" if {
	is_array(input.trails)
	count(input.trails) == 0
}

violations contains "Policy error: data.params.repository is not set. Pass --params '{\"repository\": \"owner/repo\"}'" if {
	not repository
}

# Missing attestation: no PR review data collected for this commit.
violations contains msg if {
	some trail in input.trails
	not trail_compliant(trail)
	not pr_attest(trail)
	msg := sprintf("Trail %v: pull_request attestation is missing", [trail.name])
}

# Unverifiable identity: commit author has no resolvable GitHub account.
violations contains msg if {
	some trail in input.trails
	not trail_compliant(trail)
	attest := pr_attest(trail)
	some pr in attest.pull_requests
	some c in pr.commits
	not is_resolved_username(object.get(c, "author_username", null))
	msg := sprintf(
		"PR %v: commit %v has no linked GitHub account — identity unverifiable",
		[pr.url, substring(c.sha1, 0, 7)],
	)
}

# Unverifiable signer: commit has no verified signature by a known account or GitHub.
violations contains msg if {
	some trail in input.trails
	not trail_compliant(trail)
	attest := pr_attest(trail)
	some pr in attest.pull_requests
	some c in pr.commits
	not signed_by_known_identity(c)
	msg := sprintf(
		"PR %v: commit %v has no verified signature. Who made it is unverifiable",
		[pr.url, substring(c.sha1, 0, 7)],
	)
}

# Missing PR: commit has no associated merged PR.
violations contains msg if {
	some trail in input.trails
	not trail_compliant(trail)
	attest := pr_attest(trail)
	count(attest.pull_requests) == 0
	msg := sprintf("Commit %v: no associated PR found", [substring(trail.name, 0, 7)])
}

# Missing approval: commit has an associated PR but no PR satisfies the
# independent-approval requirement.
violations contains msg if {
	some trail in input.trails
	not trail_compliant(trail)
	attest := pr_attest(trail)
	count(attest.pull_requests) > 0
	not any_pr_fully_approved(trail, attest)
	msg := sprintf(
		"Commit %v: no PR in %v has an independent approval on its final commit",
		[substring(trail.name, 0, 7), repository],
	)
}

# True if any associated PR has both resolved authors and independent approval.
# Used only for violation messaging to distinguish "missing approval" from
# "unverifiable identity".
any_pr_fully_approved(trail, attest) if {
	some pr in attest.pull_requests
	pr_in_repo(pr)
	all_authors_resolved(pr)
	has_independent_approval(trail, pr)
}