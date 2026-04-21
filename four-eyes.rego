package policy

import rego.v1

default allow = false

allow if count(violations) == 0

# ---------------------------------------------------------------------------
# Attestation data
#
# Used with `kosli evaluate trails` (plural). Each trail in input.trails
# represents one commit. The per-commit attestation payload is at:
#   trail.compliance_status.attestations_statuses["scr-data"].user_data
#
# (Generic attestations use .user_data; custom attestations use .attestation_data)
#
# Verify the exact path in your environment with:
#   kosli evaluate trails <sha1> <sha2> ... --policy four-eyes.rego \
#     --show-input --output json
# ---------------------------------------------------------------------------
trail_data(trail) := trail.compliance_status.attestations_statuses["scr-data"].attestation_data

# ---------------------------------------------------------------------------
# Behaviour: post-approval merge-from-base commits
#
# "ignore" — exclude merge-from-base commits (multi-parent commits where at
#            least one parent originates outside the PR) when checking whether
#            an approval post-dates all code changes. Such commits only bring
#            in content already reviewed on the base branch.
#
# "strict" — any commit pushed after the last approval causes a failure,
#            including merge-from-base commits.
# ---------------------------------------------------------------------------
post_approval_merge_commits := "strict"  # "ignore" or "strict"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pr_commit_shas(pr) := {c.sha | some c in pr.pr_commits}

# Logins of every PR branch commit author whose identity could be resolved.
pr_commit_authors(pr) := {login |
	some c in pr.pr_commits
	login := c.author.login
	login != null
}

is_merge_from_base(commit, pr) if {
	count(commit.parent_shas) > 1
	some parent in commit.parent_shas
	not pr_commit_shas(pr)[parent]
}

relevant_pr_commits(pr) := filtered if {
	post_approval_merge_commits == "ignore"
	filtered := [c | some c in pr.pr_commits; not is_merge_from_base(c, pr)]
	count(filtered) > 0
}

relevant_pr_commits(pr) := pr.pr_commits if {
	post_approval_merge_commits == "strict"
}

# Fallback: if every commit in the PR is a merge-from-base, use them all.
relevant_pr_commits(pr) := pr.pr_commits if {
	post_approval_merge_commits == "ignore"
	filtered := [c | some c in pr.pr_commits; not is_merge_from_base(c, pr)]
	count(filtered) == 0
}

latest_relevant_commit_ns(pr) := max(
	{time.parse_rfc3339_ns(c.date) | some c in relevant_pr_commits(pr)},
)

# Regular commits: PR branch authors + this commit's own author must all have independent approval.
has_independent_approval(commit, pr) if {
	not is_merge_commit(commit)
	cutoff := latest_relevant_commit_ns(pr)
	all_authors := (pr_commit_authors(pr) | {commit.author.login}) - {null}
	count(all_authors) > 0
	every author_login in all_authors {
		some approval in pr.approvals
		approval.user.login != author_login
		time.parse_rfc3339_ns(approval.approved_at) > cutoff
	}
}

# Merge commits: only PR branch authors matter — the merger clicked a button, not code.
# Including the merger's login would cause false positives when a reviewer merges the PR.
has_independent_approval(commit, pr) if {
	is_merge_commit(commit)
	cutoff := latest_relevant_commit_ns(pr)
	all_authors := pr_commit_authors(pr) - {null}
	count(all_authors) > 0
	every author_login in all_authors {
		some approval in pr.approvals
		approval.user.login != author_login
		time.parse_rfc3339_ns(approval.approved_at) > cutoff
	}
}

# ---------------------------------------------------------------------------
# Service account exemption
# ---------------------------------------------------------------------------

is_service_account(commit, attestation) if {
	some pattern in attestation.config.exemptions.serviceAccounts
	regex.match(pattern, commit.author.git_name)
}

is_service_account(commit, attestation) if {
	some pattern in attestation.config.exemptions.serviceAccounts
	regex.match(pattern, commit.author.login)
}

is_merge_commit(commit) if {
	count(commit.parent_shas) > 1
}

# ---------------------------------------------------------------------------
# Helpers — multi-PR support
# ---------------------------------------------------------------------------

has_any_pr_approval(commit, attestation) if {
	some pr in attestation.pull_requests
	has_independent_approval(commit, pr)
}

# ---------------------------------------------------------------------------
# Violations — iterate over all trails
# ---------------------------------------------------------------------------

violations contains msg if {
	some trail in input.trails
	not trail.compliance_status.attestations_statuses["scr-data"]
	msg := sprintf("Trail %v: scr-data attestation is missing", [trail.name])
}

violations contains msg if {
	some trail in input.trails
	attestation := trail_data(trail)
	some pr in attestation.pull_requests
	some c in pr.pr_commits
	c.author.login == null
	not is_service_account(c, attestation)
	msg := sprintf(
		"PR #%v: commit %v author '%v <%v>' has no linked GitHub account — identity unverifiable",
		[pr.number, substring(c.sha, 0, 7), c.author.git_name, c.author.git_email],
	)
}

violations contains msg if {
	some trail in input.trails
	attestation := trail_data(trail)
	commit := attestation.commit
	not is_service_account(commit, attestation)
	count(attestation.pull_requests) == 0
	msg := sprintf(
		"Commit %v (%v): no associated PR found",
		[substring(commit.sha, 0, 7), commit.message],
	)
}

violations contains msg if {
	some trail in input.trails
	attestation := trail_data(trail)
	commit := attestation.commit
	not is_service_account(commit, attestation)
	count(attestation.pull_requests) > 0
	not has_any_pr_approval(commit, attestation)
	msg := sprintf(
		"Commit %v (%v): no independent approval after latest code commit",
		[substring(commit.sha, 0, 7), commit.message],
	)
}
