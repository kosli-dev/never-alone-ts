# Implementation Questions

Please provide answers to the following questions to help guide the implementation:

1. **Execution Mode:** Should I implement this as a CLI application that can be run via `npx` or a similar command?
Yes, and please write it in Typescript.
2. **Library Preferences:** Are `exceljs` (for Excel generation) and `@octokit/rest` (for GitHub API interaction) acceptable choices?
I have removed excell request.
3. **File Path Resolution:** Should the `filePaths` defined in `scr.config.json` be interpreted as relative to the root of the git repository?
Yes
4. **Report Naming Conventions:** Should the `<tag_version>` in the JSON report filename be derived from the `CURRENT_TAG` environment variable, and `<service_version>` in the Excel filename from the `SERVICE_NAME` variable?
Yes
5. **Error Handling Policy:** Should the tool terminate with a non-zero exit code upon encountering critical errors (e.g., missing configuration, API failures)?
Yes
6. **Report Archiving:** Is it correct to assume that the CI/CD environment handles the archiving of the generated reports, or should the tool include logic for uploading them?
Yes
7. **PR Search Logic:** If the GitHub Search API returns multiple merged Pull Requests for a single commit SHA, how should the tool proceed? (e.g., check all, or just the first one?)
Write a pros/cons ADR on this one.
