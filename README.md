# Source Code Review Verification Tool

## Note! This tool is in alpha, and is therefore subject to extensive changes.

This tool verifies adherence to the "four-eyes principle" for code changes within a specified release range. It is split into two parts:

1. **Collector** (`src/`) — a TypeScript CLI that calls the Kosli CLI to create per-commit trails and attest GitHub PR data using `kosli attest pullrequest github`.
2. **Policy** (`four-eyes.rego`) — a Rego policy evaluated by Kosli against the attested PR data, producing pass/fail results and violation messages.

## How it works

```
node dist/index.js --repo /path/to/repo
  │
  ├─ for each commit in BASE_TAG..CURRENT_TAG (--first-parent):
  │    kosli begin trail <sha> --flow <flow> --commit <sha>
  │    kosli attest pullrequest github --name pr-review --commit <sha> ...
  │
  └─ (Kosli stores PR data: commits, approvers, merge commit SHA)

kosli evaluate trails SHA1 SHA2 ... --policy four-eyes.rego --flow <flow>
  │
  └─ OPA evaluates four-eyes.rego against input.trails[]
       → allow (bool) + violations[] (strings)
```

The collector's only job is trail creation and PR attestation. All evaluation logic lives in `four-eyes.rego`, so rules can be updated independently of the data collection code.

## Evaluation rules

Each commit trail is checked in order; the first matching rule determines its status:

1. **Service account** — the git commit author matches a service account pattern → PASS (no PR required)
2. **No PR** — no merged PR found for the commit → FAIL
3. **Independent approval** — the PR must have at least one approval from someone who did not author any PR commit, and that approval must come after the last code commit in the PR → PASS or FAIL

Merge commits (where `pr.merge_commit == trail.name`) are treated the same as regular commits for the approval check, but the person who clicked Merge is not counted as a code author.

PR commits authored by `GitHub <noreply@github.com>` (GitHub web-flow and Copilot co-authored commits) are exempt from the identity verification check.

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

### Service account exemptions

Service accounts are defined as a Rego set in `four-eyes.rego`. Patterns are matched against `trail.git_commit_info.author` (the `"Name <email>"` string from git) and also against `c.author` for individual PR commits:

```rego
service_account_patterns := {
    "svc_.*",
    ".*\\[bot\\]",
    "noreply@github.com",
}
```

| Pattern | Matches |
| :--- | :--- |
| `svc_.*` | Any author whose name starts with `svc_` |
| `.*\[bot\]` | GitHub App bots: `dependabot[bot]`, `github-actions[bot]`, `ci-signed-commit-bot[bot]`, etc. |
| `noreply@github.com` | GitHub web-flow commits and Copilot co-authored commit entries |

To add an exemption, add a regex pattern to the set in `four-eyes.rego`.

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

This creates one Kosli trail per commit in the range and attaches `pr-review` PR data to each trail (commits, approvers, merge commit SHA, timestamps).

### 2. Evaluate

```bash
kosli evaluate trails SHA1 SHA2 SHA3 \
  --policy four-eyes.rego \
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

The policy evaluates `input.trails[]` — one entry per commit. PR data is at:

```rego
input.trails[i].compliance_status.attestations_statuses["pr-review"]
```

Attested via: `kosli attest pullrequest github --name pr-review --commit <sha>`.

### Verifying the input shape

Use `--show-input` to inspect the exact data structure passed to the policy:

```bash
kosli evaluate trails SHA1 SHA2 \
  --policy four-eyes.rego \
  --show-input \
  --flow my-flow \
  --output json
```

### Policy tests

The policy is tested with OPA's built-in test runner. 25 test cases cover the full scenario matrix:

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
| `src/index.ts` | CLI entry point; walks the commit range; calls `kosli begin trail` and `kosli attest pullrequest github` per commit (p-limit 4 concurrent) |
| `src/baseTagResolver.ts` | Walks git history backward from `currentTag`; queries Kosli trails to find the most-recently-attested SHA |
| `src/kosli.ts` | Shells out to `kosli list trails --flow` and paginates results |
| `src/git.ts` | `execSync` wrappers for git log |
| `src/config.ts` | Validates required env vars; loads `.env` via dotenv |
| `four-eyes.rego` | Rego policy evaluating four-eyes compliance |
| `four-eyes_test.rego` | OPA unit tests (25 scenarios) |
