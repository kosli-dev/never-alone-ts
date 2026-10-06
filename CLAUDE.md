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
docker run --rm -v "$(pwd)":/work openpolicyagent/opa test /work/four-eyes.rego /work/four-eyes_test.rego -v    # Run Rego policy tests (requires Docker)
```

Run a single Jest test file:
```bash
npx jest tests/evaluator.test.ts
```

Run the collector (range mode):
```bash
BASE_TAG=v1.0.0 CURRENT_TAG=v1.1.0 GITHUB_REPOSITORY=owner/repo GITHUB_TOKEN=... npm start -- --repo /path/to/repo
```

Run the collector (single commit, tool resolution):
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

kosli evaluate trails SHA1 SHA2 ... --policy four-eyes.rego --params '{"repository": "owner/repo"}'
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

A commit passes when one of its PRs is in the repository given by `--params '{"repository": "owner/repo"}'`, lists every commit GitHub counts (`commit_count`), has every commit author linked to a GitHub account and every commit carrying a verified signature (by a known account or GitHub), and has an approval from a person with write access, other than each author, co-author and signer (and, on a commit that isn't the merge commit, the PR creator, who must be a linked account), given on the PR's final commit (`reviews[].commit_sha == head_sha`) no later than `merged_at` and not withdrawn by a later request for changes or dismissal. No PR → FAIL. There is no author-name exemption, and commit dates are not used.

Merge commits are detected by `pr.merge_commit == trail.name`, not message text.

The policy test file `four-eyes_test.rego` covers the scenarios in `SCENARIOS.md`; run with `npm run test:rego`.

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
- `SCENARIOS.md` — named test scenarios with git diagrams and expected pass/fail outcomes; use these when adding Rego test cases
