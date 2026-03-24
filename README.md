# Source Code Review Verification Tool

This tool verifies adherence to the "four-eyes principle" for code changes within a specified release range. It analyzes the git history between two tags, evaluates each commit against a set of rules (service accounts, exempted files, merge commits, or PR approvals), and generates a detailed JSON report.

## Features

- **Automated Commit Retrieval:** Fetches linear history from a specified release branch.
- **Rule-Based Evaluation:**
  - **Service Accounts:** Exempts commits from known automation accounts.
  - **Exempted Files:** Skips commits that only modify specific files (e.g., `package.json`, `README.md`).
  - **Merge Commits:** Automatically passes standard GitHub merge commits.
  - **PR Verification:** Ensures every other commit is linked to a merged Pull Request with at least one independent approval before the commit date.
- **Detailed Reporting:** Generates a JSON report with the status and reasoning for every commit.

## Prerequisites

- **Node.js**: Version 18 or higher.
- **Git**: Installed and available in the system path.
- **GitHub Token**: A Personal Access Token (PAT) with `repo` scope to read PRs and reviews.

## Installation

1.  Clone the repository.
2.  Install dependencies:
    ```bash
    npm install
    ```
3.  Build the project:
    ```bash
    npm run build
    ```

## Configuration

The tool requires both environment variables and a configuration file.

### 1. Environment Variables

Create a `.env` file in the root directory (see `.env.example` for a template):

| Variable | Description |
| :--- | :--- |
| `BASE_TAG` | The starting git tag (e.g., `v1.0.0`). Leave empty to start from the repository's beginning. |
| `CURRENT_TAG` | The ending git tag/release being evaluated (e.g., `v1.1.0`). |
| `GITHUB_REPOSITORY` | The owner and repository name (e.g., `owner/repo`). |
| `GITHUB_TOKEN` | Your GitHub Personal Access Token. |

### 2. Configuration File (`scr.config.json`)

Define exemptions in a `scr.config.json` file in the root directory:

```json
{
  "exemptions": {
    "serviceAccounts": ["svc_.*", "bot-account"],
    "filePaths": ["docs/release-notes.md"],
    "fileNames": ["package.json", "README.md", ".gitignore"]
  }
}
```

## Usage

After building the project, run the tool using:

```bash
npm start
```

### Specifying a Repository Path

You can specify the path to the repository to be scanned using the `--repo` argument:

```bash
npm start -- --repo /path/to/your/repository
```

(Note: The extra `--` is needed when using `npm start` to pass arguments to the underlying script).

Or, if using `node` directly:

```bash
node dist/index.js --repo /path/to/your/repository
```

Or, if installed as a dependency:

```bash
npx scr-verify --repo /path/to/your/repository
```

### Output

The tool will generate a report file named `att_report_<CURRENT_TAG>.json` in the root directory. If any commit fails the evaluation, the tool will exit with a non-zero status code (`1`).

## Development

### Running Tests

To run the unit test suite:

```bash
npm test
```

### Project Structure

- `src/index.ts`: Orchestration logic and entry point.
- `src/evaluator.ts`: Core "four-eyes" evaluation engine.
- `src/git.ts`: Git command wrappers.
- `src/github.ts`: GitHub API client.
- `src/reporter.ts`: JSON report generation.
- `tests/`: Comprehensive Jest unit tests.
