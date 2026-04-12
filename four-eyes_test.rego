package policy

import rego.v1

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

exemptions := {
	"serviceAccounts": ["svc_.*"],
	"filePaths": ["docs/release-notes.md"],
	"fileNames": ["README.md"],
}

make_input(commits, pull_requests) := {"trail": {"compliance_status": {"attestations_statuses": {"scr-data": {"user_data": {
	"config": {"exemptions": exemptions},
	"commits": commits,
	"pull_requests": pull_requests,
}}}}}}

commit(sha, author_login, message, changed_files) := {
	"sha": sha,
	"parent_shas": ["parent1"],
	"author": {"git_name": author_login, "login": author_login},
	"date": "2023-01-01T10:00:00Z",
	"message": message,
	"changed_files": changed_files,
	"pr_numbers": [],
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

approval(login, approved_at) := {"user": {"login": login}, "approved_at": approved_at}

# ---------------------------------------------------------------------------
# Service account
# ---------------------------------------------------------------------------

# Scenario 2 — Service account commit
test_service_account_passes if {
	c := commit("abc1234", "svc_deployer", "automated", ["src/app.ts"])
	count(violations) == 0 with input as make_input([c], {})
}

# ---------------------------------------------------------------------------
# Exempted files
# ---------------------------------------------------------------------------

# Scenario 3 — Exempted files only
test_exempt_filename_passes if {
	c := commit("abc1234", "alice", "update readme", ["README.md"])
	count(violations) == 0 with input as make_input([c], {})
}

# Scenario 3 — Exempted files only
test_exempt_filepath_passes if {
	c := commit("abc1234", "alice", "update release notes", ["docs/release-notes.md"])
	count(violations) == 0 with input as make_input([c], {})
}

# Scenario 4 — Mixed files — some exempt, some not
test_mixed_files_not_exempt if {
	c := commit("abc1234", "alice", "update stuff", ["README.md", "src/app.ts"])
	v := violations with input as make_input([c], {})
	some msg in v
	contains(msg, "abc1234")
}

# ---------------------------------------------------------------------------
# Merge commits
# ---------------------------------------------------------------------------

# Scenario 5 — GitHub merge commit
test_merge_commit_multiple_parents_passes if {
	c := {
		"sha": "abc1234",
		"parent_shas": ["parent1", "parent2"],
		"author": {"login": "alice"},
		"date": "2023-01-01T10:00:00Z",
		"message": "feat: some feature",
		"changed_files": ["src/app.ts"],
	}
	count(violations) == 0 with input as make_input([c], {})
}

# Scenario 5 — GitHub merge commit
test_merge_commit_pr_message_passes if {
	c := commit("abc1234", "alice", "Merge pull request #42 from alice/feature", ["src/app.ts"])
	count(violations) == 0 with input as make_input([c], {})
}

# ---------------------------------------------------------------------------
# No associated PR
# ---------------------------------------------------------------------------

# Scenario 6 — Commit pushed directly to main — no PR
test_no_pr_fails if {
	c := commit("abc1234", "alice", "feat: add feature", ["src/app.ts"])
	v := violations with input as make_input([c], {})
	some msg in v
	contains(msg, "no associated PR")
}

# ---------------------------------------------------------------------------
# PR approval
# ---------------------------------------------------------------------------

# Scenario 1 — Standard PR with independent approval
test_independent_approval_after_commit_passes if {
	c := object.union(commit("abc1234", "alice", "feat: add feature", ["src/app.ts"]), {"pr_numbers": [42]})
	pr := {
		"commits": [pr_commit("abc1234")],
		"approvals": [approval("bob", "2023-01-01T10:00:01Z")],
	}
	count(violations) == 0 with input as make_input([c], {"42": pr})
}

# Scenario 8 — Self-approval only
test_self_approval_fails if {
	c := object.union(commit("abc1234", "alice", "feat: add feature", ["src/app.ts"]), {"pr_numbers": [42]})
	pr := {
		"commits": [pr_commit("abc1234")],
		"approvals": [approval("alice", "2023-01-01T10:00:01Z")],
	}
	v := violations with input as make_input([c], {"42": pr})
	some msg in v
	contains(msg, "independent approval")
}

# Scenario 9 — New code pushed after approval
test_approval_before_latest_commit_fails if {
	c := object.union(commit("abc1234", "alice", "feat: add feature", ["src/app.ts"]), {"pr_numbers": [42]})
	late_commit := object.union(pr_commit("abc1234"), {"date": "2023-01-01T11:00:00Z"})
	pr := {
		"commits": [pr_commit("sha_early"), late_commit],
		"approvals": [approval("bob", "2023-01-01T10:30:00Z")],
	}
	v := violations with input as make_input([c], {"42": pr})
	some msg in v
	contains(msg, "independent approval")
}

# Scenario 7 — PR exists but has no approvals
test_no_approvals_fails if {
	c := object.union(commit("abc1234", "alice", "feat: add feature", ["src/app.ts"]), {"pr_numbers": [42]})
	pr := {
		"commits": [pr_commit("abc1234")],
		"approvals": [],
	}
	v := violations with input as make_input([c], {"42": pr})
	some msg in v
	contains(msg, "independent approval")
}

# ---------------------------------------------------------------------------
# Post-approval merge-from-base (ignore mode)
# ---------------------------------------------------------------------------

# Scenario 10 — Post-approval merge-from-base (ignore mode)
test_merge_from_base_after_approval_ignored if {
	# PR has: code commit at 09:00, approval at 10:00, merge-from-base at 11:00
	# In ignore mode the merge-from-base should not invalidate the approval
	c := object.union(commit("abc1234", "alice", "feat: add feature", ["src/app.ts"]), {"pr_numbers": [42]})
	code_commit := pr_commit("sha_code") # date: 09:00
	merge_commit := {
		"sha": "sha_merge",
		"parent_shas": ["sha_code", "external_sha"], # one parent outside PR
		"author": {"login": "alice"},
		"date": "2023-01-01T11:00:00Z",
		"message": "Merge branch 'main' into feature",
	}
	pr := {
		"commits": [code_commit, merge_commit],
		"approvals": [approval("bob", "2023-01-01T10:00:00Z")],
	}
	count(violations) == 0
		with input as make_input([c], {"42": pr})
		with post_approval_merge_commits as "ignore"
}

# Scenario 11 — Post-approval merge-from-base (strict mode)
test_merge_from_base_after_approval_strict_fails if {
	c := object.union(commit("abc1234", "alice", "feat: add feature", ["src/app.ts"]), {"pr_numbers": [42]})
	code_commit := pr_commit("sha_code")
	merge_commit := {
		"sha": "sha_merge",
		"parent_shas": ["sha_code", "external_sha"],
		"author": {"login": "alice"},
		"date": "2023-01-01T11:00:00Z",
		"message": "Merge branch 'main' into feature",
	}
	pr := {
		"commits": [code_commit, merge_commit],
		"approvals": [approval("bob", "2023-01-01T10:00:00Z")],
	}
	v := violations
		with input as make_input([c], {"42": pr})
		with post_approval_merge_commits as "strict"
	some msg in v
	contains(msg, "independent approval")
}

# Scenario 12 — All PR commits are merge-from-base — fallback to all commits (ignore mode)
test_all_commits_merge_from_base_fallback_uses_all if {
	# When every commit in the PR is a merge-from-base, fall back to all commits
	# The approval at 12:00 is after the latest commit at 11:00 — should pass
	c := object.union(commit("abc1234", "alice", "feat: add feature", ["src/app.ts"]), {"pr_numbers": [42]})
	merge_only := {
		"sha": "sha_merge",
		"parent_shas": ["external_sha1", "external_sha2"],
		"author": {"login": "alice"},
		"date": "2023-01-01T11:00:00Z",
		"message": "Merge branch 'main' into feature",
	}
	pr := {
		"commits": [merge_only],
		"approvals": [approval("bob", "2023-01-01T12:00:00Z")],
	}
	count(violations) == 0
		with input as make_input([c], {"42": pr})
		with post_approval_merge_commits as "ignore"
}

# ---------------------------------------------------------------------------
# Multi-author PRs
# ---------------------------------------------------------------------------

# Scenario 13 — Multi-author PR, cross-approval → PASS
test_multi_author_cross_approval_passes if {
	c := object.union(commit("abc1234", "sami", "feat: collab feature", ["src/app.ts"]), {"pr_numbers": [42]})
	pr := {
		"commits": [pr_commit_by("sha_sami", "sami"), pr_commit_by("sha_faye", "faye")],
		"approvals": [
			approval("faye", "2023-01-01T10:00:01Z"),
			approval("sami", "2023-01-01T10:00:02Z"),
		],
	}
	count(violations) == 0 with input as make_input([c], {"42": pr})
}

# Scenario 14 — Multi-author PR, only one committer approves → FAIL
test_multi_author_only_one_committer_approves_fails if {
	c := object.union(commit("abc1234", "sami", "feat: collab feature", ["src/app.ts"]), {"pr_numbers": [42]})
	pr := {
		"commits": [pr_commit_by("sha_sami", "sami"), pr_commit_by("sha_faye", "faye")],
		"approvals": [approval("faye", "2023-01-01T10:00:01Z")],
	}
	v := violations with input as make_input([c], {"42": pr})
	some msg in v
	contains(msg, "independent approval")
}

# ---------------------------------------------------------------------------
# Null login / unresolvable identity
# ---------------------------------------------------------------------------

pr_commit_no_github(sha, git_name, git_email) := {
	"sha": sha,
	"parent_shas": ["parent1"],
	"author": {"git_name": git_name, "git_email": git_email, "login": null},
	"date": "2023-01-01T09:00:00Z",
	"message": "code change",
}

# Scenario 17 — PR commit author has no linked GitHub account → "identity unverifiable" violation
test_null_login_pr_commit_unverifiable if {
	c := object.union(commit("abc1234", "alice", "feat: add feature", ["src/app.ts"]), {"pr_numbers": [42]})
	pr := {
		"number": 42,
		"commits": [pr_commit_no_github("sha1", "John Doe", "john@company.com")],
		"approvals": [approval("bob", "2023-01-01T10:00:01Z")],
	}
	v := violations with input as make_input([c], {"42": pr})
	some msg in v
	contains(msg, "identity unverifiable")
	contains(msg, "john@company.com")
}

# Scenario 18 — All logins null: has_independent_approval must not vacuously pass
test_all_null_logins_no_vacuous_pass if {
	c := {
		"sha": "abc1234",
		"parent_shas": ["parent1"],
		"author": {"git_name": "John Doe", "git_email": "john@company.com", "login": null},
		"date": "2023-01-01T10:00:00Z",
		"message": "feat: add feature",
		"changed_files": ["src/app.ts"],
		"pr_numbers": [42],
	}
	pr := {
		"number": 42,
		"commits": [pr_commit_no_github("sha1", "John Doe", "john@company.com")],
		"approvals": [approval("bob", "2023-01-01T10:00:01Z")],
	}
	v := violations with input as make_input([c], {"42": pr})
	some msg in v
	contains(msg, "independent approval")
}

# Scenario 19 — PR commit with null login but matching service-account pattern → no identity violation
test_null_login_service_account_pr_commit_exempt if {
	c := object.union(commit("abc1234", "alice", "feat: add feature", ["src/app.ts"]), {"pr_numbers": [42]})
	pr := {
		"number": 42,
		"commits": [pr_commit_no_github("sha1", "svc_bot", "svc@company.com")],
		"approvals": [approval("bob", "2023-01-01T10:00:01Z")],
	}
	v := violations with input as make_input([c], {"42": pr})
	every msg in v {
		not contains(msg, "identity unverifiable")
	}
}

# ---------------------------------------------------------------------------
# Multiple associated PRs (Option 2 — any PR passing is sufficient)
# ---------------------------------------------------------------------------

# Scenario 15 — Commit linked to two PRs; first has no approval, second does → PASS
test_second_pr_approval_satisfies_check if {
	c := object.union(commit("abc1234", "alice", "feat: add feature", ["src/app.ts"]), {"pr_numbers": [41, 42]})
	pr_no_approval := {
		"commits": [pr_commit("abc1234")],
		"approvals": [],
	}
	pr_with_approval := {
		"commits": [pr_commit("abc1234")],
		"approvals": [approval("bob", "2023-01-01T10:00:01Z")],
	}
	count(violations) == 0 with input as make_input([c], {"41": pr_no_approval, "42": pr_with_approval})
}

# Scenario 16 — Commit linked to two PRs; neither has approval → FAIL
test_no_pr_with_approval_fails if {
	c := object.union(commit("abc1234", "alice", "feat: add feature", ["src/app.ts"]), {"pr_numbers": [41, 42]})
	pr_no_approval := {
		"commits": [pr_commit("abc1234")],
		"approvals": [],
	}
	v := violations with input as make_input([c], {"41": pr_no_approval, "42": pr_no_approval})
	some msg in v
	contains(msg, "independent approval")
}

# ---------------------------------------------------------------------------
# Mixed: multiple commits, some pass some fail
# ---------------------------------------------------------------------------

# Scenario 12 — Multiple commits — only failing ones reported
test_only_failing_commits_reported if {
	passing := object.union(commit("aaa1111", "svc_bot", "automated", ["src/app.ts"]), {"pr_numbers": []})
	failing := commit("bbb2222", "alice", "feat: add feature", ["src/app.ts"])
	v := violations with input as make_input([passing, failing], {})
	count(v) == 1
	some msg in v
	contains(msg, "bbb2222")
}
