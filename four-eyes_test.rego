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
	"compliance_status": {"attestations_statuses": {"pr-review": {"attestation_type": "pull_request", "pull_requests": prs}}},
}

make_input(trails) := {"trails": trails}

# The repository the fixture PRs are in, passed as the policy requires.
params := {"repository": "owner/repo"}

# Every fixture PR's final commit, and the commit approval() is given on.
head := "sha_head"

# pr_commit: a commit on the PR branch, written and signed by username
pr_commit(sha, username) := signed_commit(sha, username, username)

# signed_commit: names author, with a verified signature by signer
signed_commit(sha, author, signer) := {
	"sha1": sha,
	"author_username": author,
	"timestamp": 1000000,
	"verified": true,
	"signer_username": signer,
	"signed_by_github": false,
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

# pr_commit_web_flow: a Copilot co-author entry, with no author_username and author set to GitHub
pr_commit_web_flow(sha) := {
	"sha1": sha,
	"author": "GitHub <noreply@github.com>",
	"timestamp": 1000000,
}

# approval: an approver entry, given on the PR's final commit
approval(username, ts) := approval_on(username, ts, head)

approval_on(username, ts, sha) := {"username": username, "timestamp": ts, "state": "APPROVED", "commit_sha": sha}

approval_dismissed(username, ts) := object.union(approval(username, ts), {"state": "DISMISSED"})

approval_changes_requested(username, ts) := object.union(approval(username, ts), {"state": "CHANGES_REQUESTED"})

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
	"head_sha": head,
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
	}]) with data.params as params
	some msg in v
	contains(msg, "pull_request attestation is missing")
}

# ---------------------------------------------------------------------------
# No author-name exemption
# ---------------------------------------------------------------------------

# A bot-like or service-account author name is set by whoever writes the commit,
# so it earns no exemption: with no PR, these trails fail like any other.
bot_like_authors := [
	"svc_deployer <svc@kosli.com>",
	"dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>",
	"github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>",
	"ci-signed-commit-bot[bot] <247774526+ci-signed-commit-bot[bot]@users.noreply.github.com>",
]

test_bot_like_author_without_pr_fails if {
	every author in bot_like_authors {
		inp := make_input([make_trail("abc1234", author, [])])
		not allow with input as inp with data.params as params
		v := violations with input as inp with data.params as params
		some msg in v
		contains(msg, "no associated PR")
	}
}

# A bot whose commits GitHub links to its account is reviewed like anyone else.
test_bot_commit_linked_to_account_with_human_approval_passes if {
	pr := make_pr("abc1234", "dependabot[bot]", [pr_commit("sha1", "dependabot[bot]")], [approval("bob", 1000001)])
	trail := make_trail("abc1234", "dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>", [pr])
	allow with input as make_input([trail]) with data.params as params
}

# A commit with no PR fails
test_regular_user_not_exempt if {
	trail := make_trail("abc1234", "alice <alice@example.com>", [])
	v := violations with input as make_input([trail]) with data.params as params
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
	count(violations) == 0 with input as make_input([trail]) with data.params as params
}

# Scenario 3 (no PR) — trail with no associated PR → violation
test_merge_commit_no_pr_fails if {
	trail := make_trail("abc1234", "alice <alice@example.com>", [])
	v := violations with input as make_input([trail]) with data.params as params
	some msg in v
	contains(msg, "no associated PR")
}

# Non-merge commit (merge_commit != trail.name) — pr.author also counted in all_authors
test_non_merge_commit_pr_author_counted if {
	# trail SHA is "abc1234" but merge_commit is "def5678" → non-merge path
	# pr.author = "alice", pr commits by alice; bob must approve alice
	pr := make_pr("def5678", "alice", [pr_commit("sha_alice", "alice")], [approval("bob", 1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	count(violations) == 0 with input as make_input([trail]) with data.params as params
}

# Non-merge commit self-approval: pr.author approves, but pr.author == pr commit author → fail
test_non_merge_commit_self_approval_fails if {
	pr := make_pr("def5678", "alice", [pr_commit("sha_alice", "alice")], [approval("alice", 1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail]) with data.params as params
	some msg in v
	contains(msg, "independent approval")
}

# ---------------------------------------------------------------------------
# No associated PR
# ---------------------------------------------------------------------------

# Scenario 5 — commit with no PRs → violation
test_no_pr_fails if {
	trail := make_trail("abc1234", "alice <alice@example.com>", [])
	v := violations with input as make_input([trail]) with data.params as params
	some msg in v
	contains(msg, "no associated PR")
}

# Scenario 4 — commit message resembles a GitHub merge commit but no PR exists in attestation data.
# Merge-commit detection is purely data-driven (pr.merge_commit == trail.name), so the message is irrelevant.
test_fake_merge_message_no_pr_fails if {
	trail := make_trail("abc1234", "alice <alice@example.com>", [])
	v := violations with input as make_input([trail]) with data.params as params
	some msg in v
	contains(msg, "no associated PR")
}

# ---------------------------------------------------------------------------
# PR approval
# ---------------------------------------------------------------------------

# Scenario 1: independent approval on the final commit → PASS
test_independent_approval_after_commit_passes if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval("bob", 1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	count(violations) == 0 with input as make_input([trail]) with data.params as params
}

# Scenario 7 — self-approval only → violation
test_self_approval_fails if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval("alice", 1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail]) with data.params as params
	some msg in v
	contains(msg, "independent approval")
}

# Scenario 8 — new code pushed after approval → violation
test_approval_before_latest_commit_fails if {
	late_commit := object.union(pr_commit(head, "alice"), {"timestamp": 1000010})
	pr := make_pr("abc1234", "alice",
		[pr_commit("sha_early", "alice"), late_commit],
		[approval_on("bob", 1000005, "sha_early")], # approved before the final commit was pushed
	)
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail]) with data.params as params
	some msg in v
	contains(msg, "independent approval")
}

# Scenario 6 — PR exists but has no approvals → violation
test_no_approvals_fails if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail]) with data.params as params
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
	count(violations) == 0 with input as make_input([trail]) with data.params as params
}

# Scenario 14 — faye approves but sami (co-author) still needs approval → violation
test_multi_author_only_one_committer_approves_fails if {
	pr := make_pr("abc1234", "sami",
		[pr_commit("sha_sami", "sami"), pr_commit("sha_faye", "faye")],
		[approval("faye", 1000001)], # faye approves but nobody approves faye's work
	)
	trail := make_trail("abc1234", "sami <sami@example.com>", [pr])
	v := violations with input as make_input([trail]) with data.params as params
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
	v := violations with input as make_input([trail]) with data.params as params
	some msg in v
	contains(msg, "identity unverifiable")
}

# A service-account trail author does not excuse an unresolved PR commit author
test_null_username_service_account_trail_not_exempt if {
	pr := make_pr("abc1234", "alice",
		[pr_commit_null_user("sha1")],
		[approval("bob", 1000001)],
	)
	trail := make_trail("abc1234", "svc_deployer <svc@kosli.com>", [pr])
	not allow with input as make_input([trail]) with data.params as params
	v := violations with input as make_input([trail]) with data.params as params
	some msg in v
	contains(msg, "identity unverifiable")
}

# All null author_usernames must not vacuously pass — identity violation fires
test_all_null_usernames_no_vacuous_pass if {
	pr := make_pr("abc1234", "alice",
		[pr_commit_null_user("sha1"), pr_commit_null_user("sha2")],
		[approval("bob", 1000001)],
	)
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail]) with data.params as params
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
	v := violations with input as make_input([trail]) with data.params as params
	some msg in v
	contains(msg, "identity unverifiable")
}

# A PR commit authored as "GitHub <noreply@github.com>" with no linked account is
# not exempt: the author string is set by whoever writes the commit.
test_web_flow_pr_commit_not_exempt if {
	pr := make_pr("abc1234", "alice",
		[pr_commit("sha_alice", "alice"), pr_commit_web_flow("sha_copilot")],
		[approval("bob", 1000001)],
	)
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	not allow with input as make_input([trail]) with data.params as params
	v := violations with input as make_input([trail]) with data.params as params
	some msg in v
	contains(msg, "identity unverifiable")
}

# ---------------------------------------------------------------------------
# Multiple associated PRs (any passing PR is sufficient)
# ---------------------------------------------------------------------------

# Multi-PR — first PR has no approval, second does → PASS
test_second_pr_approval_satisfies_check if {
	pr_none := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [])
	pr_approved := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval("bob", 1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr_none, pr_approved])
	count(violations) == 0 with input as make_input([trail]) with data.params as params
}

# Multi-PR — neither PR has approval → violation
test_no_pr_with_approval_fails if {
	pr_none := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr_none, pr_none])
	v := violations with input as make_input([trail]) with data.params as params
	some msg in v
	contains(msg, "independent approval")
}

# ---------------------------------------------------------------------------
# Multiple commits across trails — only failing ones reported
# ---------------------------------------------------------------------------

# Scenario 11: approved commit passes, regular commit without PR fails;
# exactly one violation referencing the failing SHA
test_only_failing_commits_reported if {
	pr := make_pr("aaa1111", "alice", [pr_commit("sha1", "alice")], [approval("bob", 1000001)])
	passing := make_trail("aaa1111", "alice <alice@example.com>", [pr])
	failing := make_trail("bbb2222", "alice <alice@example.com>", [])
	v := violations with input as make_input([passing, failing]) with data.params as params
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
	v := violations with input as make_input([direct, merged]) with data.params as params
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
	count(violations) == 0 with input as make_input([trail_a, trail_b]) with data.params as params
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
	v := violations with input as make_input([trail_a, trail_b]) with data.params as params
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
	v := violations with input as make_input([trail]) with data.params as params
	some msg in v
	contains(msg, "independent approval")
}

# CHANGES_REQUESTED approval must not satisfy independent approval requirement
test_changes_requested_approval_fails if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval_changes_requested("bob", 1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail]) with data.params as params
	some msg in v
	contains(msg, "independent approval")
}

# DISMISSED + APPROVED from independent reviewer: the APPROVED one still satisfies the check
test_dismissed_plus_approved_passes if {
	pr := make_pr("abc1234", "alice",
		[pr_commit("sha1", "alice")],
		[approval_dismissed("bob", 1000001), approval("carol", 1000002)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	count(violations) == 0 with input as make_input([trail]) with data.params as params
}

# ---------------------------------------------------------------------------
# Approver username validation
# ---------------------------------------------------------------------------

# Approval with explicit null username must not be counted as independent approval
test_null_username_approver_fails if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval_null_username(1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail]) with data.params as params
	some msg in v
	contains(msg, "independent approval")
}

# Approval with absent username field must not be counted as independent approval
test_absent_username_approver_fails if {
	pr := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval_no_username(1000001)])
	trail := make_trail("abc1234", "alice <alice@example.com>", [pr])
	v := violations with input as make_input([trail]) with data.params as params
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

# ---------------------------------------------------------------------------
# Approval must be on the PR's final commit
# ---------------------------------------------------------------------------

allowed(prs) if allow with input as make_input([make_trail("abc1234", "alice <alice@example.com>", prs)]) with data.params as params

# A later push dated before the approval, as a backdated author or committer date would be.
backdated_push := [pr_commit("sha_early", "alice"), object.union(pr_commit(head, "alice"), {"timestamp": 500})]

test_backdated_push_after_approval_fails if {
	not allowed([make_pr("abc1234", "alice", backdated_push, [approval_on("bob", 1000005, "sha_early")])])
}

test_reapproval_on_final_commit_passes if {
	allowed([make_pr("abc1234", "alice", backdated_push, [approval_on("bob", 1000005, "sha_early"), approval("bob", 1000020)])])
}

test_approval_without_reviewed_commit_fails if {
	not allowed([make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [{"username": "bob", "timestamp": 1000001, "state": "APPROVED"}])])
}

test_pr_without_head_fails if {
	not allowed([object.remove(make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval("bob", 1000001)]), ["head_sha"])])
}

test_empty_head_and_reviewed_commit_fails if {
	not allowed([object.union(make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval_on("bob", 1000001, "")]), {"head_sha": ""})])
}

test_null_head_and_reviewed_commit_fails if {
	not allowed([object.union(make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval_on("bob", 1000001, null)]), {"head_sha": null})])
}

# ---------------------------------------------------------------------------
# Only PRs in the evaluated repository count
# ---------------------------------------------------------------------------

in_repo_approved := make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval("bob", 1000001)])

with_url(pr, url) := object.union(pr, {"url": url})

test_fork_pr_approval_does_not_count if {
	unapproved := make_pr("abc1234", "alice", backdated_push, [approval_on("bob", 1000005, "sha_early")])
	not allowed([unapproved, with_url(in_repo_approved, "https://github.com/alice/fork/pull/1")])
}

test_unrelated_fork_pr_does_not_block if {
	allowed([in_repo_approved, with_url(make_pr("abc1234", "alice", [], []), "https://github.com/alice/fork/pull/1")])
}

test_enterprise_host_in_repo_passes if {
	allowed([with_url(in_repo_approved, "https://ghe.example.com/owner/repo/pull/42")])
}

test_pr_url_compared_case_insensitively if {
	allowed([with_url(in_repo_approved, "https://github.com/Owner/Repo/pull/42")])
}

test_repository_param_compared_case_insensitively if {
	allow with input as make_input([make_trail("abc1234", "alice <alice@example.com>", [in_repo_approved])])
		with data.params as {"repository": "OWNER/REPO"}
}

test_malformed_pr_url_fails if {
	not allowed([with_url(in_repo_approved, "https://github.com/owner/repo/pull/42/files")])
}

test_non_pull_request_url_fails if {
	not allowed([with_url(in_repo_approved, "https://github.com/owner/repo/issues/42")])
}

test_missing_repository_param_fails_and_says_why if {
	inp := make_input([make_trail("abc1234", "alice <alice@example.com>", [in_repo_approved])])
	not allow with input as inp
	v := violations with input as inp
	some msg in v
	contains(msg, "data.params.repository is not set")
}

test_unapproved_commit_violation_names_the_repository if {
	unapproved := make_pr("abc1234", "alice", backdated_push, [approval_on("bob", 1000005, "sha_early")])
	v := violations with input as make_input([make_trail("abc1234", "alice <alice@example.com>", [unapproved])])
		with data.params as params
	v == {"Commit abc1234: no PR in owner/repo has an independent approval on its final commit"}
}

# Approval alone does not pass a PR with a commit whose author has no linked account.
test_unresolved_commit_author_blocks_approval if {
	not allowed([make_pr("abc1234", "alice", [pr_commit("sha1", "alice"), pr_commit_no_user("sha2")], [approval("bob", 1000001)])])
}

# "ghost" is GitHub's placeholder for a deleted account: it identifies no one.
test_ghost_commit_author_blocks_approval if {
	not allowed([make_pr("abc1234", "alice", [pr_commit("sha1", "alice"), pr_commit("sha2", "ghost")], [approval("bob", 1000001)])])
}

test_ghost_approver_does_not_count if {
	not allowed([make_pr("abc1234", "alice", [pr_commit("sha1", "alice")], [approval("ghost", 1000001)])])
}

test_empty_commit_author_blocks_approval if {
	not allowed([make_pr("abc1234", "alice", [pr_commit("sha1", "alice"), pr_commit("sha2", "")], [approval("bob", 1000001)])])
}

# ---------------------------------------------------------------------------
# Who made a commit comes from its signature
# ---------------------------------------------------------------------------

unsigned(c) := object.remove(c, ["verified", "signer_username", "signed_by_github"])

test_unsigned_commit_blocks_approval if {
	not allowed([make_pr("abc1234", "alice", [unsigned(pr_commit("sha1", "alice"))], [approval("bob", 1000001)])])
}

test_invalid_signature_blocks_approval if {
	not allowed([make_pr("abc1234", "alice", [object.union(pr_commit("sha1", "alice"), {"verified": false})], [approval("bob", 1000001)])])
}

test_signature_without_known_signer_blocks_approval if {
	not allowed([make_pr("abc1234", "alice", [object.remove(pr_commit("sha1", "alice"), ["signer_username"])], [approval("bob", 1000001)])])
}

test_ghost_signer_blocks_approval if {
	not allowed([make_pr("abc1234", "alice", [signed_commit("sha1", "alice", "ghost")], [approval("bob", 1000001)])])
}

github_signed(c) := object.union(object.remove(c, ["signer_username"]), {"signed_by_github": true})

test_commit_signed_by_github_passes if {
	allowed([make_pr("abc1234", "alice", [github_signed(pr_commit("sha1", "alice"))], [approval("bob", 1000001)])])
}

test_invalid_github_signature_blocks_approval if {
	not allowed([make_pr("abc1234", "alice", [object.union(github_signed(pr_commit("sha1", "alice")), {"verified": false})], [approval("bob", 1000001)])])
}

# Naming someone else as the author doesn't let the signer approve their own work.
test_signer_cannot_approve_own_commit_under_another_author if {
	not allowed([make_pr("abc1234", "carol", [signed_commit("sha1", "bob", "alice")], [approval("alice", 1000001)])])
}

test_independent_approval_covers_author_and_signer if {
	allowed([make_pr("abc1234", "carol", [signed_commit("sha1", "bob", "alice")], [approval("dave", 1000001)])])
}

test_unsigned_commit_violation_says_why if {
	pr := make_pr("abc1234", "alice", [unsigned(pr_commit("sha1", "alice"))], [approval("bob", 1000001)])
	v := violations with input as make_input([make_trail("abc1234", "alice <alice@example.com>", [pr])]) with data.params as params
	some msg in v
	contains(msg, "no verified signature")
}

# The trail is not the PR's merge commit, so the PR author is covered too, and
# an approval on an earlier commit still does not count.
test_non_merge_trail_with_old_approval_fails if {
	pr := make_pr("def5678", "alice", backdated_push, [approval_on("bob", 1000005, "sha_early")])
	not allow with input as make_input([make_trail("abc1234", "alice <alice@example.com>", [pr])]) with data.params as params
}

# The PR author must be covered on a non-merge trail even when they wrote none of the commits.
test_non_merge_trail_pr_author_needs_independent_approval if {
	pr := make_pr("def5678", "carol", [pr_commit("sha_alice", "alice")], [approval("carol", 1000001)])
	not allow with input as make_input([make_trail("abc1234", "alice <alice@example.com>", [pr])]) with data.params as params
}

test_unlinked_author_with_known_signer_blocks_approval if {
	not allowed([make_pr("abc1234", "alice", [signed_commit("sha1", null, "alice")], [approval("bob", 1000001)])])
}

test_dismissed_review_on_head_fails_on_non_merge_trail if {
	pr := make_pr("def5678", "alice", [pr_commit("sha1", "alice")], [approval_dismissed("bob", 1000001)])
	not allow with input as make_input([make_trail("abc1234", "alice <alice@example.com>", [pr])]) with data.params as params
}
