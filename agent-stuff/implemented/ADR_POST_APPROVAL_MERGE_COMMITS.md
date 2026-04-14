# Architectural Decision Record: Post-Approval Merge-from-Base Commits

## Status
Proposed

## Context
When evaluating a PR for four-eyes compliance, the tool checks that at least one independent approval exists *after* the latest commit in the PR. This is designed to catch cases where new code is pushed after a reviewer has approved, bypassing review.

However, a common workflow pattern produces a false positive: a developer syncs their feature branch with the base branch (e.g. `Merge branch 'main' into feature-x`) *after* receiving approval. This was observed in PR #666 in the `kosli-dev/cli` repository:

- Approvals received at 13:43:41 and 13:43:57
- A `Merge branch 'main' into cleanup-docs` commit added at 14:27:49
- Result: tool FAILs the commit, even though no new authored code was introduced

The merge-from-base commit only brings in changes already approved and merged to `main` via other PRs. It is not new, unreviewed code.

## Decision Options

### Option 1: Keep Strict Behavior (Current)
Any commit pushed after the last approval causes a FAIL, including merge-from-base commits.

**Pros:**
- Simple, unambiguous rule — easy to explain to auditors
- No special-casing; the timing rule is applied uniformly
- Technically correct: the diff of the PR did change after approval

**Cons:**
- False positives on a very common, low-risk workflow pattern
- Incentivizes developers to *avoid* syncing with main to keep the tool happy, which degrades code quality
- Auditors will learn to distrust FAIL results, undermining the tool's value

### Option 2: Exclude Merge-from-Base Commits When Checking Approval Timing
When determining the "latest commit" timestamp for the approval timing check, skip commits that are merges from the base branch into the feature branch.

A commit can be identified as a merge-from-base if:
- It has more than one parent, AND
- One of its parents is reachable from the base branch (i.e. it exists in the main branch history at the time of the merge)

**Pros:**
- Eliminates false positives for a common, well-understood workflow
- Aligns with the *spirit* of four-eyes: was the authored code independently reviewed?
- Code brought in via merge-from-base was already reviewed when it was merged to main
- No friction penalty for developers keeping branches up to date

**Cons:**
- More complex implementation (requires additional git/API calls to determine parent branch membership)
- Slightly harder to explain to auditors ("we ignore certain merge commits")
- Edge case: a merge-from-base could bring in a conflict resolution that changes behavior — this would go unreviewed

### Option 3: Warn but Don't Fail
Treat post-approval merge-from-base commits as a warning rather than a hard failure. Report them separately in the output.

**Pros:**
- Surfaces the information without blocking
- Gives auditors visibility without creating friction

**Cons:**
- Ambiguous status — auditors must interpret warnings manually
- Likely to be ignored in practice, defeating the purpose

## Recommendation
**Option 2** is recommended.

The four-eyes principle exists to ensure that no single person can introduce a change to production without a second set of eyes. A merge-from-base commit does not introduce new authored code — it only incorporates changes already subject to four-eyes on the base branch. Failing on this pattern creates friction that pushes developers toward worse practices (stale branches, large PRs) without improving security.

### Implementation notes
- The check should be: does this commit have multiple parents, and is at least one parent an ancestor of the base branch HEAD at the time of the merge?
- This can be determined using `git merge-base --is-ancestor <parent-sha> <base-branch>` or equivalent GitHub API calls.
- The reason field in the report should clearly state when this exclusion is applied, e.g.: *"Approval timing check used commit `abc123` (skipped 1 post-approval merge-from-base commit)"*
- The excluded commits should still appear in the report for full auditability.

## Consequence
The approval timing rule becomes: *"at least one independent approval must exist after the latest non-merge-from-base commit in the PR."* Merge-from-base commits are excluded from this calculation but are still recorded in the report.
