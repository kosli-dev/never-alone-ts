# Agent Instructions: Source Code Review Verification

## Objective

Your task is to build a tool that verifies adherence to the "four-eyes principle" for code changes within a given release range. The tool will analyze the git history between two tags on a specific branch, evaluate each commit against a set of rules, and generate a detailed report of its findings.

## Core Logic

The process is as follows:

1.  **Initialization:** Read configuration from environment variables and the `scr.config.json` file.
2.  **Commit Retrieval:** Fetch the list of all git commits that are on the specified `RELEASE_BRANCH` and exist between the `BASE_TAG` and `CURRENT_TAG`.
3.  **Commit Evaluation:** For each commit in the list, perform an evaluation based on the rules defined in the "Evaluation Rules" section below. This will require interacting with the GitHub API to fetch details about Pull Requests and reviews.
4.  **Status Determination:** Determine an overall status for the control. If any single commit fails the evaluation, the overall status is `FAILED`. If all commits pass, the overall status is `PASSED`.
5.  **Report Generation:** Create two reports:
    *   A detailed JSON report that lists each commit and the result of its evaluation.
    *   An Excel spreadsheet that provides a human-readable summary of the evaluation.
6.  **Report Archiving:** The generated reports should be made available as downloadable artifacts within the execution environment (e.g., as GitHub workflow artifacts).

## Configuration

The tool must be configured via a combination of environment variables and a configuration file.

### Environment Variables

-   `SERVICE_NAME`: The name of the service being evaluated.
-   `RELEASE_BRANCH`: The branch that the release was created from (e.g., `main`).
-   `BASE_TAG`: The git tag representing the start of the comparison range. If this is empty, the comparison should start from the very first commit of the repository.
-   `CURRENT_TAG`: The git tag representing the end of the comparison range (the release being evaluated).
-   `RELEASE_COMMIT_SHA`: The commit SHA corresponding to the `CURRENT_TAG`.
-   `GITHUB_REPOSITORY`: The owner and repository name in the format `owner/repo`.
-   `GITHUB_TOKEN`: A GitHub token with sufficient permissions to read repository data, including commits, pull requests, and reviews.

### Configuration File (`scr.config.json`)

A file named `scr.config.json` must be present in the root directory. It defines evaluation exemptions.

**Example `scr.config.json`:**
```json
{
  "exemptions": {
    "serviceAccounts": [
      "svc_.*",
      "CPTCLDEG.*",
      "app-repo-plugin-default"
    ],
    "filePaths": [
      "docs/release-notes.md"
    ],
    "fileNames": [
      "pom.xml",
      "README.md",
      ".gitignore",
      "package.json",
      "package-lock.json"
    ]
  }
}
```

## Detailed Steps

### 1. Commit Retrieval

To get a clean, parsable list of commits, execute the following git command:

```bash
git log <BASE_TAG>..<CURRENT_TAG> --first-parent --pretty="format:%H||%an||%aI||%s" -- <RELEASE_BRANCH>
```

-   **`<BASE_TAG>..<CURRENT_TAG>`**: Defines the range of commits to analyze.
-   **`--first-parent`**: Crucial for ignoring commits from merged feature branches, providing a linear history of the `RELEASE_BRANCH` itself.
-   **`--pretty="format:%H||%an||%aI||%s"`**: Formats the output for easy parsing.
    -   `%H`: Full commit hash
    -   `%an`: Author name
    -   `%aI`: Author date (strict ISO 8601 format)
    -   `%s`: Commit subject
    -   `||`: A unique delimiter.
-   **`-- <RELEASE_BRANCH>`**: Ensures the log is only for the specified release branch.

## Evaluation Rules

Each commit must be evaluated in the following order. If a commit passes a rule, the evaluation for that commit stops, and it is marked as `PASS`.

1.  **Service Account Commit:**
    *   **Check:** Is the commit author's name a match for any of the regex patterns listed in the `serviceAccounts` array in `scr.config.json`?
    *   **Result:** If yes, the commit `PASSES`.

2.  **Exempted File Modification:**
    *   **Check:** First, get the list of files changed in the commit. Then, for each file, check if it meets the exemption criteria. The commit passes if *all* of its changed files are exempt.
    *   **Exemption Criteria:** A file is considered exempt if:
        1.  Its full path matches any of the strings in the `filePaths` array in `scr.config.json`.
        2.  Its basename (the filename itself) matches any of the strings in the `fileNames` array in `scr.config.json`.
    *   **Result:** If all files in the commit are exempt, the commit `PASSES`.

3.  **Merge Commit:**
    *   **Check:** Is the commit a merge commit created by GitHub? This can be determined by two primary methods:
        1.  **Parent Count:** The commit has more than one parent.
        2.  **Commit Message:** The commit message starts with `Merge pull request #`. This is the standard message used by GitHub when merging a pull request via the UI.
    *   **Result:** If it is a merge commit, the commit `PASSES`.

4.  **Pull Request Review:**
    *   **Check:** For any other commit, you must verify its associated Pull Request.
    *   **Steps:**
        1.  **Find the PR:** Use the GitHub Search API to find the merged PR for the commit. This is the most reliable method.
            *   **API Call:** `GET /search/issues?q=is:pr+is:merged+sha:<COMMIT_SHA>`
            *   This will return the PR that the commit was merged into.
        2.  **Verify Approval:** Verify that the Pull Request has at least one `APPROVED` review.
        3.  **Verify Independence:** Verify that at least one of the approvers is *not* the original commit author.
        4.  **Verify Timing:** Verify that the commit's author date is *earlier than* the date of the independent approval. Both dates should be parsed carefully as ISO 8601 timestamps.
    *   **Result:**
        *   If all steps are successful, the commit `PASSES`.
        *   If no associated PR is found, no approval is found, the approver is the same as the committer, or the commit is dated *after* the approval, the commit `FAILS`.

## Reporting

The tool must generate the following file:

1.  `att_report_<tag_version>.json`: A JSON file containing an array of objects, where each object represents a commit and includes:
    *   Commit SHA
    *   Author
    *   Date
    *   Commit Message
    *   Evaluation Status (`PASS` or `FAIL`)
    *   Reason for the status
    *   Associated Pull Request number (if applicable)


## Flow Diagram

```mermaid
graph TD
    A[Start] --> B{Read Environment Variables};
    B --> C{Read scr.config.json};
    C --> D{Get Git Commits between BASE_TAG and CURRENT_TAG on RELEASE_BRANCH};
    D --> E{For Each Commit};
    E --> F{Is Commit by Service Account?};
    F -- Yes --> G[Status: PASS (Service Account)];
    F -- No --> H{Are all changed files exempted?};
    H -- Yes --> I[Status: PASS (Exempted Files)];
    H -- No --> J{Is Commit a GitHub Merge?};
    J -- Yes --> K[Status: PASS (Merge Commit)];
    J -- No --> L{Was PR Independently Approved BEFORE Commit?};
    L -- Yes --> M[Status: PASS (PR Approved)];
    L -- No --> N[Status: FAIL (Review Failure)];
    G --> O{Collect Results};
    I --> O;
    K --> O;
    M --> O;
    N --> O;
    O --> P{All Commits Evaluated?};
    P -- Yes --> Q{Any Failed Commits?};
    Q -- Yes --> R[Overall Status: FAILED];
    Q -- No --> S[Overall Status: PASSED];
    R --> T[Generate JSON and Excel Reports];
    S --> T;
    T --> U[Archive Reports as Artifacts];
    U --> V[End];
```
