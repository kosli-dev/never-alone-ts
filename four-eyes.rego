package policy

import rego.v1

default allow = false

allow if count(violations) == 0

# ---------------------------------------------------------------------------
# Attestation data
#
# Used with `kosli evaluate trails` (plural). Each trail in input.trails
# represents one commit. The PR attestation payload is at:
#   trail.compliance_status.attestations_statuses["pr-review"]
#
# Attested via: kosli attest pullrequest github --name pr-review --commit <sha>
# ---------------------------------------------------------------------------
pr_attest(trail) := trail.compliance_status.attestations_statuses["pr-review"]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# GitHub usernames of all PR branch commit authors whose identity was resolved.
pr_commit_authors(pr) := {u |
	some c in pr.commits
	u := c.author_username
	u != null
}

# Latest Unix timestamp among PR branch commits.
latest_commit_ts(pr) := max({c.timestamp | some c in pr.commits})

# A commit is the merge commit when the PR's merge_commit field matches the
# trail name (which is the commit SHA). Covers squash, regular, and rebase merges.
is_merge_commit(trail, pr) if {
	trail.name == pr.merge_commit
}

# Regular commit: PR branch authors + PR author all need independent approval.
has_independent_approval(trail, pr) if {
	not is_merge_commit(trail, pr)
	cutoff := latest_commit_ts(pr)
	all_authors := pr_commit_authors(pr) | {pr.author}
	count(all_authors) > 0
	every author in all_authors {
		some approver in pr.approvers
		approver.username != author
		approver.timestamp > cutoff
	}
}

# Merge commit: only PR branch commit authors need independent approval.
# The person who clicked Merge did not write code and needs no separate review.
has_independent_approval(trail, pr) if {
	is_merge_commit(trail, pr)
	cutoff := latest_commit_ts(pr)
	all_authors := pr_commit_authors(pr)
	count(all_authors) > 0
	every author in all_authors {
		some approver in pr.approvers
		approver.username != author
		approver.timestamp > cutoff
	}
}

# ---------------------------------------------------------------------------
# Service account exemption
#
# Matched against trail.git_commit_info.author, which is "Name <email>" format.
# Patterns work against the full string, e.g.:
#   "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>"
# ---------------------------------------------------------------------------

service_account_patterns := {
	"svc_.*",
	".*\\[bot\\]",
	"noreply@github.com"
}

is_service_account(trail) if {
	some pattern in service_account_patterns
	regex.match(pattern, trail.git_commit_info.author)
}

# PR commits created by web-flow or Copilot co-authorship use the GitHub service
# identity and have no resolvable GitHub user account.
is_web_flow_commit(c) if {
	some pattern in service_account_patterns
	regex.match(pattern, object.get(c, "author", ""))
}

# ---------------------------------------------------------------------------
# Helpers — multi-PR support
# ---------------------------------------------------------------------------

has_any_pr_approval(trail, attest) if {
	some pr in attest.pull_requests
	has_independent_approval(trail, pr)
}

# ---------------------------------------------------------------------------
# Violations — iterate over all trails
# ---------------------------------------------------------------------------

violations contains msg if {
	some trail in input.trails
	not trail.compliance_status.attestations_statuses["pr-review"]
	msg := sprintf("Trail %v: pr-review attestation is missing", [trail.name])
}

violations contains msg if {
	some trail in input.trails
	attest := pr_attest(trail)
	some pr in attest.pull_requests
	some c in pr.commits
	object.get(c, "author_username", null) == null
	not is_service_account(trail)
	not is_web_flow_commit(c)
	msg := sprintf(
		"PR %v: commit %v has no linked GitHub account — identity unverifiable",
		[pr.url, substring(c.sha1, 0, 7)],
	)
}

violations contains msg if {
	some trail in input.trails
	not is_service_account(trail)
	attest := pr_attest(trail)
	count(attest.pull_requests) == 0
	msg := sprintf(
		"Commit %v: no associated PR found",
		[substring(trail.name, 0, 7)],
	)
}

violations contains msg if {
	some trail in input.trails
	not is_service_account(trail)
	attest := pr_attest(trail)
	count(attest.pull_requests) > 0
	not has_any_pr_approval(trail, attest)
	msg := sprintf(
		"Commit %v: no independent approval after latest code commit",
		[substring(trail.name, 0, 7)],
	)
}
