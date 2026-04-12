package policy

import rego.v1

default allow = false

allow if count(violations) == 0

# ---------------------------------------------------------------------------
# Attestation data
#
# Generic attestation user_data is available at:
#   input.trail.compliance_status.attestations_statuses[<name>].user_data
#
# Verify the exact path in your environment with:
#   kosli evaluate trail <trail> --policy four-eyes.rego --show-input --output json
# ---------------------------------------------------------------------------
attestation := input.trail.compliance_status.attestations_statuses["scr-data"].user_data

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

pr_commit_shas(pr) := {c.sha | some c in pr.commits}

# Logins of every PR branch commit author whose identity could be resolved.
pr_commit_authors(pr) := {login |
	some c in pr.commits
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
	filtered := [c | some c in pr.commits; not is_merge_from_base(c, pr)]
	count(filtered) > 0
}

relevant_pr_commits(pr) := pr.commits if {
	post_approval_merge_commits == "strict"
}

# Fallback: if every commit in the PR is a merge-from-base, use them all.
relevant_pr_commits(pr) := pr.commits if {
	post_approval_merge_commits == "ignore"
	filtered := [c | some c in pr.commits; not is_merge_from_base(c, pr)]
	count(filtered) == 0
}

latest_relevant_commit_ns(pr) := max(
	{time.parse_rfc3339_ns(c.date) | some c in relevant_pr_commits(pr)},
)

has_independent_approval(commit, pr) if {
	cutoff := latest_relevant_commit_ns(pr)
	# Union of PR branch commit authors and the main-branch commit author.
	# Null logins are excluded — unresolvable identities are not checked.
	all_authors := (pr_commit_authors(pr) | {commit.author.login}) - {null}
	every author_login in all_authors {
		some approval in pr.approvals
		approval.user.login != author_login
		time.parse_rfc3339_ns(approval.approved_at) > cutoff
	}
}

# ---------------------------------------------------------------------------
# Exemption checks (rules read from the attested config)
# ---------------------------------------------------------------------------

is_service_account(commit) if {
	some pattern in attestation.config.exemptions.serviceAccounts
	regex.match(pattern, commit.author.git_name)
}

is_service_account(commit) if {
	some pattern in attestation.config.exemptions.serviceAccounts
	regex.match(pattern, commit.author.login)
}

is_exempt_file(file) if {
	some exempt_path in attestation.config.exemptions.filePaths
	file == exempt_path
}

is_exempt_file(file) if {
	parts := split(file, "/")
	basename := parts[count(parts) - 1]
	some name in attestation.config.exemptions.fileNames
	basename == name
}

all_files_exempt(commit) if {
	count(commit.changed_files) > 0
	every file in commit.changed_files {
		is_exempt_file(file)
	}
}

is_merge_commit(commit) if {
	count(commit.parent_shas) > 1
}

is_merge_commit(commit) if {
	startswith(commit.message, "Merge pull request #")
}

# ---------------------------------------------------------------------------
# Helpers — multi-PR support
# ---------------------------------------------------------------------------

has_any_pr_approval(commit) if {
	some pr_num in commit.pr_numbers
	pr := attestation.pull_requests[sprintf("%d", [pr_num])]
	has_independent_approval(commit, pr)
}

# ---------------------------------------------------------------------------
# Violations
# ---------------------------------------------------------------------------

violations contains msg if {
	some commit in attestation.commits
	not is_service_account(commit)
	not all_files_exempt(commit)
	not is_merge_commit(commit)
	count(commit.pr_numbers) == 0
	msg := sprintf(
		"Commit %v (%v): no associated PR found",
		[substring(commit.sha, 0, 7), commit.message],
	)
}

violations contains msg if {
	some commit in attestation.commits
	not is_service_account(commit)
	not all_files_exempt(commit)
	not is_merge_commit(commit)
	count(commit.pr_numbers) > 0
	not has_any_pr_approval(commit)
	msg := sprintf(
		"Commit %v (%v): none of PRs %v have an independent approval after latest code commit",
		[substring(commit.sha, 0, 7), commit.message, commit.pr_numbers],
	)
}
