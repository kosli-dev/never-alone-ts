# GitLab Implementation Plan

**Depends on:** `GITLAB_API_COMPATIBILITY.md`
**Assumes:** Option 2 (evaluate all PRs/MRs) is already implemented on the GitHub side.

---

## Overview

The collector and Rego policy are largely platform-agnostic already. The main work is:

1. A new `GitLabClient` that satisfies the same interface as `GitHubClient`
2. Identity resolution logic (GitLab's extra step not needed on GitHub)
3. Config generalisation (env vars, platform field)
4. Minor Rego policy cleanup (one GitHub-specific string, one GitHub-specific rule)

No changes to `reporter.ts`, `git.ts`, `baseTagResolver.ts`, or `kosli.ts`.

---

## Phase 1 — Extract a shared client interface

**File:** `src/types.ts`

Add an interface that both clients implement:

```typescript
export interface IVCSClient {
  findPRForCommit(sha: string): Promise<number[]>;
  getPRFullDetails(prNumber: number): Promise<PRDetails | undefined>;
  getCommitDetails(sha: string): Promise<UserIdentity | undefined>;
}
```

**File:** `src/github.ts`

Add `implements IVCSClient` to `GitHubClient`. No logic changes.

**File:** `src/evaluator.ts`

Change the constructor parameter from `GitHubClient` to `IVCSClient`.

This is a small mechanical change (~5 lines) but makes everything downstream work without touching the `Collector` logic.

---

## Phase 2 — Generalise config

**File:** `src/types.ts` — `Config` interface

Replace `githubRepository` and `githubToken` with platform-agnostic fields, and add `platform`:

```typescript
export interface Config {
  platform: 'github' | 'gitlab';
  repository: string;       // was: githubRepository
  token: string;            // was: githubToken
  // ... rest unchanged
}
```

**File:** `src/config.ts`

- Read `PLATFORM` env var (default `"github"` for backward compatibility)
- Read `REPOSITORY` / `TOKEN` as the canonical names
- Keep `GITHUB_REPOSITORY` / `GITHUB_TOKEN` as fallbacks so existing users are not broken
- For GitLab, also read `GITLAB_PROJECT_ID` (optional — see open question 3 below)
- Validation: require `REPOSITORY` (or its fallback) and `TOKEN`

Approximate env var mapping:

| New var | Fallback (backward compat) |
|---|---|
| `PLATFORM` | — (defaults to `"github"`) |
| `REPOSITORY` | `GITHUB_REPOSITORY` |
| `TOKEN` | `GITHUB_TOKEN` |
| `GITLAB_PROJECT_ID` | — (optional, see Q3) |

---

## Phase 3 — GitLab client

**File:** `src/gitlab.ts` (new)

Implements `IVCSClient`. Wraps GitLab's REST API using `node-gitlab` or plain `fetch`/`axios`. Three public methods mirror the GitHub client exactly; identity resolution is an internal concern.

### 3.1 `findPRForCommit(sha): Promise<number[]>`

```
GET /api/v4/projects/{id}/repository/commits/{sha}/merge_requests
→ filter state == "merged"
→ return items.map(mr => mr.iid)
```

Direct equivalent of the GitHub search query. Returns all merged MRs that contain the commit.

### 3.2 `getMRFullDetails(iid): Promise<PRDetails | undefined>`

Three parallel calls (same pattern as `getPRFullDetails` in `github.ts`):

```
GET /api/v4/projects/{id}/merge_requests/{iid}
GET /api/v4/projects/{id}/merge_requests/{iid}/approvals   → approved_by[]
GET /api/v4/projects/{id}/merge_requests/{iid}/commits
```

Then a fourth call to resolve commit author identities:

```
GET /api/v4/projects/{id}/merge_requests/{iid}/participants
→ used by the identity resolution chain (see 3.4)
```

Field mapping when building the `PRDetails` object:

| `PRDetails` field | GitLab source |
|---|---|
| `number` | `mr.iid` |
| `url` | `mr.web_url` |
| `title` | `mr.title` |
| `author.login` | `mr.author.username` |
| `author.user_id` | `mr.author.id` |
| `author.web_url` | `mr.author.web_url` |
| `state` | `mr.state` |
| `merged_at` | `mr.merged_at` |
| `approvals[].user.login` | `approved_by[].user.username` |
| `approvals[].user.user_id` | `approved_by[].user.id` |
| `approvals[].user.web_url` | `approved_by[].user.web_url` |
| `approvals[].approved_at` | `approved_by[].approved_at` (see Q5) |
| `commits[].author.login` | resolved via `resolveIdentity()` below |

### 3.3 `getCommitDetails(sha): Promise<UserIdentity | undefined>`

GitLab's commit API does not return a platform user object. This method attempts email-based resolution only (28% success rate in testing). It is a best-effort call for the main-branch commit's author identity.

```
GET /api/v4/projects/{id}/repository/commits/{sha}
→ extract author_name, author_email
→ GET /api/v4/users?search=<author_email>
→ if exactly one result and result.name == author_name: return { login: username, user_id: id, ... }
→ else: return { git_name: author_name, git_email: author_email }   (login/user_id left undefined)
```

When this returns `undefined` for `login`, the Rego will exclude the main-branch commit's author from `all_authors`. That is acceptable — the PR commit list is the primary source of identity for the independence check.

### 3.4 `resolveIdentity(authorName, authorEmail, participants)` (private helper)

Used inside `getMRFullDetails` to resolve identity for each MR commit author. Three-step chain:

```
1. GET /api/v4/users?search=<email>
   → use if exactly one result AND result.name == authorName

2. participants.find(p => p.name === authorName)
   → use username + id

3. participants.find(p => p.username === authorName)
   → covers developers whose git_name is their username handle

4. return null for login/user_id
   → Rego fires "identity unverifiable" violation
```

The participants list is fetched once per MR and passed into per-commit resolution — no extra API call per commit.

---

## Phase 4 — Entry point routing

**File:** `src/index.ts`

After loading config, instantiate the correct client:

```typescript
const client: IVCSClient = config.platform === 'gitlab'
  ? new GitLabClient(config.repository, config.token)
  : new GitHubClient(config.repository, config.token);

const collector = new Collector(client, repoPath);
```

No other changes to `index.ts`.

---

## Phase 5 — Rego policy

Two changes needed, both small.

### 5.1 Platform-agnostic violation message

Current (GitHub-specific):
```rego
"PR #%v: commit %v author '%v <%v>' has no linked GitHub account — identity unverifiable"
```

Replace `GitHub` with `VCS platform` or just remove it:
```rego
"PR #%v: commit %v author '%v <%v>' has no linked platform account — identity unverifiable"
```

### 5.2 Merge commit detection

The existing rule `startswith(commit.message, "Merge pull request #")` is GitHub-specific and never fires on GitLab. On GitLab, standard merge commits use messages like `"Merge branch 'feature' into 'main'"`. Add a GitLab pattern:

```rego
is_merge_commit(commit) if {
  startswith(commit.message, "Merge branch '")
}
```

Note: fast-forward and squash merges on GitLab produce single-parent commits — they are correctly *not* detected as merge commits, which means they get subjected to the four-eyes check. This is the right behaviour.

---

## Phase 6 — Tests

**File:** `tests/gitlab.test.ts` (new)

Mirror the structure of `evaluator.test.ts`. Mock the GitLab HTTP client. Cover:

- `findPRForCommit` returns all MR iids
- `getMRFullDetails` maps all fields correctly
- Identity resolution: email hit, name hit, username hit, null fallback
- `getCommitDetails`: email success and failure

**File:** `four-eyes_test.rego`

No new test cases needed — existing scenarios already cover null logins (Scenarios 17–19) and the only policy change is a string substitution.

---

## API call budget per commit

For reference, the GitLab implementation makes more API calls than GitHub per commit, due to the identity resolution step:

| Step | Calls |
|---|---|
| `getCommitDetails` (main branch commit) | 1–2 (commit + optional user search) |
| `findMRsForCommit` | 1 |
| Per MR: MR details + approvals + commits + participants | 4 |
| Per MR commit: user search (if email resolution attempted) | 0–1 each |

A commit linked to one MR with three branch commits costs roughly 6–9 calls. Rate limiting (GitLab allows 2,000 req/min authenticated) should not be an issue for typical repository sizes, but a throttling wrapper (same as the Octokit plugin used on the GitHub side) is recommended.

---

## Open questions

**Q1 — Shared or platform-specific Rego policy?**
The plan above assumes one shared policy with two small GitLab-compatible adjustments. If customers need to deploy separate policies per platform (e.g. different `post_approval_merge_commits` settings), a per-platform file might be preferable. Decision affects Phase 5 scope.

**Q2 — Merge commit detection: add GitLab message pattern or rely on parent count only?**
The plan adds `startswith(commit.message, "Merge branch '")`. This covers standard GitLab merge commits but may over-match on repos that use that phrase in regular commit messages. Alternative: rely solely on `count(parent_shas) > 1` and drop the message-based rule entirely (it was only ever a GitHub workaround for merge commits that somehow had a single parent). What is the origin of that rule — is it actually needed?

**Q3 — Numeric project ID vs. namespace/path?**
GitLab API accepts URL-encoded paths (`namespace%2Fproject`) for all the calls listed in this plan. Numeric ID is more stable across project renames. Decision: require users to supply `GITLAB_PROJECT_ID`, or resolve it at startup via `GET /api/v4/projects/{encoded_path}` and cache it? The auto-resolve approach is more ergonomic but adds one extra API call.

**Q4 — Config backward compatibility: keep `GITHUB_REPOSITORY` / `GITHUB_TOKEN`?**
The plan proposes `REPOSITORY` + `TOKEN` as canonical names with `GITHUB_*` as fallbacks. Alternative: leave the GitHub env var names as-is and introduce `GITLAB_REPOSITORY` + `GITLAB_TOKEN` as the GitLab equivalents, with `PLATFORM` selecting which pair to read. This avoids changing anything for existing GitHub users at the cost of more branching in `config.ts`.

**Q5 — GitLab approval timestamps and re-approvals**
The GitLab approvals endpoint returns `approved_at` per approver. It is not verified whether this timestamp reflects the *most recent* approval event (i.e. does it update when a reviewer un-approves and re-approves after new code is pushed?). If it reflects only the first approval, a reviewer who approved early, watched new code land, and re-approved would appear to have approved before the cutoff. Should be verified before shipping.
