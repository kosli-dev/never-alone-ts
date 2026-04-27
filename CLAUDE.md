# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

**never-alone** enforces the four-eyes principle for source code changes: every commit reaching production must have been reviewed and approved by someone other than the author. It has two components:

1. **Collector** (`src/`) — TypeScript CLI that gathers per-commit data (author, changed files, associated PRs, approvals) from git and the GitHub API, then writes JSON attestation files.
2. **Policy** (`four-eyes.rego`) — OPA/Rego policy that evaluates compliance. Evaluated by Kosli against the attested data.

## Commands

```bash
npm install          # Install dependencies
npm run build        # Compile TypeScript → dist/
npm test             # Run Jest unit tests
npm run test:rego    # Run Rego policy tests (requires OPA CLI)
bash runall.sh       # Build + Jest + Rego tests + simulation end-to-end
```

Run a single Jest test file:
```bash
npx jest tests/evaluator.test.ts
```

Run the collector (range mode):
```bash
BASE_TAG=v1.0.0 CURRENT_TAG=v1.1.0 GITHUB_REPOSITORY=owner/repo GITHUB_TOKEN=... npm start -- --repo /path/to/repo
```

Run the collector (single commit):
```bash
GITHUB_REPOSITORY=owner/repo GITHUB_TOKEN=... npm start -- --commit <sha>
```

## Architecture

### Data flow

```
Collector (npm start)
  → reads git log --first-parent (BASE_TAG..CURRENT_TAG)
  → for each commit: resolves GitHub identity, finds merged PR, fetches approvals
  → writes att_data_<sha>.json  (schema: jsonschema.json)
          raw_<sha>.json        (raw GitHub API responses)

kosli attest custom --type scr-data --attestation-data att_data_<sha>.json
  → creates a Kosli trail per commit SHA

kosli evaluate trails SHA1 SHA2 ... --policy four-eyes.rego
  → OPA receives input.trails[] (one entry per commit)
  → returns allow (bool) + violations[] (strings)

kosli attest custom --type four-eyes-result
  → records final pass/fail for the release
```

### Collector source (`src/`)

| File | Role |
|---|---|
| `index.ts` | CLI entry point; selects range vs granular mode; parallelises 4 commits at a time via p-limit |
| `evaluator.ts` | `Collector` class: orchestrates GitHub data collection for one commit |
| `github.ts` | Octokit wrapper; handles rate-limit retries; caches PR summaries |
| `git.ts` | `execSync` wrappers for git log, diff-tree, show |
| `reporter.ts` | Writes `att_data_<sha>.json` and `raw_<sha>.json` |
| `baseTagResolver.ts` | Walks git history backward from `currentTag`; queries Kosli trails to find most-recently-attested SHA |
| `kosli.ts` | Shells out to `kosli list trails --flow` and paginates results |
| `config.ts` | Validates required env vars; loads `.env` via dotenv |
| `types.ts` | All TypeScript interfaces |

### Policy (`four-eyes.rego`)

Three rules evaluated per commit in priority order (first match wins):

1. **Service account exemption** — author login matches any pattern in `service_account_patterns` → PASS
2. **No PR** — no merged PR found for commit → FAIL
3. **Independent approval** — PR must have at least one approval from someone other than the commit author, and that approval must come after the last code-change commit in the PR → PASS or FAIL

`post_approval_merge_commits` constant controls how merge-from-base commits are treated: `"ignore"` (exempt from post-approval timestamp check) or `"strict"` (all commits must have approval after them).

Merge commits are detected by parent count (>1), not message text.

The policy test file `four-eyes_test.rego` covers 17 scenarios; run with `npm run test:rego`.

### Kosli attestation types

Registered via `setup-kosli-attestation-type.sh` (one-time setup):

- `scr-data` — per-commit review data; schema in `jsonschema.json`
- `four-eyes-result` — release-level pass/fail; schema in `four-eyes-result-schema.json`

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `GITHUB_REPOSITORY` | Yes | `owner/repo` format |
| `GITHUB_TOKEN` | Yes | GitHub PAT with repo scope |
| `CURRENT_TAG` | Yes (range mode) | End of commit range |
| `BASE_TAG` | No | Start of range; auto-resolved from Kosli if omitted |
| `KOSLI_FLOW` | No | Kosli flow name used for BASE_TAG auto-resolution |
| `KOSLI_ATTESTATION_NAME` | No | Defaults to `scr-data` |

Copy `.env.example` to `.env` for local development.

## Key documentation

- `CATALOGUE.md` — full control specification including data collection logic, exemption rules, limitations, schema reference, and regulatory mapping (NIST/ISO/DORA)
- `SCENARIOS.md` — 17 named test scenarios with git diagrams and expected pass/fail outcomes; use these when adding Rego test cases
