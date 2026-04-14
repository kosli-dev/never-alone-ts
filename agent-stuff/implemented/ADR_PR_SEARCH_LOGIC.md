# Architectural Decision Record: PR Search Logic for Multiple Results

## Status
Proposed

## Context
When searching for a merged Pull Request associated with a specific commit SHA using the GitHub Search API (`is:pr is:merged sha:<SHA>`), it is theoretically possible to receive multiple results. This can happen if a commit was included in multiple PRs (e.g., a cherry-pick, a backport, or a PR merged and then later included in another).

## Decision Options

### Option 1: Evaluate Only the First (Most Recent) PR
The tool uses the first PR returned by the GitHub API.

**Pros:**
- Simplest implementation.
- Lowest API overhead (minimal calls).
- Usually sufficient, as the first result is often the most relevant one in a standard workflow.

**Cons:**
- Risk of false failures if the first PR lacks approval but a subsequent one (containing the same commit) has it.
- Non-deterministic behavior if the API results order changes.

### Option 2: Evaluate All Returned PRs (Any Pass)
Iterate through all returned PRs. If *any* of them pass the "four-eyes" criteria, the commit is marked as `PASS`.

**Pros:**
- Most robust and comprehensive.
- Minimizes false failures by accounting for complex merge histories.
- High confidence in the "four-eyes" principle adherence across the entire history.

**Cons:**
- Higher API usage (multiple review fetches per commit).
- More complex implementation (requires nested loops and state management).
- Slightly slower execution time.

### Option 3: Fail if Multiple PRs are Found
Require human intervention if the tool cannot uniquely identify the PR.

**Pros:**
- Extremely conservative; ensures no ambiguity.

**Cons:**
- High friction; likely to fail in repositories with common backporting or cherry-picking practices.

## Recommendation
**Option 2 (Evaluate All Returned PRs)** is recommended for the final implementation. While slightly more complex, it ensures the highest accuracy and adheres strictly to the spirit of the "four-eyes principle" by verifying if *any* valid approval exists for that change.

## Current Implementation Status
The current implementation (as of initial draft) uses **Option 1** for simplicity. If a more robust approach is required based on this ADR, the `Evaluator` and `GitHubClient` will be updated.
