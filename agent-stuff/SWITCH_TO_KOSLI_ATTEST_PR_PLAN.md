# Plan: Switch to `kosli attest pullrequest github`

## Goal

Replace the TypeScript-based GitHub data collection pipeline with Kosli's built-in
`kosli attest pullrequest github` command. The TypeScript evaluator, reporter, GitHub
client, and most config/types code is eliminated. The base-tag resolver is kept as a
thin CLI utility. The Rego policy is rewritten to use the new attestation schema.

---

## Part 1: Base Tag Resolution

### Current

`baseTagResolver.ts` calls `kosli list trails --flow` (with pagination via `kosli.ts`),
builds a set of attested SHAs, then walks git history backward from `currentTag` to find
the most recently attested commit.

### What changes

Nothing in the resolver logic — only the attestation name it searches for changes from
`"scr-data"` to `"pr-review"` (controlled by `KOSLI_ATTESTATION_NAME` env var, which
already defaults correctly once the default is updated).

Confirmed: `kosli list trails` returns `attestations_statuses` as an array with
`attestation_name: "pr-review"` — exactly what `kosli.ts` already checks.

### TypeScript surface area that survives

| File | Status | Reason |
|---|---|---|
| `kosli.ts` | keep | paginates `list trails`, checks `attestation_name` in array |
| `baseTagResolver.ts` | keep | walks git history, finds first attested SHA |
| `git.ts` | keep (trimmed) | `getCommitHistory` + `getInitialCommit` still used by resolver |
| `types.ts` | shrink | only `KosliTrail` survives; all PR/commit types removed |
| `config.ts` | shrink | only `KOSLI_FLOW` + repo path needed; GitHub vars removed |
| `index.ts` | rewrite | becomes a thin base-SHA resolver CLI (see below) |
| `evaluator.ts` | **delete** | replaced by `kosli attest pullrequest github` |
| `reporter.ts` | **delete** | no more `att_data_*.json` / `raw_*.json` files |
| `github.ts` | **delete** | Kosli handles GitHub API calls |

### New `index.ts`

```typescript
// Prints the resolved base SHA to stdout.
// Usage: KOSLI_FLOW=<flow> [KOSLI_ATTESTATION_NAME=pr-review] \
//          node dist/index.js --repo /path/to/repo [--ref <tag-or-sha>]

const flow = process.env.KOSLI_FLOW!;
const repoPath = args.repo ?? process.cwd();
const ref = args.ref ?? 'HEAD';
const attestationName = process.env.KOSLI_ATTESTATION_NAME ?? 'pr-review';

const base = await resolveBaseTag(flow, attestationName, ref, repoPath);
process.stdout.write(base + '\n');
```

---

## Part 2: Attested Data Shape

### Old (`scr-data` custom attestation)

Attested via `kosli attest custom --type scr-data --attestation-data att_data_<sha>.json`.

Accessible in Rego at:
```
trail.compliance_status.attestations_statuses["scr-data"].attestation_data
```

Shape (our `CommitAttestation` schema):
```json
{
  "commit_sha": "a7573bcb...",
  "commit": {
    "sha": "a7573bcb...",
    "parent_shas": ["c28d319a..."],
    "author": { "login": "sami-alajrami", "git_name": "Sami Alajrami", "git_email": "sami@kosli.com" },
    "date": "2024-06-01T12:00:00Z",
    "message": "omit empty pr approver state and timestamp (#652)",
    "changed_files": ["internal/pr/github.go"]
  },
  "pull_requests": [{
    "number": 652,
    "url": "https://github.com/kosli-dev/cli/pull/652",
    "author": { "login": "sami-alajrami" },
    "approvals": [{ "user": { "login": "ToreMerkely" }, "approved_at": "2024-06-01T12:34:49Z" }],
    "pr_commits": [{ "sha": "6aa56c83...", "parent_shas": ["..."], "author": { "login": "sami-alajrami" }, "date": "2024-06-01T..." }]
  }]
}
```

### New (`pr-review` Kosli PR attestation)

Attested via `kosli attest pullrequest github --name pr-review --commit <sha> ...`.

Accessible in Rego at:
```
trail.compliance_status.attestations_statuses["pr-review"]
```

Shape (confirmed from live run on `a7573bcb`):
```json
{
  "attestation_type": "pull_request",
  "git_commit_info": {
    "author": "Sami Alajrami <sami@kosli.com>",
    "sha1": "a7573bcb...",
    "timestamp": 1770191490
  },
  "is_compliant": true,
  "pull_requests": [{
    "author": "sami-alajrami",
    "merge_commit": "a7573bcb...",
    "state": "MERGED",
    "url": "https://github.com/kosli-dev/cli/pull/652",
    "approvers": [
      { "username": "ToreMerkely", "timestamp": 1770191489, "state": "APPROVED" }
    ],
    "commits": [
      { "sha1": "6aa56c83...", "author_username": "sami-alajrami", "timestamp": 1770130023 }
    ]
  }]
}
```

### Field mapping

| Old | New |
|---|---|
| `attestation_data.commit.sha` | `trail.git_commit_info.sha1` |
| `attestation_data.commit.author.login` | parse from `git_commit_info.author` (`"Name <email>"`) |
| `attestation_data.commit.author.git_name` | parse from `git_commit_info.author` |
| `attestation_data.commit.parent_shas` | **not available** |
| `attestation_data.pull_requests[].approvals[].user.login` | `pull_requests[].approvers[].username` |
| `attestation_data.pull_requests[].approvals[].approved_at` (ISO 8601) | `pull_requests[].approvers[].timestamp` (Unix seconds) |
| `attestation_data.pull_requests[].pr_commits[].author.login` | `pull_requests[].commits[].author_username` |
| `attestation_data.pull_requests[].pr_commits[].date` (ISO 8601) | `pull_requests[].commits[].timestamp` (Unix seconds) |
| `attestation_data.pull_requests[].pr_commits[].sha` | `pull_requests[].commits[].sha1` |
| `attestation_data.pull_requests[].pr_commits[].parent_shas` | **not available** |
| *(no equivalent)* | `pull_requests[].merge_commit` — SHA of the merge commit |

### What is lost

- `parent_shas` for both the trail commit and PR branch commits — no merge-from-base
  detection possible. The `post_approval_merge_commits` setting is dropped entirely.
- `raw_<sha>.json` attachment (raw GitHub API responses). Kosli stores equivalent
  data internally.

### Merge commit detection without `parent_shas`

`pr.merge_commit` contains the SHA of the commit that merged the PR into the base branch.
Since trails are named by commit SHA, `trail.name == pr.merge_commit` tells the policy
whether this trail represents the merge commit.

---

## Part 3: Rego Policy Changes

### 3a. Attestation access path

```rego
# Old
trail_data(trail) := trail.compliance_status.attestations_statuses["scr-data"].attestation_data

# New
pr_attest(trail) := trail.compliance_status.attestations_statuses["pr-review"]
```

### 3b. Merge commit detection

```rego
# Old — required parent_shas
is_merge_commit(commit) if { count(commit.parent_shas) > 1 }

# New — use PR's merge_commit field
is_merge_commit(trail, pr) if { trail.name == pr.merge_commit }
```

### 3c. Drop merge-from-base filtering

Remove `is_merge_from_base`, `relevant_pr_commits`, and the `post_approval_merge_commits`
constant entirely. PR commit `parent_shas` are unavailable; all `commits[]` entries are
treated as code-changing commits.

### 3d. Timestamps — ISO 8601 → Unix seconds

```rego
# Old
latest_relevant_commit_ns(pr) := max(
    {time.parse_rfc3339_ns(c.date) | some c in relevant_pr_commits(pr)})
# approval check:
time.parse_rfc3339_ns(approval.approved_at) > cutoff

# New — compare Unix seconds directly
latest_commit_ts(pr) := max({c.timestamp | some c in pr.commits})
# approval check:
approver.timestamp > cutoff
```

### 3e. PR commit authors

```rego
# Old
pr_commit_authors(pr) := {login |
    some c in pr.pr_commits; login := c.author.login; login != null}

# New
pr_commit_authors(pr) := {u |
    some c in pr.commits; u := c.author_username; u != null}
```

### 3f. Independent approval

For non-merge commits include `pr.author` in the required approver set; for merge commits
(where `trail.name == pr.merge_commit`) only require PR branch commit authors.

```rego
has_independent_approval(trail, pr) if {
    not is_merge_commit(trail, pr)
    cutoff := latest_commit_ts(pr)
    all_authors := pr_commit_authors(pr) | {pr.author}
    count(all_authors) > 0
    every author in all_authors {
        some approver in pr.approvers
        approver.username != author
        approver.timestamp > cutoff
    }
}

has_independent_approval(trail, pr) if {
    is_merge_commit(trail, pr)
    cutoff := latest_commit_ts(pr)
    all_authors := pr_commit_authors(pr)
    count(all_authors) > 0
    every author in all_authors {
        some approver in pr.approvers
        approver.username != author
        approver.timestamp > cutoff
    }
}
```

### 3g. Service account detection

`git_commit_info.author` is a `"Name <email>"` string. Regex matching against the full
string works for all current patterns (e.g. `"github-actions[bot] <...>"` matches
`"github-actions\\[bot\\]"`).

```rego
# Old
is_service_account(commit) if {
    some p in service_account_patterns; regex.match(p, commit.author.git_name) }
is_service_account(commit) if {
    some p in service_account_patterns; regex.match(p, commit.author.login) }

# New
is_service_account(trail) if {
    some p in service_account_patterns
    regex.match(p, trail.git_commit_info.author)
}
```

### 3h. Violations — updated field references

| Old check | New check |
|---|---|
| `not attestations_statuses["scr-data"]` | `not attestations_statuses["pr-review"]` |
| `c.author.login == null` in PR commits | `c.author_username == null` |
| `count(attestation.pull_requests) == 0` | `count(pr_attest(trail).pull_requests) == 0` |
| `not has_any_pr_approval(commit, attestation)` | `not has_any_pr_approval(trail, pr_attest(trail))` |

---

## Part 4: Simulation Script Changes

### Remove

- `npm run build` step and all `node dist/index.js` invocations for data collection
- `kosli attest custom --type scr-data` step
- All `att_data_<sha>.json` and `raw_<sha>.json` file handling

### Base SHA resolution in the script

**First release pair** — explicit tag, resolve to SHA directly:
```bash
COMMITS=$(git -C "$REPO" log "${BASE_TAG}..${CURRENT_TAG}" --first-parent --pretty=format:%H)
```

**Subsequent pairs** — call the slimmed TypeScript resolver:
```bash
BASE_SHA=$(KOSLI_FLOW="$KOSLI_FLOW" node "${SCRIPT_DIR}/dist/index.js" \
  --repo "$REPO" --ref "$CURRENT_TAG")
COMMITS=$(git -C "$REPO" log "${BASE_SHA}..${CURRENT_TAG}" --first-parent --pretty=format:%H)
```

### New per-commit block

```bash
# 1. Begin trail — unchanged
kosli begin trail "$SHA" \
  --flow "$KOSLI_FLOW" \
  --commit "$SHA" \
  --repo-root "$REPO"

# 2. Attest PR data — replaces collector + kosli attest custom
kosli attest pullrequest github \
  --name pr-review \
  --github-token "$GITHUB_TOKEN" \
  --github-org kosli-dev \
  --commit "$SHA" \
  --repo-root "$REPO" \
  --repository "$GITHUB_REPOSITORY" \
  --flow "$KOSLI_FLOW" \
  --trail "$SHA"

# 3. Evaluate — unchanged; Rego policy updated per Part 3
kosli evaluate trails "$SHA" \
  --policy "${SCRIPT_DIR}/four-eyes.rego" \
  --flow "$KOSLI_FLOW" \
  --output json > "${COMMIT_EVAL_FILE}" 2>/dev/null || true

# 4. Build summary + attest four-eyes-result — unchanged
```

### Optional: suppress repo-info warning

The command warns `Repo information will not be reported as ID, Name and URL are required`
when `--repo-id`/`--repo-url`/`--repository` are not all three set. To suppress:

```bash
REPO_ID=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/repos/kosli-dev/cli | jq '.id')
# then add to the attest command:
#   --repo-id "$REPO_ID"
#   --repo-url "https://github.com/kosli-dev/cli"
#   --repository "kosli-dev/cli"
```

---

## Summary

| Aspect | Before | After |
|---|---|---|
| TypeScript files | 8 | 4 (`kosli.ts`, `baseTagResolver.ts`, `git.ts` trimmed, `index.ts` rewritten) |
| GitHub API calls | custom Octokit wrapper | handled by `kosli` CLI |
| Attestation type | custom `scr-data` | built-in `pull_request` |
| Timestamps in Rego | ISO 8601 via `time.parse_rfc3339_ns` | Unix seconds, direct comparison |
| Merge commit detection | `parent_shas` count | `pr.merge_commit == trail.name` |
| Merge-from-base filtering | `post_approval_merge_commits` setting | **dropped** (no `parent_shas` in PR commits) |
| Raw GitHub data attachment | `raw_<sha>.json` | not available (Kosli stores internally) |
