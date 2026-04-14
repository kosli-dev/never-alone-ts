# SCR-01 — Four-Eyes Source Code Review

| Field | Value |
| --- | --- |
| **ID** | SCR-01 |
| **Name** | Four-Eyes Source Code Review |
| **Category** | Source Code Integrity |
| **Version** | 1.0 |
| **Status** | Active |
| **Policy engine** | OPA / Rego v1 |
| **Policy file** | `four-eyes.rego` |
| **Collector** | TypeScript CLI (`src/index.ts`) |

---

## Intent

Every code change that reaches a production release must have been reviewed and approved by at least one person other than its author before it was merged. This is the *four-eyes principle* — no single developer should be able to land unreviewed code unilaterally.

The control operationalises this by examining all commits in a release range (the delta between two tags) and verifying that each one either:

- was authored by an automated agent (service account) that is trusted by policy, or
- is a merge commit created by the VCS (not a human-authored change), or
- was delivered via a pull request that received at least one independent approval *after* the last code commit in that PR.

A violation means a commit reached the release that was not subject to independent review at any point in its lifecycle.

---

## Regulatory mapping

| Framework | Clause | Why it fits |
| --- | --- | --- |
| NIST 800-53 | CM-5(4) Dual Authorization | Directly requires two separate parties to authorize a change — the control enforces exactly this by rejecting self-approved commits |
| NIST 800-53 | AC-5 Separation of Duties | The author/approver independence check is a textbook SoD enforcement at the code change level |
| NIST 800-53 | AU-12 Audit Record Generation | The JSON attestation artifact is a per-commit audit record of who authorized each change and when |
| ISO 27001 (2022) | 5.3 Segregation of Duties | Prevents any single person from both authoring and approving their own change; the control produces evidence this was upheld |
| ISO 27001 (2022) | 8.25 Secure Development Life Cycle | The control is embedded in the CI/CD pipeline as a security gate over source code changes |
| ISO 27001 (2022) | 8.32 Change Management | Produces documented, timestamped authorization evidence for each change entering a release |
| ISO 20000-1 | 7.5 Change Management (authorization sub-clause) | Satisfies the requirement that changes are authorized by an appropriate authority before deployment |
| DORA | Article 17 — ICT Change Management | Provides retained, machine-readable evidence that each ICT change was approved by an authority independent of the author |
| DORA | Article 9(2) — Protection and Prevention | Enforces access restriction: no actor can unilaterally push a change to production without an independent approver |

---

## Data collection

The collector is a TypeScript CLI that runs in CI against a specific release range (`BASE_TAG`..`CURRENT_TAG`).

```text
git log --first-parent BASE_TAG..CURRENT_TAG
         │
         ▼
  For each commit on main:
    1. Resolve author GitHub identity   (GitHub Commits API)
    2. List changed files               (git diff-tree)
    3. Find associated PR number        (GitHub Search API: sha:<commit>)
    4. If PR found — fetch PR details:
         - all commits on the PR branch
         - all submitted reviews (approvals)
         (GitHub Pull Requests API)
         │
         ▼
  Write att_data_<CURRENT_TAG>.json
  (commits[] + pull_requests{} + config + metadata)
```

**Output shape (abbreviated):**

```json
{
  "repository": "owner/repo",
  "range": { "base": "v1.0.0", "current": "v1.1.0", "base_sha": "...", "current_sha": "..." },
  "generated_at": "<ISO-8601>",
  "config": { "exemptions": { "serviceAccounts": [] } },
  "commits": [
    {
      "sha": "<40-char>",
      "parent_shas": ["<sha>"],
      "author": { "git_name": "...", "login": "...", "user_id": 0 },
      "date": "<ISO-8601>",
      "message": "...",
      "changed_files": ["src/foo.ts"],
      "pr_number": 42
    }
  ],
  "pull_requests": {
    "42": {
      "number": 42,
      "commits": [{ "sha": "...", "author": { "login": "..." }, "date": "..." }],
      "approvals": [{ "user": { "login": "..." }, "approved_at": "<ISO-8601>" }]
    }
  }
}
```

The attestation file is uploaded to Kosli via `kosli attest generic`, which makes it available to the policy engine as `input.trail.compliance_status.attestations_statuses["scr-data"].user_data`.

**BASE_TAG auto-resolution:** If `BASE_TAG` is not supplied, the collector walks git history backward and queries Kosli for the most recent trail that already has an `scr-data` attestation, using that commit's tag as the base. This ensures consecutive releases are always evaluated contiguously.

---

## Evaluation logic

The Rego policy evaluates the attestation in a single pass. For each commit it applies exemption checks in order; the first match short-circuits the rest:

```text
For each commit in attestation.commits:

  1. Is the author a service account?         → PASS (exempt)
  2. Is this a merge commit?                   → PASS (exempt)
     (multiple parents  OR  "Merge pull request #" message)
  3. No associated PR number?                  → FAIL
  4. PR found — does it have an independent
     approval after the latest code commit?    → PASS / FAIL
```

Step 5 detail — "independent approval after latest code commit":

- **Independent**: approver's `login` ≠ commit author's `login`
- **After**: `approval.approved_at > max(relevant_pr_commits.date)`
- **Relevant commits**: controlled by `post_approval_merge_commits` — in `ignore` mode, commits that merge from the base branch back into the feature branch are excluded from the timestamp comparison (they only carry changes already reviewed on main); in `strict` mode all commits count

---

## Policy

```rego
package policy

import rego.v1

default allow = false

allow if count(violations) == 0

attestation := input.trail.compliance_status.attestations_statuses["scr-data"].user_data

# "ignore" — exclude merge-from-base commits from the approval timing check
# "strict" — any commit after the last approval causes a failure
post_approval_merge_commits := "strict"

# Helpers
pr_commit_shas(pr) := {c.sha | some c in pr.commits}

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

# Fallback: if every commit is a merge-from-base, use all
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
    some approval in pr.approvals
    approval.user.login != commit.author.login
    time.parse_rfc3339_ns(approval.approved_at) > cutoff
}

# Service account exemption
is_service_account(commit) if {
    some pattern in attestation.config.exemptions.serviceAccounts
    regex.match(pattern, commit.author.git_name)
}

is_service_account(commit) if {
    some pattern in attestation.config.exemptions.serviceAccounts
    regex.match(pattern, commit.author.login)
}

is_merge_commit(commit) if { count(commit.parent_shas) > 1 }
is_merge_commit(commit) if { startswith(commit.message, "Merge pull request #") }

# Violations
violations contains msg if {
    some commit in attestation.commits
    not is_service_account(commit)
    not is_merge_commit(commit)
    not commit.pr_number
    msg := sprintf(
        "Commit %v (%v): no associated PR found",
        [substring(commit.sha, 0, 7), commit.message],
    )
}

violations contains msg if {
    some commit in attestation.commits
    not is_service_account(commit)
    not is_merge_commit(commit)
    commit.pr_number
    pr := attestation.pull_requests[sprintf("%d", [commit.pr_number])]
    not has_independent_approval(commit, pr)
    msg := sprintf(
        "Commit %v (%v): PR #%v has no independent approval after latest code commit",
        [substring(commit.sha, 0, 7), commit.message, commit.pr_number],
    )
}
```

---

## Configuration

All configuration lives in `scr.config.json` at the repository root and is embedded into the attestation at collection time. The policy reads it back from the attestation — there is no runtime config injection.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `exemptions.serviceAccounts` | `string[]` | `[]` | Regex patterns matched against `git_name` and `login`. Commits by matching authors are fully exempt. |
| `post_approval_merge_commits` | `"ignore"` \| `"strict"` | `"strict"` | Controls whether merge-from-base commits count against the approval timestamp. Set in `four-eyes.rego` directly. |

**Environment variables (collector):**

| Variable | Required | Description |
| --- | --- | --- |
| `CURRENT_TAG` | Yes | Git tag or SHA marking the end of the release range |
| `GITHUB_REPOSITORY` | Yes | `owner/repo` format |
| `GITHUB_TOKEN` | Yes | GitHub PAT with `repo` scope |
| `BASE_TAG` | No | Start of release range; auto-resolved from Kosli if omitted |
| `KOSLI_FLOW` | No | Kosli flow name used for BASE_TAG auto-resolution |
| `KOSLI_ATTESTATION_NAME` | No | Name of the attestation in Kosli (default: `scr-data`) |

---

## Exemptions

| Exemption type | Condition | Rationale |
| --- | --- | --- |
| Service account | Author name or login matches a regex in `serviceAccounts` | Automated commits (dependency updates, release scripts, CI bots) are not human-authored and cannot have a human reviewer. The service account identity itself is the control — access to that credential is the review gate. |
| Merge commit | Multiple parents or `Merge pull request #` message | GitHub's merge commits are structural — they record that a PR was merged, not that new code was introduced. The code itself was already in the PR commits, which are evaluated separately. |

---

## Pass / fail criteria

| Outcome | Condition |
| --- | --- |
| `PASS` | Every commit in the range is either exempt, or was delivered via a PR that received at least one independent approval after its last code change. |
| `FAIL` | At least one commit is not exempt and either has no associated PR, or its PR has no independent approval that post-dates all code commits. The violation message includes the commit SHA (7-char), message, and PR number where applicable. |

---

## Scenarios

See [`SCENARIOS.md`](SCENARIOS.md) for the full set of named test cases with diagrams and expected outcomes. Summary:

| # | Name | Result |
| --- | --- | --- |
| 1 | Standard PR with independent approval | PASS |
| 2 | Service account commit | PASS |
| 3 | GitHub merge commit | PASS |
| 4 | Commit pushed directly to main — no PR | FAIL |
| 5 | PR exists but has no approvals | FAIL |
| 6 | Self-approval only | FAIL |
| 7 | New code pushed after approval | FAIL |
| 8 | Post-approval merge-from-base (`ignore` mode) | PASS |
| 9 | Post-approval merge-from-base (`strict` mode) | FAIL |
| 10 | All PR commits are merge-from-base — fallback (`ignore` mode) | PASS |
| 11 | Multiple commits — only failing ones reported | FAIL (partial) |

---

## Limitations

- **Single PR per commit**: the collector finds only the first PR returned by GitHub's search API for a given commit SHA. If a commit is associated with multiple PRs (e.g. re-opened PRs, branches targeting multiple bases), only one is checked.
- **GitHub-only**: PR and approval data is fetched exclusively from the GitHub API. Approvals recorded in external systems (Jira, email, Slack) are invisible to this control.
- **Approval dismissal not tracked**: if a review approval was later dismissed (e.g. because new commits were pushed), GitHub's API may still return it. The control's own timestamp comparison is the primary safeguard against stale approvals.
- **Empty `changed_files` is not file-exempt**: a commit with no files listed (possible if git diff-tree returns nothing) is not treated as file-exempt and is subject to the full PR approval check.
- **Author identity requires platform API**: if the platform API cannot resolve a `git_name` to a `login`, the `has_independent_approval` check cannot compare author against approver and will fail the commit. Ensure the API token has sufficient scope.
- **No enforcement at merge time**: this control is evaluated at release time, not at the moment a PR is merged. A violation means the release must be blocked or remediated; it does not prevent the offending merge from happening.

---

## Failure remediation

When the control fails, the violation message identifies the commit SHA and the reason. Typical remediation steps:

1. **No associated PR** — the commit was pushed directly to the default branch. Options: revert the commit and re-deliver via a PR, or obtain a documented exception if the change was an emergency hotfix.
2. **No independent approval** — open the PR, request review from a second person, and re-run the evaluation after they approve. If the PR is already merged, a follow-up review PR with a sign-off commit may satisfy the requirement depending on your policy.
3. **Approval predates latest commit** — a reviewer approved before the final code was pushed. Re-request review so the approver can confirm the final state.

---

## False positive guidance

| Pattern | Why it triggers | Resolution |
| --- | --- | --- |
| Developer syncs feature branch with `main` after approval (`Merge branch 'main' into feature-x`) | In `strict` mode this merge-from-base commit post-dates the approval | Switch `post_approval_merge_commits` to `"ignore"` in `four-eyes.rego` |
| Bot commits not matching any `serviceAccounts` pattern | The author name is not in the exemption list | Add the bot's `git_name` or `login` pattern to `serviceAccounts` in `scr.config.json` |

---

## Dependencies

| Dependency | Required | Notes |
| --- | --- | --- |
| GitHub API | Yes | REST API v3. PAT must have `repo` scope (or `public_repo` for public repositories). Subject to GitHub secondary rate limits — collector retries on 429. |
| Kosli CLI | Yes (for attestation upload and BASE_TAG resolution) | `kosli` must be on `PATH`. `KOSLI_ORG` and `KOSLI_API_TOKEN` must be set. |
| Git | Yes | `git` must be on `PATH`. Repository must be a full clone (not shallow) for accurate commit history traversal. |
| Node.js | Yes (collector) | Runtime for the TypeScript collector. |
| OPA | Yes (policy evaluation) | Invoked via `kosli evaluate trail`. |

---

## Attestation schema

The produced attestation (`att_data_<tag>.json`) is consumed by the Rego policy and may also be consumed by downstream controls or audit tooling.

Full TypeScript types are defined in `src/types.ts`. The top-level shape is:

```typescript
{
  repository: string;           // "owner/repo"
  range: {
    base: string;               // base tag or SHA
    current: string;            // current tag or SHA
    base_sha: string;
    current_sha: string;
  };
  generated_at: string;         // ISO-8601
  config: {
    exemptions: {
      serviceAccounts: string[];
    };
  };
  commits: CommitData[];
  pull_requests: Record<string, PRDetails>;
}
```
