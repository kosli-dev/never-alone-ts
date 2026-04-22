# GitHub Actions PR Data Caching — Plan for Simultaneous Workflow Runs

## Problem

When multiple commits are pushed to a branch (or multiple workflows trigger simultaneously), each `never-alone` run fetches the same GitHub PR and commit data independently. This causes:

- **Redundant API calls**: PRs shared across commits are fetched N times.
- **Rate-limit pressure**: GitHub's REST API allows 5,000 requests/hour per token. A large release range can exhaust this quickly.
- **Race conditions**: Two runs writing the same cache key at nearly the same time can corrupt or overwrite each other.

---

## Proposed Solution: GitHub Actions Cache with Scoped Keys

### Key design decisions

| Decision | Choice | Rationale |
|---|---|---|
| Cache backend | `actions/cache` (GitHub's built-in) | Zero infrastructure, scoped to repo, automatic eviction |
| Cache granularity | Per-PR-number | PRs are immutable once merged; per-SHA would waste cache on force-pushes |
| Cache scope | Branch → main fallback | `actions/cache` restores from matching branch, falls back to default branch |
| Concurrency guard | `actions/cache` write-once-per-key semantics | First writer wins; subsequent runs restore instead of re-fetching |
| Cache format | One JSON file per PR (`pr_cache_<number>.json`) | Granular invalidation; easy to version |

---

## Cache Key Scheme

```
never-alone-pr-<repo_slug>-<pr_number>-<pr_updated_at_epoch>
```

- `repo_slug`: `owner__repo` (slashes replaced)
- `pr_updated_at_epoch`: Unix epoch of `updated_at` from the GitHub API list response

**Why include `updated_at`?** Open PRs can gain new reviews and commits. Keying on `updated_at` busts the cache automatically when the PR changes, without any manual invalidation.

**Lookup flow:**
1. Before fetching PR data, query the GitHub API list endpoint (`GET /repos/{owner}/{repo}/pulls/{number}`) for `updated_at`. This is one cheap call.
2. Compute the cache key.
3. Check `actions/cache` for a hit.
4. On hit: parse cached file, skip full fetch.
5. On miss: fetch full data, write to cache.

---

## Workflow Integration

### Option A: Cache inside the `never-alone` Node process (preferred)

The collector calls `@actions/cache` npm package directly:

```typescript
import * as cache from '@actions/cache';

async function getCachedPR(number: number, updatedAt: string): Promise<PRSummary | null> {
  const key = `never-alone-pr-${repoSlug}-${number}-${Date.parse(updatedAt)}`;
  const path = `/tmp/never-alone-cache/pr_${number}.json`;
  const hit = await cache.restoreCache([path], key);
  if (hit) return JSON.parse(fs.readFileSync(path, 'utf8'));
  return null;
}

async function saveCachedPR(number: number, updatedAt: string, data: PRSummary): Promise<void> {
  const key = `never-alone-pr-${repoSlug}-${number}-${Date.parse(updatedAt)}`;
  const path = `/tmp/never-alone-cache/pr_${number}.json`;
  fs.writeFileSync(path, JSON.stringify(data));
  await cache.saveCache([path], key);
}
```

**Pro:** No workflow YAML changes needed beyond the existing `never-alone` job step.  
**Con:** `@actions/cache` only works inside GitHub Actions (no-op locally, throws outside Actions unless guarded).

Guard for local runs:
```typescript
const IS_ACTIONS = !!process.env.ACTIONS_CACHE_URL;
```

### Option B: Pre-fetch step in workflow YAML

Add a step before `never-alone` that restores a broad cache:

```yaml
- uses: actions/cache@v4
  id: pr-cache
  with:
    path: /tmp/never-alone-cache
    key: never-alone-prs-${{ github.sha }}
    restore-keys: |
      never-alone-prs-
```

Then `never-alone` reads from `/tmp/never-alone-cache/` before fetching. A post-step saves any new entries back.

**Pro:** No new npm dependency.  
**Con:** Coarse cache key — any SHA change misses everything, defeating the purpose. More YAML boilerplate. Harder to invalidate per-PR.

**Recommendation: Option A** — per-PR keys with `updated_at` busting give the right granularity and work automatically.

---

## Handling Simultaneous Runs (Race Condition)

`actions/cache` uses a first-writer-wins model: if two runs try to save the same key, only the first succeeds and the second is silently rejected. This is safe — both runs computed the same data, so losing the second write is harmless.

For the read side: if run B starts before run A has finished saving, run B will get a cache miss and fetch independently. This is also safe — redundant work, not corruption.

**No explicit locking is needed.**

---

## Scope Limitations

- Cache is **not shared across repositories** — each `owner/repo` has its own namespace.
- Cache is **evicted after 7 days** of no access (GitHub's policy). Long-lived repos will re-fetch after idle periods.
- Cache is **not available on self-hosted runners** unless the runner has network access to `api.github.com` cache endpoints.
- The `@actions/cache` package is **a no-op outside GitHub Actions** — callers must guard with `IS_ACTIONS`.

---

## Implementation Steps

1. Add `@actions/cache` to `package.json` dependencies (already an optional peer dep of many action toolkits).
2. Create `src/prCache.ts` with `getCachedPR` / `saveCachedPR` helpers, guarded by `IS_ACTIONS`.
3. In `GitHubClient.getPRSummaryAndRaw()`, call `getCachedPR` before the GitHub API fetch; call `saveCachedPR` after.
4. Add `/tmp/never-alone-cache/` to `.gitignore`.
5. Document the `ACTIONS_CACHE_URL` guard in the README.

---

## What This Does NOT Solve

- **Commit data caching**: `GET /repos/{owner}/{repo}/commits/{sha}` calls are already per-SHA and rarely duplicated across runs. Not worth caching.
- **Cross-workflow PR data sharing within the same run**: If the same PR number appears for multiple commits in one run, `pLimit(4)` already serializes those calls and the in-memory result can be reused by adding a simple `Map<number, PRSummary>` memo inside `Collector`. This is lower-hanging fruit than the Actions cache and should be implemented first.
