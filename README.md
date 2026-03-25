# Source Code Review Verification Tool

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
                                  │  --policy-file four-eyes.rego  │
                                  └───────────────────────────────┘
```

The collector gathers facts (commit authors, changed files, PR approvals, commit timestamps). All evaluation logic lives in `four-eyes.rego`, so rules can be updated independently of the data collection code.

## Evaluation rules

Each commit is checked in order; the first matching rule determines its status:

1. **Service account** — commit author matches a service account pattern → PASS
2. **Exempted files** — all changed files are exempted by path or filename → PASS
3. **Merge commit** — GitHub merge commit (multiple parents or `Merge pull request #` message) → PASS
4. **PR approval** — commit is linked to a merged PR with at least one independent approval after the latest code commit → PASS / else FAIL

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

| Variable | Description |
| :--- | :--- |
| `BASE_TAG` | Starting git tag. Leave empty to start from the first commit. |
| `CURRENT_TAG` | Ending git tag (the release being evaluated). |
| `GITHUB_REPOSITORY` | Repository in `owner/repo` format. |
| `GITHUB_TOKEN` | GitHub Personal Access Token. |

### 2. `scr.config.json`

Place `scr.config.json` in the root of the repository being scanned:

```json
{
  "exemptions": {
    "serviceAccounts": ["svc_.*", "bot-account"],
    "filePaths": ["docs/release-notes.md"],
    "fileNames": ["package.json", "README.md", ".gitignore"]
  }
}
```

The exemptions are embedded in the attestation output and read by the Rego policy at evaluation time.

## Usage

### 1. Collect data

```bash
npm start -- --repo /path/to/your/repository
```

This produces `att_data_<CURRENT_TAG>.json` in the working directory.

### 2. Attest to a Kosli trail

```bash
kosli attest generic \
  --name scr-data \
  --user-data att_data_v2.11.46.json \
  --trail release-v1.2.3
```

### 3. Evaluate

```bash
kosli evaluate trail release-v1.2.3 \
  --policy four-eyes.rego \
  --output json > eval-result.json
```

Exit code `0` = all commits comply. Exit code `1` = violations found.

### 4. (Optional) Record the evaluation result

```bash
kosli attest generic \
  --name four-eyes-result \
  --user-data eval-result.json
  --attachment four-eyes.rego \
  --trail release-v1.2.3
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
  --policy-file four-eyes.rego \
  --show-input \
  --output json
```

The attestation path in the policy (`input.trail.attestations["scr-data"].payload`) may need adjusting based on your Kosli setup.

## Development

### Running tests

```bash
npm test
```

### Project structure

- `src/index.ts` — entry point and orchestration
- `src/evaluator.ts` — `Collector` class: fetches commit and PR data
- `src/git.ts` — git command wrappers
- `src/github.ts` — GitHub API client
- `src/reporter.ts` — writes the attestation JSON file
- `src/config.ts` — loads configuration from env vars and `scr.config.json`
- `four-eyes.rego` — Rego policy for evaluating four-eyes compliance
- `tests/` — Jest unit tests
