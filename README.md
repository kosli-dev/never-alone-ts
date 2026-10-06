# Source Code Review Verification Tool

## Note! This tool is in alpha, and is therefore subject to extensive changes

This tool verifies adherence to the "four-eyes principle" for code changes within a specified release range. It is split into two parts:

1. **Collector** (`src/`) — a TypeScript CLI that calls the Kosli CLI to create per-commit trails and attest GitHub PR data using `kosli attest pullrequest github`.
2. **Policy** (`four-eyes.rego`) — a Rego policy evaluated by Kosli against the attested PR data, producing pass/fail results and violation messages.

## How it works

```text
node dist/index.js --repo /path/to/repo
  │
  ├─ for each commit in BASE_TAG..CURRENT_TAG (--first-parent):
  │    kosli begin trail <sha> --flow <flow> --commit <sha>
  │    kosli attest pullrequest github --name pr-review --commit <sha> ...
  │
  └─ (Kosli stores PR data: commits, reviews, merge commit SHA)

kosli evaluate trails SHA1 SHA2 ... --policy four-eyes.rego --flow <flow> \
    --params '{"repository": "owner/repo"}'
  │
  └─ OPA evaluates four-eyes.rego against input.trails[]
       → allow (bool) + violations[] (strings)
```

The collector's only job is trail creation and PR attestation. All evaluation logic lives in `four-eyes.rego`, so rules can be updated independently of the data collection code.

## Evaluation rules

A commit trail passes when one of its PRs meets all of these:

1. **In this repository**: the PR's URL is in the repository passed as `--params '{"repository": "owner/repo"}'`. A PR anywhere else, such as a fork, doesn't count. Without the param, every trail fails.
2. **Every commit identified**: each PR commit has an author linked to a GitHub account (`author_username`) and a verified signature, either by a known account (`signer_username`) or by GitHub (`signed_by_platform`, for web edits and merges). The author fields are whatever the commit's writer put there, so the signer is what shows who made it. The signer needs an independent approval too.
3. **Independent approval on the final commit**: for each PR code author and signer, at least one approval from a different person with write access, given on the PR's final commit, and not withdrawn by a later request for changes or dismissal from the same reviewer. The policy compares the commit each review was given on with the PR's head commit. Commit dates aren't used, because whoever writes a commit sets them.

A commit with no PR fails. There is no exemption by author name: bot and service-account commits need a PR with a human approval like any other. A bot commit GitHub links to the bot's account (e.g. `dependabot[bot]`) counts as identified; one with no linked account, such as a `GitHub <noreply@github.com>` co-author entry, doesn't.

Merge commits (where `pr.merge_commit == trail.name`) are treated the same as regular commits for the approval check, but the person who clicked Merge is not counted as a code author.

Unsigned commits fail, so this suits repositories that require signed commits.

Anything that adds a commit after approval needs a new approval, including **Update branch**, a rebase, a conflict fix in the web editor and an applied review suggestion. A reviewer who applies their own suggestion also becomes a commit's author, so someone else has to approve.

This needs a Kosli CLI that records every review (`reviews`, with each review's commit, `author_type` and `has_write_access`), the PR's head commit (`head_sha`) and each commit's signer (`signer_username`, `signed_by_platform`). The CLI records these as facts; this policy decides which reviews count. Attestations made with an older CLI lack these fields, so no approval counts; re-attest with a current CLI.

For named test cases with git diagrams and expected outcomes, see [SCENARIOS.md](SCENARIOS.md).

## Prerequisites

- **Node.js** 18+
- **Git** available in PATH
- **GitHub Token** — Personal Access Token with `repo` scope
- **Kosli CLI** — for attesting and evaluating ([installation](https://docs.kosli.com/getting_started/))
- `KOSLI_API_TOKEN` and `KOSLI_ORG` set in the environment (consumed directly by the Kosli CLI)

## Installation

```bash
npm install
npm run build
```

## Import style and build pipeline

This project uses extensionless local imports in TypeScript source (for example `./kosli` instead of `./kosli.js`) to stay compatible with monorepo defaults.

Because the package runs as ESM (`"type": "module"`), plain TypeScript emit can produce runtime resolution errors in Node for extensionless local imports. For that reason, `npm run build` uses webpack to bundle `src/main.ts` into `dist/index.js`.

Use:

```bash
npm run build      # webpack bundle used for runtime
npm run typecheck  # TypeScript type-check only
```

## Configuration

### Environment variables

| Variable | Required | Description |
| :--- | :--- | :--- |
| `CURRENT_TAG` | Yes | The release being evaluated — a git tag or commit SHA. |
| `GITHUB_REPOSITORY` | Yes | Repository in `owner/repo` format. |
| `GITHUB_TOKEN` | Yes | GitHub Personal Access Token with `repo` scope. |
| `KOSLI_FLOW` | Yes | Kosli flow name. Used for trail creation and `BASE_TAG` auto-resolution. |
| `BASE_TAG` | No | Starting git tag or SHA. If omitted, auto-resolved from Kosli (last attested commit in the flow). Falls back to the repository's first commit. |
| `KOSLI_ATTESTATION_NAME` | No | Attestation name for the PR data. Defaults to `pr-review`. |

## Usage

### CLI flags

| Flag | Description |
| :--- | :--- |
| `--repo <path>` | Path to the git repository to analyse. Defaults to the current directory. |
| `--env-file <path>` | Path to a `.env` file to load. |

### 1. Run the collector

**With explicit base tag:**

```bash
BASE_TAG=v1.0.0 CURRENT_TAG=v1.1.0 \
GITHUB_REPOSITORY=owner/repo GITHUB_TOKEN=... \
KOSLI_FLOW=my-flow \
node dist/index.js --repo /path/to/repo
```

**With auto-resolved base tag:**

```bash
CURRENT_TAG=v1.1.0 \
GITHUB_REPOSITORY=owner/repo GITHUB_TOKEN=... \
KOSLI_FLOW=my-flow \
node dist/index.js --repo /path/to/repo
```

When `BASE_TAG` is not set, the tool queries Kosli for the most recent commit in the git history that already has a `pr-review` attestation in the flow, and uses that as the base. If none is found it falls back to the repository's first commit.

This creates one Kosli trail per commit in the range and attaches `pr-review` PR data to each trail (commits, every review with the commit it was given on, head and merge commit SHAs).

### 2. Evaluate

```bash
kosli evaluate trails SHA1 SHA2 SHA3 \
  --policy four-eyes.rego \
  --params '{"repository": "owner/repo"}' \
  --flow my-flow \
  --output json > eval-result.json
```

Exit code `0` = all commits comply. Exit code `1` = violations found.

### 3. (Optional) Record the evaluation result

```bash
kosli attest custom \
  --type four-eyes-result \
  --name four-eyes-result \
  --attestation-data eval-result.json \
  --attachments four-eyes.rego \
  --flow my-flow \
  --trail release-v1.1.0
```

## Policy: `four-eyes.rego`

The policy evaluates `input.trails[]` — one entry per commit. PR data is the attestation in `input.trails[i].compliance_status.attestations_statuses` whose `attestation_type` is `pull_request`, whatever its name.

Attested via: `kosli attest pullrequest github --name pr-review --commit <sha>`.

### Verifying the input shape

Use `--show-input` to inspect the exact data structure passed to the policy:

```bash
kosli evaluate trails SHA1 SHA2 \
  --policy four-eyes.rego \
  --params '{"repository": "owner/repo"}' \
  --show-input \
  --flow my-flow \
  --output json
```

### Policy tests

The policy is tested with OPA's built-in test runner. The test file covers the scenario matrix:

```bash
npm run test:rego   # requires OPA CLI (or: docker run --rm -v $(pwd):/w openpolicyagent/opa test /w/four-eyes.rego /w/four-eyes_test.rego -v)
```

## Documentation

| Document | Description |
| :--- | :--- |
| [CATALOGUE.md](CATALOGUE.md) | Full control specification: intent, data collection flow, evaluation logic, configuration reference, exemptions, limitations, failure remediation, and attestation schema. |
| [SCENARIOS.md](SCENARIOS.md) | Named test cases with git diagrams and expected pass/fail outcomes, grouped by theme. |

---

## Development

### Running tests

```bash
npm test           # Jest unit tests (TypeScript)
npm run test:rego  # OPA policy tests (requires OPA CLI)
```

### Project structure

| File | Role |
| :--- | :--- |
| `src/main.ts` | CLI entry point; walks the commit range; calls `kosli begin trail` and `kosli attest pullrequest github` per commit (p-limit 4 concurrent) |
| `src/baseTagResolver.ts` | Walks git history backward from `currentTag`; queries Kosli trails to find the most-recently-attested SHA |
| `src/kosli.ts` | Shells out to `kosli list trails --flow` and paginates results |
| `src/git.ts` | `execFileSync` wrappers for `git log` and `git rev-list` |
| `src/config.ts` | Validates required env vars; loads `.env` via dotenv |
| `four-eyes.rego` | Rego policy evaluating four-eyes compliance |
| `four-eyes_test.rego` | OPA unit tests (36 scenarios) |
