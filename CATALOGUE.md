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

The control operationalises this by examining all commits in a release range (the delta between two tags) and verifying that each one was delivered via a pull request, in the evaluated repository, that received at least one independent approval *on the PR's final commit*. There is no exemption by author name: the author name is set by whoever writes the commit.

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

Kosli's `attest pullrequest github` fetches PR data from the GitHub API and stores it as a `pull_request`-type attestation on the trail. The data includes: all commits on the PR branch, all review approvals and the commit each was given on, the head and merge commit SHAs, PR author, and timestamps.

**BASE_TAG auto-resolution:** If `BASE_TAG` is not supplied, the collector walks git history backward from `CURRENT_TAG` and queries `kosli list trails --flow` for the most recent SHA that already has a `pr-review` attestation. This ensures consecutive releases are evaluated contiguously without gaps or overlaps.

**PR attestation data shape (stored in Kosli):**

```json
{
  "pull_requests": [
    {
      "url": "https://github.com/owner/repo/pull/42",
      "author": "alice",
      "merge_commit": "<40-char sha>",
      "head_sha": "<40-char sha of the PR's final commit>",
      "state": "MERGED",
      "commits": [
        {
          "sha1": "<40-char>",
          "author": "Alice Smith <alice@example.com>",
          "author_username": "alice",
          "timestamp": 1770191490,
          "verified": true,
          "signer_username": "alice",
          "signed_by_platform": false
        }
      ],
      "reviews": [
        {
          "username": "bob",
          "timestamp": 1770191600,
          "state": "APPROVED",
          "commit_sha": "<40-char sha the review was given on>",
          "author_type": "user",
          "has_write_access": true
        }
      ]
    }
  ]
}
```

Available to the policy at:
`input.trails[i].compliance_status.attestations_statuses[<name>]`, found by `attestation_type == "pull_request"` rather than by name

---

## Evaluation logic

The Rego policy evaluates all commit trails in a single pass. For each trail it applies checks in order; the first match short-circuits the rest:

```text
For each trail in input.trails:

  1. No pull_requests in pr-review attestation?           → FAIL
  2. No PR in data.params.repository?                     → FAIL
  3. Does any PR commit have an unresolvable identity
     (no author_username), or no verified signature by
     a known account or GitHub?                           → FAIL (identity unverifiable)
  4. Does the PR have an independent approval
     on its final commit?                                 → PASS / FAIL
```

Step 4 detail: "independent approval on the final commit":

- **Merge commit detection**: a commit is the PR merge commit when `trail.name == pr.merge_commit`. This covers squash merges, regular merges, and rebase-merges since all produce a merge commit SHA in the PR data.
- **Author set** for merge commits: the GitHub usernames of PR branch commit authors (`pr.commits[].author_username`) and signers (`pr.commits[].signer_username`). The author fields are set by whoever writes the commit; the signer of a verified signature is the account holding the key. The identity of whoever clicked Merge is excluded.
- **Author set** for non-merge commits: PR branch commit authors and signers plus `pr.author` (the PR creator).
- **Independent**: every username in the author set must have at least one approval from a *different* username.
- **Who can approve**: a review counts as an approval only if its state is `APPROVED`, its author is a person (`author_type` `user`) with write access (`has_write_access`), and the same reviewer has no request for changes or dismissal at the same time or later. Review times are set by GitHub.
- **On the final commit**: every such approval must satisfy `review.commit_sha == pr.head_sha`, the commit the review was given on against the PR's head commit. Commit dates are not used: whoever writes a commit sets them. A PR or approval without these fields gets no approval.
- **Repository**: a PR counts only if its URL is `https://<host>/<owner>/<repo>/pull/<n>` with `<owner>/<repo>` equal to `data.params.repository`, compared case-insensitively. An associated PR elsewhere, such as a fork, doesn't count.
- **Multiple PRs**: if a commit has multiple associated PRs, any single PR with a passing approval is sufficient.

---

## Policy

The policy evaluates a release range by receiving all commit trails together via `kosli evaluate trails SHA1 SHA2 ...`. Each trail in `input.trails` represents one commit. `allow` is `true` only if every trail is compliant.

See `four-eyes.rego` for the full current policy.

---

## Configuration

The policy takes one required param, passed with `kosli evaluate trails --params`. The collector has no config file: all inputs come from environment variables.

| Policy param | Type | Description |
| --- | --- | --- |
| `repository` | `string` | `owner/repo` whose PRs count. Without it, every trail fails with a violation naming the param. |

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

None. Bot and service-account commits need a PR with a human approval, like any other. A bot commit that GitHub links to the bot's account (e.g. `dependabot[bot]`) has an `author_username` and is identified; one with no linked account, such as a `GitHub <noreply@github.com>` co-author entry, is not.

---

## Pass / fail criteria

| Outcome | Condition |
| --- | --- |
| `PASS` | Every commit trail was delivered via a PR in the evaluated repository that received at least one independent approval on its final commit. |
| `FAIL` | At least one trail (a) has no `pr-review` attestation, (b) has a PR commit with an unresolvable identity or no verified signature, (c) has no associated PR in the evaluated repository, or (d) has no independent approval on the PR's final commit, or the `repository` param is missing. The violation message includes the commit SHA (7-char), and PR URL where applicable. |

---

## Scenarios

See [`SCENARIOS.md`](SCENARIOS.md) for the full set of named test cases with diagrams and expected outcomes. Summary of currently evaluated scenarios:

| # | Name | Result |
| --- | --- | --- |
| 1 | Standard PR with independent approval | PASS |
| 2 | Bot or service-account commit without a PR | FAIL |
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

> **Note:** Scenarios 9/10 (post-approval merge-from-base `ignore`/`strict` modes) and scenario 4 (fake merge commit message detection via parent count) are no longer applicable. A merge-from-base commit changes the PR's final commit, so it needs a new approval. Merge commit detection uses `pr.merge_commit` rather than parent count or message text.

---

## Limitations

- **GitHub-only**: PR and approval data is fetched exclusively from the GitHub API via the Kosli CLI. Approvals recorded in external systems (Jira, email, Slack) are invisible to this control.
- **Evidence is a snapshot**: the attestation records the reviews as they were when it ran. A dismissal or request for changes in the attestation withdraws the approval, but one made afterwards isn't seen until the commit is attested again.
- **Author identity requires a linked GitHub account**: if a PR branch commit's `author_username` cannot be resolved by Kosli (absent field), it is flagged as "identity unverifiable". Ensure the GitHub token has sufficient scope.
- **Merge-from-base commits count as code commits**: a `Merge branch 'main' into feature-x` commit pushed after an approval becomes the PR's final commit. The approver must re-approve after such a sync commit.
- **Signed commits required**: an unsigned PR commit fails. GitHub signs commits it makes itself (web edits, merges, and commits a workflow makes through the git-data API or `createCommitOnBranch` without setting an author); for those, the named author is trusted. An API commit whose author the caller sets is left unsigned (tested with a user token and a workflow token), so it fails.
- **Bot commits name the bot, not the person behind it**: a commit made by a workflow is authored by its bot account (`github-actions[bot]`), so the policy requires an approval from someone other than the bot. It can't tell who started the workflow, so that person's own approval still counts. Accepted, because bots and agents contribute more and more.
- **Needs a current Kosli CLI**: the attestation must record `head_sha`, `reviews` and each commit's `verified`, `signer_username` and `signed_by_platform`. Attestations made with an older CLI lack them and get no approval; re-attest.
- **No enforcement at merge time**: this control is evaluated at release time, not at the moment a PR is merged. A violation means the release must be blocked or remediated; it does not prevent the offending merge from happening.

---

## Failure remediation

When the control fails, the violation message identifies the commit SHA and the reason. Typical remediation steps:

1. **No associated PR** — the commit was pushed directly to the default branch. Options: revert the commit and re-deliver via a PR, or obtain a documented exception if the change was an emergency hotfix.
2. **No independent approval** — the PR was approved only by its own authors, or had no approvals. Request review from an independent person and re-run the evaluation after they approve.
3. **Approval not on the final commit**: a reviewer approved before the final code was pushed (including a branch sync commit). Re-request review so the approver can confirm the final state.
4. **Identity unverifiable**: a PR branch commit could not be linked to a GitHub account. Check that the commit was authored via a linked GitHub identity.

---

## False positive guidance

| Pattern | Why it triggers | Resolution |
| --- | --- | --- |
| Developer syncs feature branch with `main` after approval (`Merge branch 'main' into feature-x`) | This merge-from-base commit becomes the PR's final commit, which has no approval | Request re-review after the sync commit, or adopt a workflow that syncs before requesting review |
| Bot commit pushed without a PR | There is no author-name exemption | Deliver bot changes through a PR with a human approval |
| Copilot co-authored commit triggering identity violation | Kosli expands `Co-authored-by: Copilot` into a separate commit entry with `author="GitHub <noreply@github.com>"` and no `author_username` | Not exempt: the author string is set by the committer. Avoid the co-author trailer, or accept the violation and record an exception |
| "no verified signature" violation | A PR commit is unsigned, or signed with a key GitHub can't match to an account | Sign commits with a key registered on the author's GitHub account; require signed commits on the repository |
| All trails fail with "data.params.repository is not set" | The `repository` param was not passed | Add `--params '{"repository": "owner/repo"}'` to `kosli evaluate trails` |

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
| `pull_requests[].url` | `string` | PR URL; its `owner/repo` must match the `repository` param |
| `pull_requests[].merge_commit` | `string` | SHA of the commit that landed on the default branch |
| `pull_requests[].head_sha` | `string \| absent` | SHA of the PR's final commit |
| `pull_requests[].commits[].sha1` | `string` | Full SHA of the PR branch commit |
| `pull_requests[].commits[].author` | `string` | `"Name <email>"` of the git commit author |
| `pull_requests[].commits[].author_username` | `string \| absent` | GitHub username; absent when the identity cannot be resolved |
| `pull_requests[].reviews[].username` | `string` | GitHub username of the reviewer |
| `pull_requests[].reviews[].state` | `string` | `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED` or `DISMISSED` |
| `pull_requests[].reviews[].timestamp` | `number` | Unix epoch seconds when the review was submitted, set by GitHub |
| `pull_requests[].reviews[].author_type` | `string` | `user`, `bot` or `other` |
| `pull_requests[].reviews[].has_write_access` | `bool` | Whether the reviewer can push to the repository, as GitHub reports it when the attestation runs (not when the review was given) |
| `pull_requests[].commits[].verified` | `bool \| absent` | `true` if GitHub verified the commit's signature |
| `pull_requests[].commits[].signer_username` | `string \| absent` | GitHub account behind the signing key |
| `pull_requests[].commits[].signed_by_platform` | `bool \| absent` | `true` if the hosting platform (here GitHub) made the signature with its own key |
| `pull_requests[].reviews[].commit_sha` | `string \| absent` | SHA of the commit the review was given on |

The trail-level `git_commit_info.author` field (set by `kosli begin trail --commit <sha>`) carries the git `author` field of the merge commit as `"Name <email>"`. The policy does not use it.
