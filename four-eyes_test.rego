package policy

import rego.v1

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

# One trail = one commit. The trail name is the commit SHA.
make_trail(commit_obj, prs) := {
	"name": commit_obj.sha,
	"compliance_status": {"attestations_statuses": {"scr-data": {"attestation_data": {
		"commit_sha": commit_obj.sha,
		"repository": "owner/repo",
		"generated_at": "2023-01-01T10:00:00Z",
		"commit": commit_obj,
		"pull_requests": prs,
	}}}},
}

make_input(trails) := {"trails": trails}

commit(sha, author_login, message, changed_files) := {
	"sha": sha,
	"parent_shas": ["parent1"],
	"author": {"git_name": author_login, "login": author_login},
	"date": "2023-01-01T10:00:00Z",
	"message": message,
	"changed_files": changed_files,
}

pr_commit(sha) := {
	"sha": sha,
	"parent_shas": ["parent1"],
	"author": {"login": "alice"},
	"date": "2023-01-01T09:00:00Z",
	"message": "code change",
}

pr_commit_by(sha, login) := {
	"sha": sha,
	"parent_shas": ["parent1"],
	"author": {"login": login},
	"date": "2023-01-01T09:00:00Z",
	"message": "code change",
}

pr_commit_no_github(sha, git_name, git_email) := {
	"sha": sha,
	"parent_shas": ["parent1"],
	"author": {"git_name": git_name, "git_email": git_email, "login": null},
	"date": "2023-01-01T09:00:00Z",
	"message": "code change",
}

approval(login, approved_at) := {"user": {"login": login}, "approved_at": approved_at}

make_pr(number, pr_commits, approvals) := {
	"number": number,
	"url": "https://github.com/owner/repo/pull/42",
	"title": "test PR",
	"state": "closed",
	"merged_at": "2023-01-01T11:00:00Z",
	"author": {"login": "alice"},
	"approvals": approvals,
	"pr_commits": pr_commits,
}

# ---------------------------------------------------------------------------
# Missing attestation
# ---------------------------------------------------------------------------

# Scenario 0 — scr-data attestation absent from trail → violation fires
test_missing_attestation_fails if {
	v := violations with input as make_input([{"name": "abc1234", "compliance_status": {"attestations_statuses": {}}}])
	some msg in v
	contains(msg, "scr-data attestation is missing")
}

# ---------------------------------------------------------------------------
# Service account
# ---------------------------------------------------------------------------

# Scenario 2 — svc_.* pattern (generic service account prefix)
test_service_account_svc_prefix_passes if {
	c := commit("abc1234", "svc_deployer", "automated release", ["deploy/config.yaml"])
	count(violations) == 0 with input as make_input([make_trail(c, [])])
}

# dependabot[bot] — GitHub's dependency update bot
test_service_account_dependabot_passes if {
	c := commit("abc1234", "dependabot[bot]", "chore: bump lodash from 4.17.20 to 4.17.21", ["package.json"])
	count(violations) == 0 with input as make_input([make_trail(c, [])])
}

# github-actions[bot] — GitHub Actions automation commits
test_service_account_github_actions_passes if {
	c := commit("abc1234", "github-actions[bot]", "chore: update generated changelog", ["CHANGELOG.md"])
	count(violations) == 0 with input as make_input([make_trail(c, [])])
}

# Regular user must not be treated as a service account
test_regular_user_not_exempt if {
	c := commit("abc1234", "alice", "feat: add feature", ["src/app.ts"])
	v := violations with input as make_input([make_trail(c, [])])
	some msg in v
	contains(msg, "no associated PR")
}

# Service account pattern can also match via login field
test_service_account_matched_via_login if {
	c := {
		"sha": "abc1234",
		"parent_shas": ["parent1"],
		"author": {"git_name": "Dependabot", "login": "dependabot[bot]"},
		"date": "2023-01-01T10:00:00Z",
		"message": "chore: bump dep",
		"changed_files": ["go.sum"],
	}
	count(violations) == 0 with input as make_input([make_trail(c, [])])
}

# ---------------------------------------------------------------------------
# Merge commits
# ---------------------------------------------------------------------------

# Scenario 3 — Merge commit (multiple parents) linked to PR with independent approval → PASS
test_merge_commit_multiple_parents_passes if {
	c := {
		"sha": "abc1234",
		"parent_shas": ["parent1", "parent2"],
		"author": {"login": "alice"},
		"date": "2023-01-01T10:00:00Z",
		"message": "Merge pull request #42 from alice/feature",
		"changed_files": ["src/app.ts"],
	}
	pr := make_pr(42, [pr_commit_by("sha_alice", "alice")], [approval("bob", "2023-01-01T09:00:01Z")])
	count(violations) == 0 with input as make_input([make_trail(c, [pr])])
}

# Scenario 3 (no PR) — Merge commit with no associated PR → violation
test_merge_commit_multiple_parents_no_pr_fails if {
	c := {
		"sha": "abc1234",
		"parent_shas": ["parent1", "parent2"],
		"author": {"login": "alice"},
		"date": "2023-01-01T10:00:00Z",
		"message": "Merge pull request #42 from alice/feature",
		"changed_files": ["src/app.ts"],
	}
	v := violations with input as make_input([make_trail(c, [])])
	some msg in v
	contains(msg, "no associated PR")
}

# Scenario 4 — Fake merge message on single-parent commit is NOT a merge commit
test_fake_merge_message_single_parent_requires_pr if {
	c := commit("abc1234", "alice", "Merge pull request #42 from alice/feature", ["src/app.ts"])
	v := violations with input as make_input([make_trail(c, [])])
	some msg in v
	contains(msg, "no associated PR")
}

# Scenario 4 (self-approval) — Fake merge commit linked to PR but self-approved only → violation
test_fake_merge_message_self_approval_fails if {
	c := commit("abc1234", "alice", "Merge pull request #42 from alice/feature", ["src/app.ts"])
	pr := make_pr(42, [pr_commit_by("abc1234", "alice")], [approval("alice", "2023-01-01T10:00:01Z")])
	v := violations with input as make_input([make_trail(c, [pr])])
	some msg in v
	contains(msg, "independent approval")
}

# ---------------------------------------------------------------------------
# No associated PR
# ---------------------------------------------------------------------------

# Scenario 5 — Commit pushed directly to main — no PR
test_no_pr_fails if {
	c := commit("abc1234", "alice", "feat: add feature", ["src/app.ts"])
	v := violations with input as make_input([make_trail(c, [])])
	some msg in v
	contains(msg, "no associated PR")
}

# ---------------------------------------------------------------------------
# PR approval
# ---------------------------------------------------------------------------

# Scenario 1 — Standard PR with independent approval after latest commit → PASS
test_independent_approval_after_commit_passes if {
	c := commit("abc1234", "alice", "feat: add feature", ["src/app.ts"])
	pr := make_pr(42, [pr_commit("abc1234")], [approval("bob", "2023-01-01T10:00:01Z")])
	count(violations) == 0 with input as make_input([make_trail(c, [pr])])
}

# Scenario 7 — Self-approval only → violation
test_self_approval_fails if {
	c := commit("abc1234", "alice", "feat: add feature", ["src/app.ts"])
	pr := make_pr(42, [pr_commit("abc1234")], [approval("alice", "2023-01-01T10:00:01Z")])
	v := violations with input as make_input([make_trail(c, [pr])])
	some msg in v
	contains(msg, "independent approval")
}

# Scenario 8 — New code pushed after approval → violation
test_approval_before_latest_commit_fails if {
	c := commit("abc1234", "alice", "feat: add feature", ["src/app.ts"])
	late_commit := object.union(pr_commit("abc1234"), {"date": "2023-01-01T11:00:00Z"})
	pr := make_pr(42, [pr_commit("sha_early"), late_commit], [approval("bob", "2023-01-01T10:30:00Z")])
	v := violations with input as make_input([make_trail(c, [pr])])
	some msg in v
	contains(msg, "independent approval")
}

# Scenario 6 — PR exists but has no approvals → violation
test_no_approvals_fails if {
	c := commit("abc1234", "alice", "feat: add feature", ["src/app.ts"])
	pr := make_pr(42, [pr_commit("abc1234")], [])
	v := violations with input as make_input([make_trail(c, [pr])])
	some msg in v
	contains(msg, "independent approval")
}

# ---------------------------------------------------------------------------
# Post-approval merge-from-base
# ---------------------------------------------------------------------------

# Scenario 9 — Post-approval merge-from-base (ignore mode): merge-from-base at 11:00,
# approval at 10:00, code commit at 09:00 — merge-from-base excluded from timing → PASS
test_merge_from_base_after_approval_ignored if {
	c := commit("abc1234", "alice", "feat: add feature", ["src/app.ts"])
	code_commit := pr_commit("sha_code") # date: 09:00
	merge_commit := {
		"sha": "sha_merge",
		"parent_shas": ["sha_code", "external_sha"], # one parent outside the PR
		"author": {"login": "alice"},
		"date": "2023-01-01T11:00:00Z",
		"message": "Merge branch 'main' into feature",
	}
	pr := make_pr(42, [code_commit, merge_commit], [approval("bob", "2023-01-01T10:00:00Z")])
	count(violations) == 0
		with input as make_input([make_trail(c, [pr])])
		with post_approval_merge_commits as "ignore"
}

# Scenario 10 — Post-approval merge-from-base (strict mode): same setup → FAIL
test_merge_from_base_after_approval_strict_fails if {
	c := commit("abc1234", "alice", "feat: add feature", ["src/app.ts"])
	code_commit := pr_commit("sha_code")
	merge_commit := {
		"sha": "sha_merge",
		"parent_shas": ["sha_code", "external_sha"],
		"author": {"login": "alice"},
		"date": "2023-01-01T11:00:00Z",
		"message": "Merge branch 'main' into feature",
	}
	pr := make_pr(42, [code_commit, merge_commit], [approval("bob", "2023-01-01T10:00:00Z")])
	v := violations
		with input as make_input([make_trail(c, [pr])])
		with post_approval_merge_commits as "strict"
	some msg in v
	contains(msg, "independent approval")
}

# Scenario 9 (edge case) — Every PR commit is a merge-from-base: fallback uses all,
# approval at 12:00 is after latest commit at 11:00 → PASS
test_all_commits_merge_from_base_fallback_uses_all if {
	c := commit("abc1234", "alice", "feat: add feature", ["src/app.ts"])
	merge_only := {
		"sha": "sha_merge",
		"parent_shas": ["external_sha1", "external_sha2"],
		"author": {"login": "alice"},
		"date": "2023-01-01T11:00:00Z",
		"message": "Merge branch 'main' into feature",
	}
	pr := make_pr(42, [merge_only], [approval("bob", "2023-01-01T12:00:00Z")])
	count(violations) == 0
		with input as make_input([make_trail(c, [pr])])
		with post_approval_merge_commits as "ignore"
}

# ---------------------------------------------------------------------------
# Multi-author PRs
# ---------------------------------------------------------------------------

# Scenario 13 — Multi-author PR: each author approved by the other → PASS
test_multi_author_cross_approval_passes if {
	c := commit("abc1234", "sami", "feat: collab feature", ["src/app.ts"])
	pr := make_pr(42,
		[pr_commit_by("sha_sami", "sami"), pr_commit_by("sha_faye", "faye")],
		[approval("faye", "2023-01-01T10:00:01Z"), approval("sami", "2023-01-01T10:00:02Z")],
	)
	count(violations) == 0 with input as make_input([make_trail(c, [pr])])
}

# Scenario 14 — Multi-author PR: faye approves but sami (co-author) does not approve faye → FAIL
test_multi_author_only_one_committer_approves_fails if {
	c := commit("abc1234", "sami", "feat: collab feature", ["src/app.ts"])
	pr := make_pr(42,
		[pr_commit_by("sha_sami", "sami"), pr_commit_by("sha_faye", "faye")],
		[approval("faye", "2023-01-01T10:00:01Z")],
	)
	v := violations with input as make_input([make_trail(c, [pr])])
	some msg in v
	contains(msg, "independent approval")
}

# ---------------------------------------------------------------------------
# Null login / unresolvable identity
# ---------------------------------------------------------------------------

# Null login — PR commit author has no linked GitHub account → "identity unverifiable" violation
test_null_login_pr_commit_unverifiable if {
	c := commit("abc1234", "alice", "feat: add feature", ["src/app.ts"])
	pr := make_pr(42,
		[pr_commit_no_github("sha1", "John Doe", "john@company.com")],
		[approval("bob", "2023-01-01T10:00:01Z")],
	)
	v := violations with input as make_input([make_trail(c, [pr])])
	some msg in v
	contains(msg, "identity unverifiable")
	contains(msg, "john@company.com")
}

# Null login — both commit and PR commit authors unresolvable: must not vacuously pass
test_all_null_logins_no_vacuous_pass if {
	c := {
		"sha": "abc1234",
		"parent_shas": ["parent1"],
		"author": {"git_name": "John Doe", "git_email": "john@company.com", "login": null},
		"date": "2023-01-01T10:00:00Z",
		"message": "feat: add feature",
		"changed_files": ["src/app.ts"],
	}
	pr := make_pr(42,
		[pr_commit_no_github("sha1", "John Doe", "john@company.com")],
		[approval("bob", "2023-01-01T10:00:01Z")],
	)
	v := violations with input as make_input([make_trail(c, [pr])])
	some msg in v
	contains(msg, "independent approval")
}

# Null login — PR commit matches service-account pattern by git_name → no identity violation
test_null_login_service_account_pr_commit_exempt if {
	c := commit("abc1234", "alice", "feat: add feature", ["src/app.ts"])
	pr := make_pr(42,
		[pr_commit_no_github("sha1", "svc_bot", "svc@company.com")],
		[approval("bob", "2023-01-01T10:00:01Z")],
	)
	v := violations with input as make_input([make_trail(c, [pr])])
	every msg in v {
		not contains(msg, "identity unverifiable")
	}
}

# ---------------------------------------------------------------------------
# Multiple associated PRs (any passing PR is sufficient)
# ---------------------------------------------------------------------------

# Multi-PR — first PR has no approval, second does → PASS
test_second_pr_approval_satisfies_check if {
	c := commit("abc1234", "alice", "feat: add feature", ["src/app.ts"])
	pr_none := make_pr(41, [pr_commit("abc1234")], [])
	pr_approved := make_pr(42, [pr_commit("abc1234")], [approval("bob", "2023-01-01T10:00:01Z")])
	count(violations) == 0 with input as make_input([make_trail(c, [pr_none, pr_approved])])
}

# Multi-PR — neither PR has approval → FAIL
test_no_pr_with_approval_fails if {
	c := commit("abc1234", "alice", "feat: add feature", ["src/app.ts"])
	pr_none := make_pr(41, [pr_commit("abc1234")], [])
	v := violations with input as make_input([make_trail(c, [pr_none, pr_none])])
	some msg in v
	contains(msg, "independent approval")
}

# ---------------------------------------------------------------------------
# Multiple commits across trails — only failing ones reported
# ---------------------------------------------------------------------------

# Scenario 11 — Service account trail passes, regular commit without PR fails;
# exactly one violation referencing the failing SHA
test_only_failing_commits_reported if {
	passing_commit := commit("aaa1111", "svc_bot", "automated", ["src/app.ts"])
	failing_commit := commit("bbb2222", "alice", "feat: add feature", ["src/app.ts"])
	v := violations with input as make_input([
		make_trail(passing_commit, []),
		make_trail(failing_commit, []),
	])
	count(v) == 1
	some msg in v
	contains(msg, "bbb2222")
}
