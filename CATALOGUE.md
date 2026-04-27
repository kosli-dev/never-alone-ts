# SCR-01 — Four-Eyes Source Code Review

| Field | Value |
| --- | --- |
| **ID** | SCR-01 |
| **Name** | Four-Eyes Source Code Review |
| **Category** | Source Code Integrity |
| **Version** | 2.0 |
| **Status** | Active |
| **Policy engine** | OPA / Rego v1 |
| **Policy file** | `four-eyes.rego` |
| **Collector** | TypeScript CLI (`src/index.ts`) |

---

## Intent

Every code change that reaches a production release must have been reviewed and approved by at least one person other than its author before it was merged. This is the *four-eyes principle* — no single developer should be able to land unreviewed code unilaterally.

The control operationalises this by examining all commits in a release range (the delta between two tags) and verifying that each one either:

- was authored by an automated agent (service account) that is trusted by policy, or
- was delivered via a pull request that received at least one independent approval *after* the last code commit in that PR.

The merge commit that lands on the default branch is identified via `pr.merge_commit`. Its author is excluded from the author set — the person who clicked Merge was executing a merge rather than contributing code. Approval is required from someone who did not author any PR branch commit.

A violation means a commit reached the release that was not subject to independent review at any point in its lifecycle.

---

## Regulatory mapping

| Framework | Clause | Why it fits |
| --- | --- | --- |
| NIST 800-53 | CM-5(4) Dual Authorization | Directly requires two separate parties to authorize a change — the control enforces exactly this by rejecting self-approved commits |
| NIST 800-53 | AC-5 Separation of Duties | The author/approver independence check is a textbook SoD enforcement at the code change level |
| NIST 800-53 | AU-12 Audit Record Generation | The PR attestation artifact is a per-commit audit record of who authorized each change and when |
| ISO 27001 (2022) | 5.3 Segregation of Duties | Prevents any single person from both authoring and approving their own change; the control produces evidence this was upheld |
| ISO 27001 (2022) | 8.25 Secure Development Life Cycle | The control is embedded in the CI/CD pipeline as a security gate over source code changes |
| ISO 27001 (2022) | 8.32 Change Management | Produces documented, timestamped authorization evidence for each change entering a release |
| ISO 20000-1 | 7.5 Change Management (authorization sub-clause) | Satisfies the requirement that changes are authorized by an appropriate authority before deployment |
| DORA | Article 17 — ICT Change Management | Provides retained, machine-readable evidence that each ICT change was approved by an authority independent of the author |
| DORA | Article 9(2) — Protection and Prevention | Enforces access restriction: no actor can unilaterally push a change to production without an independent approver |

---

## Data collection

The collector is a TypeScript CLI that runs in CI against a specific release range (`BASE_TAG`..`CURRENT_TAG`). It delegates all GitHub API calls to the Kosli CLI.

```text
git log --first-parent BASE_TAG..CURRENT_TAG
         │
         ▼
  For each commit on main (up to 4 in parallel):
    1. kosli begin trail <sha>
         --flow <flow> --commit <sha> --repo-root <path>
    2. kosli attest pullrequest github
         --name pr-review --commit <sha>
         --github-token <token> --github-org <org>
         --repository <owner/repo> --flow <flow> --trail <sha>
```

Kosli's `attest pullrequest github` fetches PR data from the GitHub API and stores it as a `pull_request`-type attestation on the trail. The data includes: all commits on the PR branch, all review approvals, merge commit SHA, PR author, and timestamps.

**BASE_TAG auto-resolution:** If `BASE_TAG` is not supplied, the collector walks git history backward from `CURRENT_TAG` and queries `kosli list trails --flow` for the most recent SHA that already has a `pr-review` attestation. This ensures consecutive releases are evaluated contiguously without gaps or overlaps.

**PR attestation data shape (stored in Kosli):**

```json
{
  "pull_requests": [
    {
      "url": "https://github.com/owner/repo/pull/42",
      "author": "alice",
      "merge_commit": "<40-char sha>",
      "state": "MERGED",
      "commits": [
        {
          "sha1": "<40-char>",
          "author": "Alice Smith <alice@example.com>",
          "author_username": "alice",
          "timestamp": 1770191490
        }
      ],
      "approvers": [
        {
          "username": "bob",
          "timestamp": 1770191600,
          "state": "APPROVED"
        }
      ]
    }
  ]
}
```

Available to the policy at:
`input.trails[i].compliance_status.attestations_statuses["pr-review"]`

---

## Evaluation logic

The Rego policy evaluates all commit trails in a single pass. For each trail it applies checks in order; the first match short-circuits the rest:

```text
For each trail in input.trails:

  1. Is trail.git_commit_info.author a service account?   → PASS (exempt)
  2. Does any PR commit have an unresolvable identity
     (no author_username) and is not a web-flow commit?  → FAIL (identity unverifiable)
  3. No pull_requests in pr-review attestation?          → FAIL
  4. PR found — does it have an independent approval
     after the latest code commit?                       → PASS / FAIL
```

Step 4 detail — "independent approval after latest code commit":

- **Merge commit detection**: a commit is the PR merge commit when `trail.name == pr.merge_commit`. This covers squash merges, regular merges, and rebase-merges since all produce a merge commit SHA in the PR data.
- **Author set** for merge commits: only the GitHub usernames of PR branch commit authors (`pr.commits[].author_username`). The identity of whoever clicked Merge is excluded.
- **Author set** for non-merge commits: PR branch commit authors plus `pr.author` (the PR creator).
- **Independent**: every username in the author set must have at least one approval from a *different* username.
- **After**: every such approval must satisfy `approver.timestamp > max(pr.commits[].timestamp)` (Unix epoch seconds).
- **Web-flow commits**: PR commits where `author` contains a service account pattern (e.g. `GitHub <noreply@github.com>`) and `author_username` is absent are treated as system-generated (GitHub web-flow, Copilot co-author expansions) and excluded from both the identity check and the author set.
- **Multiple PRs**: if a commit has multiple associated PRs, any single PR with a passing approval is sufficient.

---

## Policy

The policy evaluates a release range by receiving all commit trails together via `kosli evaluate trails SHA1 SHA2 ...`. Each trail in `input.trails` represents one commit. `allow` is `true` only if every trail is compliant.

Service account patterns are defined as a constant in `four-eyes.rego` — not in the attestation data. To add an exemption, edit `service_account_patterns` in the policy file.

See `four-eyes.rego` for the full current policy. Key constant:

```rego
# Service accounts exempt from the four-eyes check.
# Matched against trail.git_commit_info.author ("Name <email>" string).
# Also matched against pr.commits[].author to exempt web-flow/Copilot entries.
service_account_patterns := {
    "svc_.*",       # organisation service account prefix
    ".*\\[bot\\]",  # any GitHub App bot (dependabot, github-actions, ci-signed-commit-bot, etc.)
    "noreply@github.com",  # GitHub web-flow and Copilot co-author entries
}
```

---

## Configuration

Policy constants are set directly in `four-eyes.rego`. The collector has no config file — all inputs come from environment variables.

| Policy constant | Type | Default | Description |
| --- | --- | --- | --- |
| `service_account_patterns` | `set[string]` | see above | Regex patterns matched against `trail.git_commit_info.author` and PR commit `author` fields. Trails with a matching author are fully exempt. Edit in `four-eyes.rego`. |

**Environment variables (collector):**

| Variable | Required | Description |
| --- | --- | --- |
| `CURRENT_TAG` | Yes | Git tag or SHA marking the end of the release range |
| `GITHUB_REPOSITORY` | Yes | `owner/repo` format |
| `GITHUB_TOKEN` | Yes | GitHub PAT with `repo` scope |
| `KOSLI_FLOW` | Yes | Kosli flow name for trail creation and `BASE_TAG` auto-resolution |
| `BASE_TAG` | No | Start of release range; auto-resolved from Kosli if omitted |
| `KOSLI_ATTESTATION_NAME` | No | Name of the PR attestation in Kosli (default: `pr-review`) |

**Kosli CLI environment variables** (consumed directly by the Kosli CLI, not the collector):

| Variable | Required | Description |
| --- | --- | --- |
| `KOSLI_API_TOKEN` | Yes | Kosli API token |
| `KOSLI_ORG` | Yes | Kosli organisation name |

---

## Exemptions

| Exemption type | Condition | Rationale |
| --- | --- | --- |
| Service account (trail) | `trail.git_commit_info.author` matches a regex in `service_account_patterns` | Automated commits (dependency updates, release scripts, CI bots) are not human-authored and cannot have a human reviewer. The service account credential is the control gate. |
| Web-flow PR commit | A PR branch commit's `author` field matches a service account pattern and `author_username` is absent | GitHub web-flow commits and Copilot co-author expansions carry no resolvable GitHub identity. They are excluded from the author set and identity checks, while the human co-author's approval requirement still applies. |

---

## Pass / fail criteria

| Outcome | Condition |
| --- | --- |
| `PASS` | Every commit trail is either exempt, or was delivered via a PR that received at least one independent approval after its last code change. |
| `FAIL` | At least one trail is not exempt and either (a) has no `pr-review` attestation, (b) has a PR commit with an unresolvable identity, (c) has no associated PR, or (d) has no independent approval post-dating all code commits. The violation message includes the commit SHA (7-char), and PR URL where applicable. |

---

## Scenarios

See [`SCENARIOS.md`](SCENARIOS.md) for the full set of named test cases with diagrams and expected outcomes. Summary of currently evaluated scenarios:

| # | Name | Result |
| --- | --- | --- |
| 1 | Standard PR with independent approval | PASS |
| 2 | Service account commit | PASS |
| 3 | Merge commit — identified via `pr.merge_commit` | PASS |
| 5 | Commit pushed directly to main — no PR | FAIL |
| 6 | PR exists but has no approvals | FAIL |
| 7 | Self-approval only | FAIL |
| 8 | New code pushed after approval | FAIL |
| 11 | Multiple commits — only failing ones reported | FAIL (partial) |
| 13 | Multi-author PR — cross-approval | PASS |
| 14 | Multi-author PR — only one committer approves | FAIL |
| 16 | Two PRs in range — both independently approved | PASS |
| 17 | Two PRs in range — one is self-approved | FAIL |

> **Note:** Scenarios 9/10 (post-approval merge-from-base `ignore`/`strict` modes) and scenario 4 (fake merge commit message detection via parent count) are no longer applicable. Merge-from-base commits are counted in the approval timestamp cutoff. Merge commit detection uses `pr.merge_commit` rather than parent count or message text.

---

## Limitations

- **GitHub-only**: PR and approval data is fetched exclusively from the GitHub API via the Kosli CLI. Approvals recorded in external systems (Jira, email, Slack) are invisible to this control.
- **Approval dismissal not tracked**: if a review approval was later dismissed, the Kosli `pr-review` attestation captures a snapshot at attestation time. The control's own timestamp comparison is the primary safeguard against stale approvals.
- **Author identity requires a linked GitHub account**: if a PR branch commit's `author_username` cannot be resolved by Kosli (absent field), and the commit is not recognised as a web-flow commit, it is flagged as "identity unverifiable". Ensure the GitHub token has sufficient scope.
- **Merge-from-base commits count as code commits**: a `Merge branch 'main' into feature-x` commit pushed after an approval raises the cutoff timestamp. The approver must re-approve after such a sync commit.
- **No enforcement at merge time**: this control is evaluated at release time, not at the moment a PR is merged. A violation means the release must be blocked or remediated; it does not prevent the offending merge from happening.

---

## Failure remediation

When the control fails, the violation message identifies the commit SHA and the reason. Typical remediation steps:

1. **No associated PR** — the commit was pushed directly to the default branch. Options: revert the commit and re-deliver via a PR, or obtain a documented exception if the change was an emergency hotfix.
2. **No independent approval** — the PR was approved only by its own authors, or had no approvals. Request review from an independent person and re-run the evaluation after they approve.
3. **Approval predates latest commit** — a reviewer approved before the final code was pushed (including a branch sync commit). Re-request review so the approver can confirm the final state.
4. **Identity unverifiable** — a PR branch commit could not be linked to a GitHub account. Check that the commit was authored via a linked GitHub identity, or add the committer pattern to `service_account_patterns` if it is a known system account.

---

## False positive guidance

| Pattern | Why it triggers | Resolution |
| --- | --- | --- |
| Developer syncs feature branch with `main` after approval (`Merge branch 'main' into feature-x`) | This merge-from-base commit post-dates the approval, raising the cutoff timestamp | Request re-review after the sync commit, or adopt a workflow that syncs before requesting review |
| Bot commits not matching any `service_account_patterns` entry | The author string is not in the exemption set | Add a regex matching the bot's `Name <email>` string to `service_account_patterns` in `four-eyes.rego` |
| Copilot co-authored commit triggering identity violation | Kosli expands `Co-authored-by: Copilot` into a separate commit entry with `author="GitHub <noreply@github.com>"` and no `author_username` | The `noreply@github.com` service account pattern exempts these entries; ensure it is present in `service_account_patterns` |

---

## Dependencies

| Dependency | Required | Notes |
| --- | --- | --- |
| GitHub API | Yes (via Kosli CLI) | REST API v3. PAT must have `repo` scope (or `public_repo` for public repositories). The Kosli CLI handles rate limiting and retries. |
| Kosli CLI | Yes | `kosli` must be on `PATH`. `KOSLI_ORG` and `KOSLI_API_TOKEN` must be set. Used for trail creation, PR attestation, trail listing, and policy evaluation. |
| Git | Yes | `git` must be on `PATH`. Repository must be a full clone (not shallow) for accurate commit history traversal. |
| Node.js | Yes (collector) | Runtime for the TypeScript collector. |
| OPA | Yes (policy evaluation) | Invoked via `kosli evaluate trails`. |

---

## PR attestation schema reference

The `pr-review` attestation is a built-in Kosli `pull_request` type populated by `kosli attest pullrequest github`. Key fields used by the policy:

| Field path | Type | Description |
| --- | --- | --- |
| `pull_requests[].author` | `string` | GitHub username of the PR creator |
| `pull_requests[].merge_commit` | `string` | SHA of the commit that landed on the default branch |
| `pull_requests[].commits[].sha1` | `string` | Full SHA of the PR branch commit |
| `pull_requests[].commits[].author` | `string` | `"Name <email>"` of the git commit author |
| `pull_requests[].commits[].author_username` | `string \| absent` | GitHub username; absent when the identity cannot be resolved |
| `pull_requests[].commits[].timestamp` | `number` | Unix epoch seconds of the commit |
| `pull_requests[].approvers[].username` | `string` | GitHub username of the reviewer |
| `pull_requests[].approvers[].timestamp` | `number` | Unix epoch seconds when the approval was submitted |

The trail-level `git_commit_info.author` field (set by `kosli begin trail --commit <sha>`) carries the git `author` field of the merge commit as `"Name <email>"` and is used for service account detection.
