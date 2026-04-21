# Plan: Granular Per-Commit Attestation Model

**Date:** 2026-04-21  
**Status:** Draft

---

## Overview

Today never-alone produces one large attestation per release containing every commit and PR in the range. This plan collapses that into one attestation per commit, where each trail is named after the commit SHA. The Rego policy, Kosli trail structure, collector orchestration, schema, and base-tag resolution all change as a consequence.

---

## 1. New trail model

| | Current | New |
| --- | --- | --- |
| Trail unit | Release tag (e.g. `v2.13.1`) | Commit SHA |
| Trail name | Arbitrary (typically commit SHA of tag) | Commit SHA |
| Attestation payload | All commits + all PRs in the range | Single commit + its associated PRs |
| Files written | One `att_data_<tag>.json` | One `att_data_<sha>.json` per commit |

The trail name being the commit SHA is not coincidental — it means `kosli get trail <sha>` is a direct lookup with no guessing, and the git history walk in base-tag resolution becomes authoritative.

---

## 2. New schema: core summary vs. attachment

### 2a. Core schema (`att_data_<sha>.json`)

Vendor-agnostic. Contains only what the Rego policy needs to evaluate this one commit. The raw GitHub/GitLab API payloads move out.

```json
{
  "commit_sha": "<full sha>",
  "repository": "owner/repo",
  "generated_at": "2026-04-21T10:00:00Z",
  "config": {
    "exemptions": {
      "serviceAccounts": ["svc_.*", "dependabot.*"]
    }
  },
  "commit": {
    "sha": "abc1234...",
    "parent_shas": ["parent1"],
    "author": {
      "git_name": "Alice",
      "git_email": "alice@example.com",
      "login": "alice"
    },
    "date": "2026-04-01T09:00:00Z",
    "message": "feat: add payment flow",
    "changed_files": ["src/payment.ts"]
  },
  "pull_requests": [
    {
      "number": 42,
      "url": "https://github.com/owner/repo/pull/42",
      "title": "Add payment flow",
      "state": "closed",
      "merged_at": "2026-04-01T10:30:00Z",
      "author": {
        "login": "alice"
      },
      "approvals": [
        {
          "user": { "login": "bob" },
          "approved_at": "2026-04-01T10:00:00Z"
        }
      ],
      "pr_commits": [
        {
          "sha": "sha_alice_1",
          "parent_shas": ["parent1"],
          "author": {
            "git_name": "Alice",
            "git_email": "alice@example.com",
            "login": "alice",
            "user_id": 1234,
            "web_url": "https://github.com/alice"
          },
          "date": "2026-04-01T09:00:00Z",
          "message": "feat: add payment flow"
        }
      ]
    }
  ]
}
```

**What stays in PR commits (full set, no removals vs. current schema):**

- `sha`, `parent_shas` — needed for merge-from-base detection (`is_merge_from_base`)
- `author.login` — needed for `pr_commit_authors`
- `author.git_name`, `author.git_email` — needed for the "identity unverifiable" violation message and service-account exemption on PR commits
- `author.user_id`, `author.web_url` — kept for traceability and audit links
- `date` — needed for `latest_relevant_commit_ns`
- `message` — kept for audit readability

**What changes at the top level:**

- `commit` (singular object) replaces `commits[]` array
- `pull_requests` becomes an array (was a map keyed by PR number string) — no need for keyed lookup when there is only one commit to match against
- `range` block removed — the trail name is the commit SHA; range is a release-level concept, not a commit-level one
- `commit_sha` added at top level as an explicit identifier (mirrors the trail name)

### 2b. Attachment: raw provider data (`raw_<sha>.json`)

Optional file, attached to the same attestation via `--attachments`. Contains the full API responses for audit and debugging without polluting the schema.

```json
{
  "commit_sha": "<full sha>",
  "provider": "github",
  "generated_at": "...",
  "github_commit": { /* full repos.getCommit response */ },
  "pull_requests": [
    {
      "number": 42,
      "github_pr": { /* full pulls.get response */ },
      "github_reviews": [ /* full pulls.listReviews response items */ ],
      "github_commits": [ /* full pulls.listCommits response items */ ]
    }
  ]
}
```

The attachment is generated alongside the core file but not validated by `jsonschema.json`. It is attached via `--attachments raw_<sha>.json` in the `kosli attest custom` call.

---

## 3. Rego policy changes

### Input path

The policy reads from:

```rego
attestation := input.trail.compliance_status.attestations_statuses["scr-data"].attestation_data
```

This path does not change.

### What changes

The `attestation` object now represents a single commit. The `violations` rules must be rewritten to no longer iterate over `attestation.commits`:

**Current pattern (iterating a range):**

```rego
violations contains msg if {
    some commit in attestation.commits
    not is_service_account(commit)
    count(commit.pr_numbers) == 0
    msg := sprintf("Commit %v ...", [...])
}
```

**New pattern (one commit per attestation):**

```rego
commit := attestation.commit

violations contains msg if {
    not is_service_account(commit)
    count(attestation.pull_requests) == 0
    msg := sprintf("Commit %v ...", [...])
}
```

The `pr_numbers` field on the commit is replaced by `attestation.pull_requests` (the array). `has_any_pr_approval` iterates over that array instead of looking up by number.

**`pr_commit_shas` and `pr_commit_authors`** already operate on a single `pr` object — no change needed.

**`has_any_pr_approval`** becomes:

```rego
has_any_pr_approval if {
    some pr in attestation.pull_requests
    has_independent_approval(commit, pr)
}
```

### Policy scope

Each trail evaluation now answers: *"Is this single commit compliant?"*. A release is compliant if all commit trails in its range are compliant. How that release-level aggregation is expressed in Kosli is an open question — see section 7.

---

## 4. BASE_TAG auto-resolution

### Current algorithm

1. Call `kosli list trails --flow <flow>` (paginated)
2. For each trail: check `trail.git_commit_info.sha1` and whether the trail has the `scr-data` attestation
3. Collect the set of attested SHAs
4. Walk `git log --first-parent CURRENT_TAG`, find the most recent SHA in that set
5. Look up the git tag for that SHA (`git tag --points-at <sha>`), return tag or SHA

### New algorithm

Steps 1–4 are identical — the set of attested SHAs is still derived from `trail.git_commit_info.sha1`. In the new model every trail IS a commit SHA, so the set is even more directly the set of attested commits.

**Step 5 changes:** `getTagForCommit` is no longer called. The resolved SHA is returned directly as the base — it is always a SHA, never a tag name. `git log SHA..CURRENT_TAG` works the same way.

This means `resolveBaseTag` in `baseTagResolver.ts` only needs the removal of the tag-lookup step. The `getTagForCommit` function in `git.ts` can be removed.

### Performance consideration

With per-commit trails there will be many more trails per flow than before (one per commit vs. one per release). Pagination over `kosli list trails` becomes more expensive over time. A future optimisation is to use `kosli get trail <sha> --flow <flow>` as a direct lookup for each SHA in the git history walk — stopping as soon as one is found — rather than pre-fetching the full trail list. This is not required for the initial implementation but should be noted as a follow-up.

---

## 5. Collector and orchestration changes

### `src/reporter.ts`

Replace `generateAttestationData(commits[], pullRequests{}, config, baseSha, currentSha)` with two functions:

```typescript
generateCommitAttestation(commitData: CommitData, pullRequests: PRDetails[], config: Config): void
// writes att_data_<sha>.json

generateRawAttachment(commitData: CommitData, rawPRData: RawPRData[], config: Config): void
// writes raw_<sha>.json
```

The filename uses the full commit SHA: `att_data_<sha>.json`, `raw_<sha>.json`.

### `src/index.ts`

The outer loop changes from **collect-all-then-write-one** to **collect-one-write-one**:

```text
for each commit in git log range:
    collect commit (GitHub API calls)
    write att_data_<sha>.json
    write raw_<sha>.json
    (optionally: attest immediately, or collect files and attest in a second pass)
```

The concurrency model (`pLimit(4)`) can still apply across commits. Each commit's files are written independently before moving on.

### `src/types.ts`

Add new types:

```typescript
export interface CommitAttestation {
  commit_sha: string;
  repository: string;
  generated_at: string;
  config: { exemptions: { serviceAccounts: string[] } };
  commit: CommitData;
  pull_requests: PRSummary[];
}

export interface PRSummary {
  number: number;
  url: string;
  title: string;
  state: string;
  merged_at: string | null;
  author: { login?: string };
  approvals: { user: { login?: string }; approved_at: string }[];
  pr_commits: PRCommitSummary[];
}

export interface PRCommitSummary {
  sha: string;
  parent_shas: string[];
  author: { git_name?: string; git_email?: string; login?: string };
  date: string;
}
```

`CommitData` loses `pr_numbers: number[]` — association is now expressed by which PRs are in the `pull_requests` array of the attestation.

### `src/evaluator.ts`

`collectCommit` currently returns `{ commitData: CommitData, prDetails: PRDetails[] }`. This already matches the new granularity. The internal change is that `prDetails` is split:

- `prDetails` (summary, for core schema) — stripped to `PRSummary`
- `prRaw` (full API response, for attachment)

---

## 6. `jsonschema.json`

Replace the current schema (validated server-side by Kosli's custom attestation type) with a new one matching `CommitAttestation`. Key changes:

- Top-level `commits` array → `commit` object (singular)
- Top-level `pull_requests` map → `pull_requests` array
- `range` block removed
- `commit_sha` added as required top-level field
- `PRDetails.commits[]` → `PRSummary.pr_commits[]` with only the fields the policy needs
- `CommitData` loses `pr_numbers`

The custom attestation type in Kosli must be re-created (or updated) with the new schema using `setup-kosli-attestation-type.sh`.

---

## 7. `simulate.sh` changes

### Inner loop structure

Currently one loop iteration = one tag pair = one trail + one attestation.

New: one loop iteration = one tag pair = multiple commits = multiple trails + multiple attestations.

```bash
for (( i=1; i<${#TAGS[@]}; i++ )); do
  BASE_TAG="${TAGS[$((i-1))]}"
  CURRENT_TAG="${TAGS[$i]}"

  # Get commits in range
  COMMITS=$(git -C "${REPO}" log "${BASE_TAG}..${CURRENT_TAG}" --first-parent --pretty=format:%H)

  for SHA in ${COMMITS}; do
    # 1. Begin trail named by commit SHA
    kosli begin trail "${SHA}" \
      --flow "${KOSLI_FLOW}" \
      --commit "${SHA}" \
      --repo-root "${REPO}"

    # 2. Run collector for this single commit
    COMMIT_SHA="${SHA}" ... node dist/index.js ...

    # 3. Attest core data
    kosli attest custom \
      --type scr-data \
      --name scr-data \
      --attestation-data "att_data_${SHA}.json" \
      --attachments "raw_${SHA}.json" \
      --trail "${SHA}" \
      --flow "${KOSLI_FLOW}"

    # 4. Evaluate this commit's trail
    kosli evaluate trail "${SHA}" \
      --policy four-eyes.rego \
      --flow "${KOSLI_FLOW}" \
      --output json > "eval_result_${SHA}.json" || EVAL_EXIT=$?

    # 5. Attest evaluation result
    kosli attest generic \
      --name four-eyes-result \
      --user-data "eval_result_${SHA}.json" \
      --attachments four-eyes.rego \
      --compliant="${COMPLIANT_FLAG}" \
      --trail "${SHA}" \
      --flow "${KOSLI_FLOW}"
  done
done
```

### Release-level compliance (open question)

With per-commit trails, there is no single trail that represents an entire release. Options:

**Option A — Release trail aggregates commit trails**  
Create a separate release trail (named by tag, e.g. `v2.13.1`) that references all the commit SHAs. The Rego policy for the release trail checks that each commit trail is compliant. Requires Kosli to support trail cross-references.

**Option B — Evaluate at the flow level**  
A release is compliant if all commit trails in the range have a passing `four-eyes-result` attestation. `simulate.sh` iterates and fails the release if any per-commit evaluation failed.

**Option C — Release-summary attestation**  
After processing all commits in a range, create one more attestation (on a release trail) that is a JSON list of `{ sha, compliant }` entries — a simple roll-up. The release Rego policy checks all are compliant.

The simplest path for the initial implementation is **Option B**: the script tracks `OVERALL_COMPLIANT` and sets it to `false` on any per-commit violation. No new trail type is needed.

---

## 8. Collector input: new environment variable

`CURRENT_TAG` currently drives the range. In per-commit mode the collector processes one commit at a time. The CLI interface should accept either:

- `COMMIT_SHA` — process exactly this one commit (new per-commit mode)
- `BASE_TAG` + `CURRENT_TAG` — process the range (batch mode, backward-compatible)

When `COMMIT_SHA` is provided, the range logic is skipped and only that commit is collected. `simulate.sh` would set `COMMIT_SHA` in the inner loop.

---

## 9. File naming convention

| Artifact | New name |
| --- | --- |
| Core attestation | `att_data_<full_sha>.json` |
| Raw attachment | `raw_<full_sha>.json` |
| Evaluation result | `eval_result_<full_sha>.json` |

Using the full SHA (not short) avoids collision risk and matches Kosli trail names exactly.

---

## 10. Open questions

1. **Release-level compliance** — which option (A/B/C above) to implement first?
2. **Collector mode** — keep batch mode (`BASE_TAG..CURRENT_TAG`) alongside per-commit mode, or deprecate it immediately?
3. **Kosli trail API** — does `kosli get trail <sha>` support direct lookup without pagination? If yes, the base-tag resolver can skip the full list fetch and do point lookups instead (much cheaper at scale).
4. **Attachment format** — is one `raw_<sha>.json` file enough, or should each PR have its own attachment file?
5. **Custom attestation type update** — the existing `scr-data` type in Kosli must be re-created with the new schema. Is there a non-destructive update path, or does old data need to remain readable under the old type?
