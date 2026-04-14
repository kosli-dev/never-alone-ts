# Plan: Remove File/Folder Exclusions from the SCR Control

## Goal

Remove the ability to exempt specific files or folders from the four-eyes review requirement.
The `filePaths` and `fileNames` exemption types are deleted entirely.
The `serviceAccounts` exemption is **not** affected by this change.

After this change the only ways a commit can pass without an independent PR approval are:
1. The author is a service account.
2. It is a merge commit.

---

## Files to change

### 1. `four-eyes.rego`

Remove the three Rego rules that implement file exemption logic and the guards that call them.

- **Delete** `is_exempt_file(file)` — first rule (lines 101–104): path equality check.
- **Delete** `is_exempt_file(file)` — second rule (lines 106–111): basename check.
- **Delete** `all_files_exempt(commit)` (lines 113–118).
- In the violation `"no associated PR"` (starts line 153): remove the `not all_files_exempt(commit)` guard (line 156).
- In the violation `"independent approval"` (starts line 165): remove the `not all_files_exempt(commit)` guard (line 168).
- Remove the comment block header `# Exemption checks (rules read from the attested config)` (lines 87–89) if it would be left describing only the service account rules — or retitle it to `# Service account exemption`.

### 2. `four-eyes_test.rego`

- Remove `"filePaths"` and `"fileNames"` keys from the `exemptions` helper object (lines 11–12), leaving only `"serviceAccounts"`.
- Delete test `test_exempt_filename_passes` (lines 64–67).
- Delete test `test_exempt_filepath_passes` (lines 70–73).
- Delete test `test_mixed_files_not_exempt` (lines 76–81).
- Remove the `# Exempted files` comment section header (lines 59–61).

### 3. `src/types.ts`

- In `Config.exemptions` (lines 8–12): remove the `filePaths: string[]` and `fileNames: string[]` lines.
- In `AttestationData.config.exemptions` (lines 77–81): remove the same two lines.

### 4. `src/config.ts`

- Remove the `filePaths` and `fileNames` lines from the returned `exemptions` object (lines 40–41).
- If `scr.config.json` is no longer needed for any other config, assess whether the file-existence check and JSON parse are still required. They remain needed as long as `serviceAccounts` is still read from the config file.

### 5. `jsonschema.json`

- In `config.exemptions.required` (line 48): remove `"filePaths"` and `"fileNames"` from the array.
- Delete the `filePaths` property definition (lines 56–60).
- Delete the `fileNames` property definition (lines 61–65).

### 6. `scr.config.json`

- Remove the `"filePaths"` key and its array value.
- Remove the `"fileNames"` key and its array value.

### 7. `tests/config.test.ts`

- Remove `filePaths` and `fileNames` from any mock config objects.
- Remove any assertions that reference `config.exemptions.filePaths` or `config.exemptions.fileNames`.

### 8. `tests/reporter.test.ts`

- Remove `filePaths` and `fileNames` from `mockConfig.exemptions`.
- If there is a test asserting `written.config.exemptions` equals the full mock, update the expected object to only contain `serviceAccounts`.

### 9. `README.md`

- Remove `filePaths` and `fileNames` entries from the example `scr.config.json` block.
- Remove the "Exempt files" row from the Exemptions table.
- Remove any prose that explains file/folder exemptions.

### 10. `CATALOGUE.md`

- Remove step 2 ("Are ALL changed files on the exempt list? → PASS") from the evaluation logic list (around line 106).
- Remove the `exemptions.filePaths` and `exemptions.fileNames` rows from the configuration reference table (around lines 249–251).
- Remove the "Exempt files" row from the Exemptions table (around line 268).
- Remove `filePaths` and `fileNames` from the attestation schema documentation block (around lines 368–372).

---

## Order of execution

1. `src/types.ts` — remove type fields first so TypeScript compiler flags all downstream usages.
2. `src/config.ts` — remove loading of the two fields.
3. `src/reporter.ts` — no code change needed; it passes `config.exemptions` through as-is, which will now be narrower.
4. `jsonschema.json` — tighten the schema.
5. `scr.config.json` — remove the fields from the example config.
6. `four-eyes.rego` — remove the Rego rules and violation guards.
7. `four-eyes_test.rego` — remove the exemption test cases.
8. `tests/config.test.ts` and `tests/reporter.test.ts` — update unit tests.
9. `README.md` and `CATALOGUE.md` — update documentation last.

---

## Verification

- `npm run build` (or `tsc --noEmit`) must pass with no type errors.
- `npm test` must pass — all file-exemption tests deleted, remaining tests green.
- `opa test four-eyes.rego four-eyes_test.rego` must pass — deleted Rego tests removed, remaining scenarios still passing.
