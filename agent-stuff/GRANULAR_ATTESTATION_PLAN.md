# Plan: Granular Per-Commit Attestation Model

**Date:** 2026-04-21  
**Status:** In Progress

---

## Overview

Today never-alone produces one large attestation per release containing every commit and PR in the range. This plan collapses that into one attestation per commit, where each trail is named after the commit SHA. The Rego policy, Kosli trail structure, collector orchestration, schema, and base-tag resolution all change as a consequence.

---

## 1. New trail model

> **IMPLEMENTED** — `simulate_granular.sh` creates one trail per commit SHA. Confirmed working against `kosli-dev/cli` for all 9 tag pairs (46 commit trails created).

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

> **IMPLEMENTED** — Written by `generateGranularAttestation()` in `src/reporter.ts`. Types defined in `src/types.ts` (`CommitAttestation`, `PRSummary`, `PRCommitSummary`). Field name `pr_commits` confirmed from live Kosli input inspection.

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

> **IMPLEMENTED** — Written by `generateGranularAttestation()` alongside the core file. Attached via `--attachments raw_<sha>.json` in `simulate_granular.sh`.

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

The attachment is generated alongside the core file but not validated by `jsonschema.json`. It is attached via `--attachments raw_<sha>.json` in the `kosli attest` call.

---

## 3. Rego policy changes

> **IMPLEMENTED** — `four-eyes.rego` rewritten. Confirmed working: 8/9 tag pairs PASS, `v2.11.44..v2.11.45` correctly FAILs on PR #666 (no independent approval after latest code commit).

### Input path

> **FINDING** — The input path depends on attestation type. Since `simulate_granular.sh` currently uses `attest generic` (not `attest custom`), the data is under `.user_data`. When the custom attestation type is updated (see section 6), it will move to `.attestation_data`.

The policy uses a helper function rather than a global assignment, so the path is in one place to update:

```rego
trail_data(trail) := trail.compliance_status.attestations_statuses["scr-data"].user_data
# Change to .attestation_data once kosli attest custom is restored
```

The command used is `kosli evaluate trails` (plural), not `evaluate trail`. Input is `input.trails` (array), not `input.trail` (single object).

### What changed vs. the old policy

The `attestation` global is gone. The `violations` rules now iterate over trails:

**Old pattern (single trail, iterating commits array):**

```rego
attestation := input.trail.compliance_status.attestations_statuses["scr-data"].attestation_data

violations contains msg if {
    some commit in attestation.commits          # <-- iterated commits array
    not is_service_account(commit)             # <-- attestation implicit via global
    count(commit.pr_numbers) == 0
    msg := sprintf("Commit %v ...", [...])
}
```

**New pattern (multiple trails, one commit per trail):**

```rego
trail_data(trail) := trail.compliance_status.attestations_statuses["scr-data"].user_data

violations contains msg if {
    some trail in input.trails                 # <-- iterate trails
    attestation := trail_data(trail)
    commit := attestation.commit               # <-- singular commit object
    not is_service_account(commit, attestation) # <-- attestation passed explicitly
    count(attestation.pull_requests) == 0
    msg := sprintf("Commit %v ...", [...])
}
```

**Other changes:**

- `is_service_account(commit)` → `is_service_account(commit, attestation)` — attestation threaded as parameter since there is no global
- `has_any_pr_approval(commit)` → `has_any_pr_approval(commit, attestation)` — same reason
- `pr.commits` → `pr.pr_commits` everywhere — field renamed in new schema (confirmed from live input)
- `commit.pr_numbers` check gone — replaced by `count(attestation.pull_requests) == 0`
- Missing-attestation violation uses `trail.name` to identify which trail is missing it

### Policy scope

Each trail in `input.trails` represents one commit. One call to `kosli evaluate trails SHA1 SHA2 ...` evaluates the entire release range. `allow` is `true` only if all commits across all trails are compliant.

---

## 4. BASE_TAG auto-resolution

> **IMPLEMENTED** — Auto-resolution confirmed working in simulation run 2026-04-21. Iterations 2–9 all print "Auto-resolving base tag using Kosli flow: …" and resolve to the correct SHA. The shell script passes `BASE_TAG` explicitly only for the first iteration; subsequent iterations omit it and rely on `KOSLI_FLOW`.

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

> **IMPLEMENTED** — The following files were updated:
>
> - `src/types.ts` — `CommitSummary`, `PRSummary`, `PRCommitSummary`, `CommitAttestation`, `RawPRData`, `RawAttachment` added
> - `src/git.ts` — `getSingleCommit(sha, repoPath)` added
> - `src/github.ts` — `getPRSummaryAndRaw()` and `getRawCommitData()` added (each with their own cache)
> - `src/evaluator.ts` — `collectCommitGranular()` added to `Collector` class
> - `src/reporter.ts` — `generateGranularAttestation()` added (writes both `att_data_<sha>.json` and `raw_<sha>.json`)
> - `src/config.ts` — `loadGranularConfig()` added (requires only `GITHUB_REPOSITORY` + `GITHUB_TOKEN`)
> - `src/index.ts` — `--commit <sha>` flag activates single-commit granular path; range mode also replaced to write granular files per commit (parallelised with `pLimit(4)`). `--resolve-base` flag removed; `generateAttestationData` and old batch path removed.
> - `tests/baseTagResolver.test.ts` — updated: removed tag-lookup expectations; `resolveBaseTag` now always returns SHA directly.

### `src/reporter.ts`

Two new functions replace `generateAttestationData` for the granular path:

```typescript
generateGranularAttestation(commitSummary, pullRequests, rawData, config): void
// writes att_data_<sha>.json  (core)
// writes raw_<sha>.json       (attachment)
```

The filename uses the full commit SHA: `att_data_<sha>.json`, `raw_<sha>.json`.

### `src/index.ts`

Two modes:

```text
--commit <sha> provided:
    loadGranularConfig()         (GITHUB_REPOSITORY + GITHUB_TOKEN only)
    getSingleCommit(sha)         (git show for that one commit)
    collectCommitGranular()      (GitHub API calls)
    generateGranularAttestation() (writes both output files)

no --commit flag (range mode):
    loadConfig()                 (CURRENT_TAG + GITHUB_REPOSITORY + GITHUB_TOKEN)
    if KOSLI_FLOW set and BASE_TAG empty → resolveBaseTag() auto-resolves from flow
    getCommits(base, current)    (git log --first-parent)
    for each commit (pLimit 4):
        collectCommitGranular()
        generateGranularAttestation()  (writes att_data_<sha>.json + raw_<sha>.json)
```

`--resolve-base` flag removed — base resolution is now an internal detail of range mode.

### `src/types.ts`

New types added (existing types unchanged for backward compatibility):

```typescript
CommitSummary      // CommitData without pr_numbers
PRCommitSummary    // PR commit with full UserIdentity + message
PRSummary          // PR in new model — pr_commits array, not keyed map
CommitAttestation  // top-level type for att_data_<sha>.json
RawPRData          // raw API data for one PR
RawAttachment      // top-level type for raw_<sha>.json
```

### `src/evaluator.ts`

`collectCommitGranular(commit: CommitInfo)` added alongside existing `collectCommit`. Uses `getRawCommitData` instead of `getCommitDetails` to get the full GitHub commit response (from which author identity is extracted before storing the raw payload).

---

## 6. `jsonschema.json`

> **IMPLEMENTED** — Schema updated to match `CommitAttestation`. `scr-data` attestation type re-created in Kosli via `setup-kosli-attestation-type.sh`. `simulate_granular.sh` switched to `kosli attest custom --attestation-data`. `four-eyes.rego` updated to `.attestation_data`. Confirmed working: same 8 PASS / 1 FAIL results, now with server-side schema validation active.

Key changes from old schema:

- Top-level `commits` array → `commit` object (singular)
- Top-level `pull_requests` map → `pull_requests` array
- `range` block removed
- `commit_sha` added as required top-level field
- `PRDetails.commits[]` → `PRSummary.pr_commits[]` (field renamed; `message` added)
- `CommitData.pr_numbers` removed
- `UserIdentity.login`, `user_id`, `web_url` declared as `oneOf [string/integer, null]` to allow null when GitHub identity can't be resolved

`setup-kosli-attestation-type.sh` updated to delete (if exists) and re-create — so it can be re-run after any future schema change.

**Kosli flag discovery:** `attest custom` requires `--attestation-data` (not `--user-data`). The data lands in `.attestation_data` in the Rego input, not `.user_data`.

---

## 7. `simulate_granular.sh`

> **IMPLEMENTED** — `simulate_granular.sh` fully active. Collector runs once per tag pair in range mode (not per-commit). Per-commit inner loop handles only Kosli trail operations. Evaluation runs at the outer loop level after all commits in the range are attested. Confirmed working across all 9 tag pairs.

### Structure

One outer loop iteration = one tag pair.

```bash
for (( i=1; i<${#TAGS[@]}; i++ )); do
  BASE_TAG="${TAGS[$((i-1))]}"
  CURRENT_TAG="${TAGS[$i]}"

  # 1. Run collector once for the entire range → writes att_data_<sha>.json + raw_<sha>.json
  #    First iteration: explicit BASE_TAG. Subsequent: omit BASE_TAG, auto-resolve via KOSLI_FLOW.
  if [[ $i -eq 1 ]]; then
    BASE_TAG=... CURRENT_TAG=... KOSLI_FLOW=... node dist/index.js --repo ... --config ...
  else
    CURRENT_TAG=... KOSLI_FLOW=... node dist/index.js --repo ... --config ...
  fi

  # 2. Get commits in range for Kosli operations (shell uses explicit tag pair)
  COMMITS=$(git -C "${REPO}" log "${BASE_TAG}..${CURRENT_TAG}" --first-parent --pretty=format:%H)

  while IFS= read -r SHA; do
    # 3. Begin trail named by commit SHA
    kosli begin trail "${SHA}" --flow "${KOSLI_FLOW}" --commit "${SHA}" --repo-root "${REPO}"

    # 4. Attest core data + raw attachment (schema-validated)
    kosli attest custom --type scr-data --name scr-data \
      --attestation-data "att_data_${SHA}.json" \
      --attachments "raw_${SHA}.json" --trail "${SHA}" --flow "${KOSLI_FLOW}"
  done <<< "${COMMITS}"

  # 5. Evaluate all commit trails in the release range together
  CURRENT_SHA=$(git -C "${REPO}" rev-parse "${CURRENT_TAG}^{commit}")
  TRAIL_LIST=$(echo "${COMMITS}" | tr '\n' ' ')
  kosli evaluate trails ${TRAIL_LIST} --policy four-eyes.rego --flow "${KOSLI_FLOW}" --output json \
    > "eval_result_${CURRENT_TAG}.json" 2>/dev/null || true

  # 6. Attest evaluation result to the current tag's commit trail
  #    CURRENT_SHA is always the topmost commit in the range — its trail was begun in the inner loop.
  kosli attest generic --name four-eyes-result \
    --user-data "eval_result_${CURRENT_TAG}.json" \
    --trail "${CURRENT_SHA}" --flow "${KOSLI_FLOW}"
done
```

### Release-level evaluation

> **DESIGN DECIDED** — `kosli evaluate trails` (plural) is the mechanism. It takes the full list of commit SHAs in the release range as positional arguments and runs the Rego policy once with `input.trails` containing all of them. One call per release (at the outer loop level), not one call per commit.

### Evaluation attestation placement

> **IMPLEMENTED** — The evaluation result (`eval_result_<tag>.json`) is attested as a `four-eyes-result` generic attestation to the trail of `CURRENT_TAG`'s commit SHA. That trail already exists from the inner loop. This means the topmost commit in any release range carries both its own `scr-data` attestation and the release-level `four-eyes-result`. Confirmed working for all 9 tag pairs including the FAIL case (`v2.11.44→v2.11.45`).

---

## 8. Collector input: `--commit` flag

> **IMPLEMENTED** — `--commit <sha>` flag added to `src/index.ts`. When set, `loadGranularConfig()` is used (no `CURRENT_TAG` or `KOSLI_FLOW` required) and the single-commit granular path runs. Range mode also rewired to produce granular files per commit; old `generateAttestationData` batch path removed.

The CLI supports two modes:

- `--commit <sha>` — process exactly one commit (for external orchestrators that manage the loop)
- _(no --commit)_ + `CURRENT_TAG` env var — range mode: collect and write granular files for every commit in `BASE_TAG..CURRENT_TAG` (auto-resolving base from `KOSLI_FLOW` if `BASE_TAG` unset)

---

## 9. File naming convention

> **IMPLEMENTED**

| Artifact | Name |
| --- | --- |
| Core attestation | `att_data_<full_sha>.json` |
| Raw attachment | `raw_<full_sha>.json` |
| Evaluation result | `eval_result_<tag>.json` — attested to CURRENT_TAG's commit trail as `four-eyes-result` |

Using the full SHA (not short) avoids collision risk and matches Kosli trail names exactly.

---

## 10. Open questions

1. **Release-level compliance** — ~~which option (A/B/C above) to implement first?~~ **ANSWERED:** `kosli evaluate trails SHA1 SHA2 ...` takes the full range of SHAs in one call. The Rego sees `input.trails` (array). This is effectively Option B from the original list but implemented natively by the Kosli CLI rather than by shell script aggregation.

2. **Collector mode** — **ANSWERED:** Batch mode kept alongside per-commit mode. `--commit` activates granular; omitting it falls back to the existing range path.

3. **Kosli trail API** — Does `kosli get trail <sha>` support direct lookup without pagination? If yes, the base-tag resolver can skip the full list fetch and do point lookups instead (much cheaper at scale). **Still open.**

4. **Attachment format** — **ANSWERED:** One `raw_<sha>.json` file per commit, containing all PR raw data nested inside. Confirmed sufficient.

5. **Custom attestation type update** — **ANSWERED:** `jsonschema.json` updated, `scr-data` type re-created, `attest custom --attestation-data` in use, `four-eyes.rego` updated to `.attestation_data`. Schema validation confirmed active. `setup-kosli-attestation-type.sh` now handles delete-and-recreate so it's idempotent.

---

## 11. Simulation results (2026-04-21)

Flow `cli-granular-demo-20260421124227` — 9 tag pairs, all 9 evaluated:

| Range | Result | Note |
| --- | --- | --- |
| v2.11.41 → v2.11.42 | PASS | 4 commits |
| v2.11.42 → v2.11.43 | PASS | 3 commits, base auto-resolved to `a7573bc` |
| v2.11.43 → v2.11.44 | PASS | 5 commits |
| v2.11.44 → v2.11.45 | **FAIL** | PR #666 — no independent approval after latest code commit |
| v2.11.45 → v2.11.46 | PASS | 2 commits |
| v2.11.46 → v2.12.0 | PASS | 5 commits |
| v2.12.0 → v2.12.1 | PASS | 10 commits |
| v2.12.1 → v2.13.0 | PASS | 10 commits |
| v2.13.0 → v2.13.1 | PASS | 1 commit |

Auto-resolution picked up the most recent attested SHA each time — not the nominal tag boundary — confirming that `resolveBaseTag` correctly avoids re-attesting commits across release boundaries.

---

## 12. Unanswered questions from implementation session (2026-04-21)

1. **`--attestations` flag on `kosli evaluate trails`** — The docs show the flag (e.g. `--attestations pull-request`) but we ran all evaluations without it and the `user_data` was still present in `input.trails[i]`. It is unclear what the flag actually changes about the input: does it filter which attestations are included, enrich them with additional data, or is it only needed for artifact-level attestations? Needs a test with `--show-input` comparing with and without the flag.

2. **`kosli get trail <sha>` direct lookup** — Does the Kosli CLI support fetching a single trail by name without paginating the full trail list? If it does, `baseTagResolver.ts` can be rewritten to walk the git history and do a point lookup per SHA (stopping at the first hit) rather than pre-fetching all trails. This matters for flows that accumulate thousands of per-commit trails over time.

3. **`attest custom` vs `attest generic` and the Rego path** — **ANSWERED:** `attest custom` requires `--attestation-data` (not `--user-data`). The payload lands at `.attestation_data` in the Rego input. The existing type cannot be updated in place — `kosli delete attestation-type` + `kosli create attestation-type` is required. `setup-kosli-attestation-type.sh` now handles this idempotently. All three switches (schema, type, Rego path) are done and confirmed working.
