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

approval_dismissed(username, ts) := {"username": username, "timestamp": ts, "state": "DISMISSED"}

approval_changes_requested(username, ts) := {"username": username, "timestamp": ts, "state": "CHANGES_REQUESTED"}

approval_null_username(ts) := {"username": null, "timestamp": ts, "state": "APPROVED"}

approval_no_username(ts) := {"timestamp": ts, "state": "APPROVED"}

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

# Scenario 4 — commit message resembles a GitHub merge commit but no PR exists in attestation data.
# Merge-commit detection is purely data-driven (pr.merge_commit == trail.name), so the message is irrelevant.
test_fake_merge_message_no_pr_fails if {
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

# Scenario 15 — direct commit and a properly approved PR merge commit in the same release range.
# Only the direct commit produces a violation.
# SHAs are exactly 7 chars: violation messages use substring(trail.name, 0, 7).
test_direct_commit_and_pr_in_range_one_violation if {
	direct := make_trail("dc20001", "alice <alice@example.com>", [])
	pr := make_pr("mr62001", "alice",
		[pr_commit("sha_c3", "alice"), pr_commit("sha_c4", "alice")],
		[approval("bob", 1000001)])
	merged := make_trail("mr62001", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([direct, merged])
	count(v) == 1
	some msg in v
	contains(msg, "dc20001")
}

# ---------------------------------------------------------------------------
# Multiple PRs in release range
# ---------------------------------------------------------------------------

# Scenario 16 — two merge commits, each backed by a PR with an independent approver → PASS
test_two_prs_both_approved_passes if {
	pr_a := make_pr("mr63001", "sami",
		[pr_commit("sha_c2", "sami")],
		[approval("faye", 1000001)])
	pr_b := make_pr("mr64001", "faye",
		[pr_commit("sha_c3", "faye")],
		[approval("sami", 1000001)])
	trail_a := make_trail("mr63001", "sami <sami@example.com>", [pr_a])
	trail_b := make_trail("mr64001", "faye <faye@example.com>", [pr_b])
	count(violations) == 0 with input as make_input([trail_a, trail_b])
}

# Scenario 17 — two merge commits; first PR independently approved, second self-approved → one violation
test_two_prs_one_self_approved_fails if {
	pr_a := make_pr("mr65001", "sami",
		[pr_commit("sha_c2", "sami")],
		[approval("faye", 1000001)])
	pr_b := make_pr("mr66001", "faye",
		[pr_commit("sha_c3", "faye")],
		[approval("faye", 1000001)])
	trail_a := make_trail("mr65001", "sami <sami@example.com>", [pr_a])
	trail_b := make_trail("mr66001", "faye <faye@example.com>", [pr_b])
	v := violations with input as make_input([trail_a, trail_b])
	count(v) == 1
	some msg in v
	contains(msg, "mr66001")
}

# ---------------------------------------------------------------------------
# Approval state validation
# ---------------------------------------------------------------------------

# DISMISSED approval must not satisfy independent approval requirement
test_dismissed_approval_fails if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval_dismissed("bob", 1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail])
	some msg in v
	contains(msg, "independent approval")
}

# CHANGES_REQUESTED approval must not satisfy independent approval requirement
test_changes_requested_approval_fails if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval_changes_requested("bob", 1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail])
	some msg in v
	contains(msg, "independent approval")
}

# DISMISSED + APPROVED from independent reviewer: the APPROVED one still satisfies the check
test_dismissed_plus_approved_passes if {
	pr := make_pr("abc1234", "alice",
		[pr_commit("sha1", "alice")],
		[approval_dismissed("bob", 1000001), approval("carol", 1000002)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	count(violations) == 0 with input as make_input([trail])
}

# ---------------------------------------------------------------------------
# Approver username validation
# ---------------------------------------------------------------------------

# Approval with explicit null username must not be counted as independent approval
test_null_username_approver_fails if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval_null_username(1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail])
	some msg in v
	contains(msg, "independent approval")
}

# Approval with absent username field must not be counted as independent approval
test_absent_username_approver_fails if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval_no_username(1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail])
	some msg in v
	contains(msg, "independent approval")
}

# ---------------------------------------------------------------------------
# Input structure guard
# ---------------------------------------------------------------------------

# input.trails absent: policy must fail closed, not silently allow everything
test_missing_trails_key_fails_closed if {
	v := violations with input as {}
	some msg in v
	contains(msg, "input.trails is missing")
	not allow with input as {}
}

# input.trails is a non-array (e.g. typo, singular object): policy must fail closed
test_wrong_trails_type_fails_closed if {
	v := violations with input as {"trails": "not-an-array"}
	some msg in v
	contains(msg, "input.trails is missing")
	not allow with input as {"trails": "not-an-array"}
}
