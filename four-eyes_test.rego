package policy

import rego.v1

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

# One trail = one commit. The trail name is the commit SHA.
# author_str is "Name <email>" format, matching trail.git_commit_info.author.
make_trail(sha, author_str, prs) := {
	"name": sha,
	"git_commit_info": {"author": author_str, "sha1": sha, "timestamp": 1000100},
	"compliance_status": {"attestations_statuses": {"pr-review": {"pull_requests": prs}}},
}

make_input(trails) := {"trails": trails}

# pr_commit: a commit on the PR branch (Unix timestamps)
pr_commit(sha, username) := {
	"sha1": sha,
	"author_username": username,
	"timestamp": 1000000,
}

pr_commit_null_user(sha) := {
	"sha1": sha,
	"author_username": null,
	"timestamp": 1000000,
}

# pr_commit_no_user: author_username field absent (as Kosli sends for unresolvable identities)
pr_commit_no_user(sha) := {
	"sha1": sha,
	"timestamp": 1000000,
}

# pr_commit_web_flow: Copilot co-author or GitHub web-flow commit — no author_username, author is GitHub
pr_commit_web_flow(sha) := {
	"sha1": sha,
	"author": "GitHub <noreply@github.com>",
	"timestamp": 1000000,
}

# approval: an approver entry
approval(username, ts) := {"username": username, "timestamp": ts, "state": "APPROVED"}

# make_pr builds a PR object.
# merge_sha: SHA that equals trail.name when this is a merge commit trail.
# pr_author: GitHub username of the PR creator.
make_pr(merge_sha, pr_author, commits, approvers) := {
	"url": "https://github.com/owner/repo/pull/42",
	"merge_commit": merge_sha,
	"author": pr_author,
	"commits": commits,
	"approvers": approvers,
	"state": "MERGED",
}

# ---------------------------------------------------------------------------
# Missing attestation
# ---------------------------------------------------------------------------

# Scenario 0 — pr-review attestation absent from trail → violation fires
test_missing_attestation_fails if {
	v := violations with input as make_input([{
		"name": "abc1234",
		"git_commit_info": {"author": "alice <alice@example.com>", "sha1": "abc1234", "timestamp": 1000000},
		"compliance_status": {"attestations_statuses": {}},
	}])
	some msg in v
	contains(msg, "pr-review attestation is missing")
}

# ---------------------------------------------------------------------------
# Service account exemption
# ---------------------------------------------------------------------------

# svc_.* pattern — generic service account prefix
test_service_account_svc_prefix_passes if {
	trail := make_trail("abc1234", "svc_deployer <svc@kosli.com>", [])
	count(violations) == 0 with input as make_input([trail])
}

# dependabot[bot] — covered by .*\[bot\] pattern
test_service_account_dependabot_passes if {
	trail := make_trail("abc1234", "dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>", [])
	count(violations) == 0 with input as make_input([trail])
}

# github-actions[bot] — covered by .*\[bot\] pattern
test_service_account_github_actions_passes if {
	trail := make_trail("abc1234", "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>", [])
	count(violations) == 0 with input as make_input([trail])
}

# ci-signed-commit-bot[bot] — GitHub App that signs commits on behalf of humans
test_service_account_ci_signed_commit_bot_passes if {
	trail := make_trail("abc1234", "ci-signed-commit-bot[bot] <247774526+ci-signed-commit-bot[bot]@users.noreply.github.com>", [])
	count(violations) == 0 with input as make_input([trail])
}

# Regular user must not be treated as a service account
test_regular_user_not_exempt if {
	trail := make_trail("abc1234", "alice <alice@example.com>", [])
	v := violations with input as make_input([trail])
	some msg in v
	contains(msg, "no associated PR")
}

# ---------------------------------------------------------------------------
# Merge commit detection via pr.merge_commit == trail.name
# ---------------------------------------------------------------------------

# Scenario 3 — merge commit (merge_commit == trail.name), independent approval → PASS
test_merge_commit_passes if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha_alice", "alice")], [approval("bob", 1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	count(violations) == 0 with input as make_input([trail])
}

# Scenario 3 (no PR) — trail with no associated PR → violation
test_merge_commit_no_pr_fails if {
	trail := make_trail("abc1234", "alice <alice@example.com>", [])
	v := violations with input as make_input([trail])
	some msg in v
	contains(msg, "no associated PR")
}

# Non-merge commit (merge_commit != trail.name) — pr.author also counted in all_authors
test_non_merge_commit_pr_author_counted if {
	# trail SHA is "abc1234" but merge_commit is "def5678" → non-merge path
	# pr.author = "alice", pr commits by alice; bob must approve alice
	pr := make_pr("def5678", "alice", [pr_commit("sha_alice", "alice")], [approval("bob", 1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	count(violations) == 0 with input as make_input([trail])
}

# Non-merge commit self-approval: pr.author approves, but pr.author == pr commit author → fail
test_non_merge_commit_self_approval_fails if {
	pr := make_pr("def5678", "alice", [pr_commit("sha_alice", "alice")], [approval("alice", 1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail])
	some msg in v
	contains(msg, "independent approval")
}

# ---------------------------------------------------------------------------
# No associated PR
# ---------------------------------------------------------------------------

# Scenario 5 — commit with no PRs → violation
test_no_pr_fails if {
	trail := make_trail("abc1234", "alice <alice@example.com>", [])
	v := violations with input as make_input([trail])
	some msg in v
	contains(msg, "no associated PR")
}

# ---------------------------------------------------------------------------
# PR approval
# ---------------------------------------------------------------------------

# Scenario 1 — independent approval after latest commit → PASS
test_independent_approval_after_commit_passes if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval("bob", 1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	count(violations) == 0 with input as make_input([trail])
}

# Scenario 7 — self-approval only → violation
test_self_approval_fails if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval("alice", 1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail])
	some msg in v
	contains(msg, "independent approval")
}

# Scenario 8 — new code pushed after approval → violation
test_approval_before_latest_commit_fails if {
	late_commit := {"sha1": "sha_late", "author_username": "alice", "timestamp": 1000010}
	pr := make_pr("abc1234", "alice",
		[pr_commit("sha_early", "alice"), late_commit],
		[approval("bob", 1000005)], # approved at 1000005 but late commit is at 1000010
	)
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail])
	some msg in v
	contains(msg, "independent approval")
}

# Scenario 6 — PR exists but has no approvals → violation
test_no_approvals_fails if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail])
	some msg in v
	contains(msg, "independent approval")
}

# ---------------------------------------------------------------------------
# Multi-author PRs
# ---------------------------------------------------------------------------

# Scenario 13 — multi-author PR: sami and faye both commit, each approved by the other → PASS
test_multi_author_cross_approval_passes if {
	pr := make_pr("abc1234", "sami",
		[pr_commit("sha_sami", "sami"), pr_commit("sha_faye", "faye")],
		[approval("faye", 1000001), approval("sami", 1000002)],
	)
	trail := make_trail("abc1234", "sami <sami@example.com>", [pr])
	count(violations) == 0 with input as make_input([trail])
}

# Scenario 14 — faye approves but sami (co-author) still needs approval → violation
test_multi_author_only_one_committer_approves_fails if {
	pr := make_pr("abc1234", "sami",
		[pr_commit("sha_sami", "sami"), pr_commit("sha_faye", "faye")],
		[approval("faye", 1000001)], # faye approves but nobody approves faye's work
	)
	trail := make_trail("abc1234", "sami <sami@example.com>", [pr])
	v := violations with input as make_input([trail])
	some msg in v
	contains(msg, "independent approval")
}

# ---------------------------------------------------------------------------
# Null author_username / unresolvable identity
# ---------------------------------------------------------------------------

# PR commit author_username is null → "identity unverifiable" violation
test_null_username_pr_commit_unverifiable if {
	pr := make_pr("abc1234", "alice",
		[pr_commit_null_user("sha1")],
		[approval("bob", 1000001)],
	)
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail])
	some msg in v
	contains(msg, "identity unverifiable")
}

# Null username service account PR commit: service account trail → no identity violation
test_null_username_service_account_trail_exempt if {
	pr := make_pr("abc1234", "alice",
		[pr_commit_null_user("sha1")],
		[approval("bob", 1000001)],
	)
	trail := make_trail("abc1234", "svc_deployer <svc@kosli.com>", [pr])
	v := violations with input as make_input([trail])
	every msg in v {
		not contains(msg, "identity unverifiable")
	}
}

# All null author_usernames must not vacuously pass — identity violation fires
test_all_null_usernames_no_vacuous_pass if {
	pr := make_pr("abc1234", "alice",
		[pr_commit_null_user("sha1"), pr_commit_null_user("sha2")],
		[approval("bob", 1000001)],
	)
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail])
	some msg in v
	contains(msg, "identity unverifiable")
}

# Absent author_username field (as sent by Kosli when identity unresolvable) → "identity unverifiable"
test_absent_username_pr_commit_unverifiable if {
	pr := make_pr("abc1234", "alice",
		[pr_commit_no_user("sha1")],
		[approval("bob", 1000001)],
	)
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail])
	some msg in v
	contains(msg, "identity unverifiable")
}

# GitHub web-flow / Copilot co-author commit: author="GitHub <noreply@github.com>", no author_username → exempt
test_web_flow_pr_commit_exempt if {
	pr := make_pr("abc1234", "alice",
		[pr_commit("sha_alice", "alice"), pr_commit_web_flow("sha_copilot")],
		[approval("bob", 1000001)],
	)
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	count(violations) == 0 with input as make_input([trail])
}

# ---------------------------------------------------------------------------
# Multiple associated PRs (any passing PR is sufficient)
# ---------------------------------------------------------------------------

# Multi-PR — first PR has no approval, second does → PASS
test_second_pr_approval_satisfies_check if {
	pr_none := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [])
	pr_approved := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval("bob", 1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr_none, pr_approved])
	count(violations) == 0 with input as make_input([trail])
}

# Multi-PR — neither PR has approval → violation
test_no_pr_with_approval_fails if {
	pr_none := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr_none, pr_none])
	v := violations with input as make_input([trail])
	some msg in v
	contains(msg, "independent approval")
}

# ---------------------------------------------------------------------------
# Multiple commits across trails — only failing ones reported
# ---------------------------------------------------------------------------

# Scenario 11 — service account passes, regular commit without PR fails;
# exactly one violation referencing the failing SHA
test_only_failing_commits_reported if {
	passing := make_trail("aaa1111", "svc_bot <svc@kosli.com>", [])
	failing := make_trail("bbb2222", "alice <alice@example.com>", [])
	v := violations with input as make_input([passing, failing])
	count(v) == 1
	some msg in v
	contains(msg, "bbb2222")
}
