# GitHub API Parallelization Plan

Observed during a run against `kosli-dev/cli` at tag `v0.1.1` (62 commits):
- All commits processed in a serial `for...of` loop
- Search API rate limit hit twice during serial execution
- ~186 sequential API round-trips total

---

## Step 1 — Parallelize within `collectCommit`

**File:** `src/evaluator.ts` lines 9–17

`getCommitDetails` and `findPRForCommit` have no data dependency on each other but are currently awaited sequentially. Replace with `Promise.all`.

```typescript
// Before
const githubAuthor = await this.github.getCommitDetails(commit.sha);
const changedFiles = getChangedFiles(commit.sha, this.repoPath);
const prNumbers = await this.github.findPRForCommit(commit.sha);

// After
const [githubAuthor, prNumbers, changedFiles] = await Promise.all([
  this.github.getCommitDetails(commit.sha),
  this.github.findPRForCommit(commit.sha),
  Promise.resolve(getChangedFiles(commit.sha, this.repoPath)),
]);
```

**Gain:** saves one full API round-trip (~200–400ms) per commit. For 62 commits: ~12–25s saved. Zero rate limit risk — same total number of requests.

---

## Step 2 — PR fetch deduplication cache

**File:** `src/github.ts` line 46

Multiple commits in the same range often share PRs. Currently `getPRFullDetails` is called once per *(commit, PR)* pair, so the same PR can be fetched multiple times. A `Promise`-based cache eliminates all duplicate fetches.

```typescript
// Add to GitHubClient class
private prCache = new Map<number, Promise<PRDetails | undefined>>();

async getPRFullDetails(prNumber: number): Promise<PRDetails | undefined> {
  if (!this.prCache.has(prNumber)) {
    this.prCache.set(prNumber, this._fetchPRFullDetails(prNumber));
  }
  return this.prCache.get(prNumber)!;
}

// Rename existing method body to _fetchPRFullDetails
```

**Gain:** fewer API calls and less rate limit pressure with no architectural change.

---

## Step 3 — Parallelize the outer commit loop

**File:** `src/index.ts` lines 50–57

The serial `for...of` loop is the main bottleneck. Replace with `Promise.all` plus a concurrency cap.

**Caution:** the search API (`findPRForCommit`) hit its quota at serial pace during the observed run. The limit is 30 req/min (authenticated). A concurrency cap of **4** keeps search pressure manageable while the `@octokit/plugin-throttling` handler retries as needed.

```typescript
// Add p-limit as explicit dependency: npm install p-limit
import pLimit from 'p-limit';

const limit = pLimit(4);

const results = await Promise.all(
  commits.map(commit => limit(async () => {
    console.log(`Collecting commit ${commit.sha.substring(0, 7)}: ${commit.message.substring(0, 30)}...`);
    return collector.collectCommit(commit);
  }))
);

for (const { commitData, prDetails } of results) {
  collectedCommits.push(commitData);
  for (const pr of prDetails) pullRequests[pr.number.toString()] = pr;
}
```

`p-limit` is a transitive dependency already installed but not listed in `package.json` — add it explicitly before shipping.

**Gain:** with steps 1 and 2 in place, expected wall time for 62 commits drops from ~4–5 min to ~1 min.

---

## Resulting call graph (post-parallelization)

```
main()
  getCommits()          — local, synchronous

  Promise.all(commits, concurrency=4):
    per commit [wave 1, concurrent]:
      Promise.all([
        GET /repos/:owner/:repo/commits/:sha   (getCommitDetails)
        GET /search/issues?q=sha:...           (findPRForCommit)
        getChangedFiles()                      — local, sync
      ])
    per commit [wave 2, after wave 1]:
      Promise.all(prNumbers.map(n =>
        getPRFullDetails(n)  ← cache hit if PR already seen
          Promise.all([
            GET /pulls/:n
            GET /pulls/:n/reviews
            GET /pulls/:n/commits (paginated)
          ])
      ))

  generateAttestationData()   — local, synchronous
```

---

## Implementation order

| Step | File | Rate limit risk | Expected gain |
|------|------|-----------------|---------------|
| 1 | `src/evaluator.ts` | None | ~50% per-commit latency |
| 2 | `src/github.ts` | None | Eliminates duplicate PR fetches |
| 3 | `src/index.ts` | Search quota — keep concurrency ≤ 4 | ~4× total throughput |

Do steps 1 and 2 first. They reduce rate limit pressure before step 3 amplifies request volume.
