# Source Code Review Verification Tool

## Note! This tool is in alpha, and is therefore subject to extensive changes.

This tool verifies adherence to the "four-eyes principle" for code changes within a specified release range. It is split into two parts:

1. **Collector** — a TypeScript CLI that fetches commit and PR data from git and the GitHub API, and writes a self-contained JSON attestation file.
2. **Policy** — a Rego policy (`four-eyes.rego`) that evaluates the attestation data and produces pass/fail results and violation messages.

The attestation file is attached to a Kosli trail; the policy is evaluated with `kosli evaluate trail`.

## How it works

```
┌─────────────────────────┐       ┌──────────────────────────────┐
│  never-alone (collector) │──────▶│  att_data_<tag>.json         │
│  npm start               │       │  (attested to Kosli trail)   │
└─────────────────────────┘       └──────────────┬───────────────┘
                                                  │
                                  ┌───────────────▼───────────────┐
                                  │  kosli evaluate trail          │
                                  │  --policy four-eyes.rego       │
                                  └───────────────────────────────┘
```

The collector gathers facts (commit authors, changed files, PR approvals, commit timestamps). All evaluation logic lives in `four-eyes.rego`, so rules can be updated independently of the data collection code.

## Evaluation rules

Each commit is checked in order; the first matching rule determines its status:

1. **Service account** — commit author matches a service account pattern → PASS
2. **Merge commit** — GitHub merge commit (multiple parents or `Merge pull request #` message) → PASS
3. **PR approval** — commit is linked to a merged PR with at least one independent approval after the latest code commit → PASS / else FAIL

For named test cases with git diagrams and expected outcomes for each rule, see [SCENARIOS.md](SCENARIOS.md).

## Prerequisites

- **Node.js** 18+
- **Git** available in PATH
- **GitHub Token** — Personal Access Token with `repo` scope
- **Kosli CLI** — for attesting and evaluating ([installation](https://docs.kosli.com/getting_started/))

## Installation

```bash
npm install
npm run build
```

## Configuration

### 1. Environment Variables

| Variable | Required | Description |
| :--- | :--- | :--- |
| `CURRENT_TAG` | Yes | The release being evaluated — a git tag or commit SHA. |
| `GITHUB_REPOSITORY` | Yes | Repository in `owner/repo` format. |
| `GITHUB_TOKEN` | Yes | GitHub Personal Access Token with `repo` scope. |
| `BASE_TAG` | No | Starting git tag or SHA. If omitted, the tool auto-resolves it from Kosli (requires `KOSLI_FLOW`). Falls back to the repository's first commit if nothing is found. |
| `KOSLI_FLOW` | No | Kosli flow name to search for the previous attestation when auto-resolving `BASE_TAG`. |
| `KOSLI_ATTESTATION_NAME` | No | Name of the attestation to look for in Kosli trails. Defaults to `scr-data`. |

### 2. `scr.config.json`

Place `scr.config.json` in the root of the repository being scanned:

```json
{
  "exemptions": {
    "serviceAccounts": ["svc_.*", "bot-account"]
  }
}
```

The exemptions are embedded in the attestation output and read by the Rego policy at evaluation time.

## Usage

### CLI flags

| Flag | Description |
| :--- | :--- |
| `--repo <path>` | Path to the git repository to analyse. Defaults to the current directory. |
| `--config <path>` | Path to `scr.config.json`. Defaults to `scr.config.json` in the current directory. |
| `--env-file <path>` | Path to a `.env` file to load. Defaults to dotenv's standard behaviour. |
| `--flow <name>` | Kosli flow name for auto-resolving `BASE_TAG`. Overrides `KOSLI_FLOW`. |

### 1. Collect data

**With explicit base tag:**
```bash
BASE_TAG=v1.0.0 CURRENT_TAG=v1.1.0 npm start -- --repo /path/to/repo
```

**With auto-resolved base tag:**
```bash
CURRENT_TAG=v1.1.0 npm start -- --repo /path/to/repo --flow my-kosli-flow
```

When `--flow` is provided and `BASE_TAG` is not set, the tool queries Kosli for the most recent commit in the git history that has a trail with the target attestation, and uses that as the base. If none is found it falls back to the repository's first commit.

This produces `att_data_<CURRENT_TAG>.json` in the working directory.

### 2. Attest to a Kosli trail

```bash
kosli attest generic \
  --name scr-data \
  --user-data att_data_v1.1.0.json \
  --flow my-kosli-flow \
  --trail release-v1.1.0
```

### 3. Evaluate

```bash
kosli evaluate trail release-v1.1.0 \
  --policy four-eyes.rego \
  --flow my-kosli-flow \
  --output json > eval-result.json
```

Exit code `0` = all commits comply. Exit code `1` = violations found.

### 4. (Optional) Record the evaluation result

Use `--compliant=false` when the policy found violations (exit code `1`):

```bash
kosli attest generic \
  --name four-eyes-result \
  --user-data eval-result.json \
  --attachments four-eyes.rego \
  --compliant=false \
  --flow my-kosli-flow \
  --trail release-v1.1.0
```

## Policy: `four-eyes.rego`

The policy implements the four-eyes evaluation rules in Rego. It reads exemption configuration from the attested data so that `scr.config.json` remains the single source of truth.

### Behaviour: `post_approval_merge_commits`

A constant at the top of `four-eyes.rego` controls how merge-from-base commits are handled:

```rego
post_approval_merge_commits := "ignore"  # or "strict"
```

| Value | Behaviour |
| :--- | :--- |
| `ignore` | Merge-from-base commits (e.g. `Merge branch 'main' into feature-x`) are excluded from the approval timing check. Such commits only bring in content already reviewed on the base branch. |
| `strict` | Any commit after the last approval causes a failure, including merge-from-base commits. |

### Verifying the input shape

Use `--show-input` to inspect the exact data structure passed to the policy:

```bash
kosli evaluate trail release-v1.2.3 \
  --policy four-eyes.rego \
  --show-input \
  --output json
```

Generic attestation user-data is available at `input.trail.compliance_status.attestations_statuses["scr-data"].user_data`. Use `--show-input` to verify the exact structure in your environment.

## Documentation

| Document | Description |
| :--- | :--- |
| [CATALOGUE.md](CATALOGUE.md) | Full control specification: intent, data collection flow, evaluation logic, configuration reference, exemptions, limitations, failure remediation, and attestation schema. |
| [SCENARIOS.md](SCENARIOS.md) | Named test cases with git diagrams and expected pass/fail outcomes, grouped by theme. |

---

## Development

### Running tests

```bash
npm test
```

### Project structure

- `src/index.ts` — entry point and orchestration
- `src/evaluator.ts` — `Collector` class: fetches commit and PR data
- `src/baseTagResolver.ts` — auto-resolves `BASE_TAG` from Kosli trail history
- `src/kosli.ts` — `KosliClient`: shells out to the Kosli CLI to list trails
- `src/git.ts` — git command wrappers
- `src/github.ts` — GitHub API client
- `src/reporter.ts` — writes the attestation JSON file
- `src/config.ts` — loads configuration from env vars and `scr.config.json`
- `four-eyes.rego` — Rego policy for evaluating four-eyes compliance
- `tests/` — Jest unit tests
