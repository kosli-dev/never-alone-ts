# Security Gap: Fake Merge Commit Message Bypass

## The Problem

The four-eyes policy has two independent ways to classify a commit as a merge commit.
Only one of them is safe.

### Root cause

**`four-eyes.rego` lines 101–107:**
```rego
is_merge_commit(commit) if {
    count(commit.parent_shas) > 1          # structural — cannot be faked
}

is_merge_commit(commit) if {
    startswith(commit.message, "Merge pull request #")   # message-based — trivially faked
}
```

**`src/git.ts` line 88:**
```typescript
return parentCount > 1 || message.startsWith('Merge pull request #');
```

Both checks exist because GitHub's real merge commits have the message *and* multiple parents.
The message check is redundant for legitimate commits — and exploitable for malicious ones.

### Attack path

1. Alice and Bob both push commits to a feature branch.
2. Alice names her commits `"Merge pull request #42 from alice/feature"`.
3. The branch is PR'd into main and merged with **rebase** (each commit lands
   individually on main with a single parent).
4. After the merge, `git log --first-parent` surfaces Alice's commits in
   `attestation.commits` with `parent_shas: ["<single-parent>"]`.
5. `is_merge_commit` returns `true` for Alice's commits (message match) even
   though they have only one parent.
6. **Both violation rules skip Alice's commits entirely** (`not is_merge_commit`
   guard at lines 137 and 149). Her code reaches main with no review required.

### What the attack does NOT achieve

Alice still cannot be the sole approver for Bob's commits.
`getPRFullDetails` calls GitHub's `pulls.listCommits` API, which returns every
commit in the PR branch — including Alice's fake-merge commits. Her login
therefore appears in `pr_commit_authors(pr)` and is included in `all_authors`,
so `approval.user.login != author_login` fails for her own approval.

### Summary of impact

| What Alice wants | Achieved? |
|---|---|
| Her own commits bypass four-eyes review | **Yes — gap confirmed** |
| Approve the PR herself as the sole reviewer | No — still blocked |

---

## Tests to Verify the Gap

Add these to `four-eyes_test.rego`. They **currently pass** (wrong behaviour) and
should **fail after the fix is applied** — at which point rename them to assert
the correct failure.

```rego
# ---------------------------------------------------------------------------
# Fake merge commit bypass — these expose the security gap.
# After the fix, each test should be rewritten to assert a violation fires.
# ---------------------------------------------------------------------------

# GAP-1: Single-parent commit with a fake "Merge pull request #" message
# currently passes (no violation), should fail (violation required).
test_fake_merge_message_single_parent_CURRENTLY_PASSES_incorrectly if {
    c := {
        "sha": "bad1234",
        "parent_shas": ["parent1"],           # only one parent — NOT a real merge commit
        "author": {"login": "alice"},
        "date": "2023-01-01T10:00:00Z",
        "message": "Merge pull request #42 from alice/feature",
        "changed_files": ["src/evil.ts"],
        "pr_numbers": [],
    }
    # This should produce a violation but currently does not.
    count(violations) == 0 with input as make_input([c], {})
}

# GAP-2: Same commit linked to a PR with only the attacker's own approval
# — also passes currently, also wrong.
test_fake_merge_self_approval_CURRENTLY_PASSES_incorrectly if {
    c := {
        "sha": "bad1234",
        "parent_shas": ["parent1"],
        "author": {"login": "alice"},
        "date": "2023-01-01T10:00:00Z",
        "message": "Merge pull request #42 from alice/feature",
        "changed_files": ["src/evil.ts"],
        "pr_numbers": [42],
    }
    pr := {
        "commits": [pr_commit_by("bad1234", "alice")],
        "approvals": [approval("alice", "2023-01-01T10:00:01Z")],
    }
    # This should produce a violation but currently does not.
    count(violations) == 0 with input as make_input([c], {"42": pr})
}
```

After the fix is applied, rewrite the two tests to assert violations:

```rego
# POST-FIX versions of the above — confirm the gap is closed.

test_fake_merge_message_single_parent_triggers_violation if {
    c := {
        "sha": "bad1234",
        "parent_shas": ["parent1"],
        "author": {"login": "alice"},
        "date": "2023-01-01T10:00:00Z",
        "message": "Merge pull request #42 from alice/feature",
        "changed_files": ["src/evil.ts"],
        "pr_numbers": [],
    }
    v := violations with input as make_input([c], {})
    some msg in v
    contains(msg, "no associated PR")
}

test_fake_merge_self_approval_triggers_violation if {
    c := {
        "sha": "bad1234",
        "parent_shas": ["parent1"],
        "author": {"login": "alice"},
        "date": "2023-01-01T10:00:00Z",
        "message": "Merge pull request #42 from alice/feature",
        "changed_files": ["src/evil.ts"],
        "pr_numbers": [42],
    }
    pr := {
        "commits": [pr_commit_by("bad1234", "alice")],
        "approvals": [approval("alice", "2023-01-01T10:00:01Z")],
    }
    v := violations with input as make_input([c], {"42": pr})
    some msg in v
    contains(msg, "independent approval")
}
```

Also add a regression test to confirm that real GitHub merge commits (which
always have two parents) are still exempt after the fix:

```rego
# REGRESSION: Real merge commit (2 parents) must still be exempt.
test_real_merge_commit_two_parents_still_passes if {
    c := {
        "sha": "abc1234",
        "parent_shas": ["parent1", "parent2"],   # two parents = real merge
        "author": {"login": "alice"},
        "date": "2023-01-01T10:00:00Z",
        "message": "Merge pull request #42 from alice/feature",
        "changed_files": ["src/app.ts"],
        "pr_numbers": [],
    }
    count(violations) == 0 with input as make_input([c], {})
}
```

---

## Fix

### 1. `four-eyes.rego` — remove the message-based rule

Delete lines 105–107 entirely. Keep only the structural check:

```rego
# Before (lines 101–107):
is_merge_commit(commit) if {
    count(commit.parent_shas) > 1
}

is_merge_commit(commit) if {
    startswith(commit.message, "Merge pull request #")
}

# After:
is_merge_commit(commit) if {
    count(commit.parent_shas) > 1
}
```

**Why this is safe:** GitHub's "Create a merge commit" strategy always produces a
commit with two parents (the tip of main and the tip of the feature branch).
The message prefix is therefore redundant for legitimate commits and dangerous
for malicious ones. Squash merges and rebase merges do not produce multi-parent
commits, so they are already correctly routed to the violation checks.

### 2. `src/git.ts` — mirror the same fix

```typescript
// Before (line 88):
return parentCount > 1 || message.startsWith('Merge pull request #');

// After:
return parentCount > 1;
```

Remove the now-unused `message` variable (lines 86–88 collapse to just the
`parentCount` read).

---

## Verification steps

1. Run the existing test suite — all existing tests must still pass:
   ```
   opa test four-eyes.rego four-eyes_test.rego -v
   ```
2. Temporarily add GAP-1 and GAP-2 (the "CURRENTLY_PASSES_incorrectly"
   versions) before applying the fix and confirm they pass (demonstrating the
   gap exists).
3. Apply the fix.
4. Confirm GAP-1 and GAP-2 now fail (the gap is closed).
5. Replace them with the POST-FIX versions and the regression test; confirm
   the full suite is green.
