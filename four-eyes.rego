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
# Compliance
# ---------------------------------------------------------------------------

# A commit is compliant when an associated PR in the evaluated repository has
# independent approval, on the PR's final commit, covering every author. There
# is no exemption based on the git author string: whoever writes the commit
# sets it, so matching on it would let anyone skip review.
trail_compliant(trail) if {
	attest := pr_attest(trail)
	some pr in attest.pull_requests
	pr_in_repo(pr)
	all_commits_listed(pr)
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

# GitHub usernames on PR branch commits: each named author, signing account and co-author.
pr_commit_authors(pr) := {u |
	some c in pr.commits
	some u in [object.get(c, "author_username", null), object.get(c, "signer_username", null)]
	is_resolved_username(u)
} | {u |
	some c in pr.commits
	some u in object.get(c, "co_author_usernames", [])
	is_resolved_username(u)
}

# The approval was given on the PR's final commit. Commit dates are not used:
# whoever writes a commit sets them.
approved_on_head(approver, pr) if {
	is_string(pr.head_sha)
	pr.head_sha != ""
	approver.commit_sha == pr.head_sha
}

# Approvals that count: by a person with write access, on the PR's final commit,
# and not withdrawn. Review times are set by GitHub.
counting_approvals(pr) := {a |
	some a in pr.reviews
	a.state == "APPROVED"
	a.author_type == "user"
	a.has_write_access == true
	is_resolved_username(a.username)
	is_number(a.timestamp)
	approved_on_head(a, pr)
	given_before_merge(a, pr)
	not withdrawn(a, pr)
}

# The same reviewer requested changes or had a review dismissed at the same
# time or later. A review with no usable time counts as later.
withdrawn(approval, pr) if {
	some r in pr.reviews
	r.username == approval.username
	r.state in {"CHANGES_REQUESTED", "DISMISSED"}
	not earlier(r, approval)
}

# An approval after merge means the code reached main unreviewed.
given_before_merge(approval, pr) if {
	is_number(pr.merged_at)
	approval.timestamp <= pr.merged_at
}

earlier(r, approval) if {
	is_number(r.timestamp)
	r.timestamp < approval.timestamp
}

# The PR URL is https://<host>/<owner>/<repo>/pull/<number>.
pr_in_repo(pr) if {
	parts := split(pr.url, "/")
	count(parts) == 7
	parts[5] == "pull"
	lower(concat("/", [parts[3], parts[4]])) == repository
}

# The PR lists every commit GitHub counts. GitHub returns at most 250, so on a
# longer PR the oldest commits' authors would go unchecked.
all_commits_listed(pr) if {
	count(pr.commits) == pr.commit_count
}

# Every commit on the PR has an author linked to a GitHub account and a
# verified signature, by a known account or by GitHub. Without the signature
# the author is only what the commit says, which its writer chooses.
all_authors_resolved(pr) if {
	every c in pr.commits {
		every u in object.get(c, "co_author_usernames", []) {
			is_resolved_username(u)
		}
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
	c.signed_by_platform == true
}

# A commit is the merge commit when the PR's merge_commit field matches the
# trail name (which is the commit SHA). Covers squash, regular, and rebase merges.
is_merge_commit(trail, pr) if {
	trail.name == pr.merge_commit
}

# Regular commit: PR branch authors + PR author all need independent approval on the final commit.
has_independent_approval(trail, pr) if {
	not is_merge_commit(trail, pr)
	is_resolved_username(pr.author)
	all_authors := pr_commit_authors(pr) | {pr.author}
	count(all_authors) > 0

	# At least one approver must exist to satisfy four-eyes.
	count(counting_approvals(pr)) > 0
	every author in all_authors {
		some approver in counting_approvals(pr)
		approver.username != author
	}
}

# Merge commit: only PR branch commit authors need independent approval.
# The merge button clicker did not write code and requires no separate review.
has_independent_approval(trail, pr) if {
	is_merge_commit(trail, pr)
	all_authors := pr_commit_authors(pr)
	count(all_authors) > 0

	# At least one approver must exist to satisfy four-eyes.
	count(counting_approvals(pr)) > 0
	every author in all_authors {
		some approver in counting_approvals(pr)
		approver.username != author
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

# Unlisted commits: the PR lists a different number of commits than GitHub counts.
violations contains msg if {
	some trail in input.trails
	not trail_compliant(trail)
	attest := pr_attest(trail)
	some pr in attest.pull_requests
	is_number(pr.commit_count)
	not all_commits_listed(pr)
	msg := sprintf(
		"PR %v: lists %v commits but GitHub counts %v. Some authors can't be checked",
		[pr.url, count(pr.commits), pr.commit_count],
	)
}

violations contains msg if {
	some trail in input.trails
	not trail_compliant(trail)
	attest := pr_attest(trail)
	some pr in attest.pull_requests
	not is_number(object.get(pr, "commit_count", null))
	msg := sprintf("PR %v: no commit count recorded. Re-attest with a current Kosli CLI", [pr.url])
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
		"Commit %v: no PR in %v has an independent approval on its final commit before merge",
		[substring(trail.name, 0, 7), repository],
	)
}

# True if any associated PR has both resolved authors and independent approval.
# Used only for violation messaging to distinguish "missing approval" from
# "unverifiable identity".
any_pr_fully_approved(trail, attest) if {
	some pr in attest.pull_requests
	pr_in_repo(pr)
	all_commits_listed(pr)
	all_authors_resolved(pr)
	has_independent_approval(trail, pr)
}