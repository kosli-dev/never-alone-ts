# Implementation Plan: Custom Kosli Attestation Type for `scr-data`

## What changes and why

Currently `simulate.sh` uses `kosli attest generic` for the `scr-data` attestation. A custom attestation type lets Kosli validate the payload against `jsonschema.json` server-side every time data is attested — schema violations are caught at attestation time, not just during policy evaluation.

---

## Step 1 — Create the custom type (one-time, org-level)

New script `setup-kosli-attestation-type.sh`:

```bash
kosli create attestation-type scr-data \
  --description "Source code review data for never-alone four-eyes verification" \
  --schema jsonschema.json \
  --org sofus-test
```

- `TYPE-NAME` is `scr-data` — matches the existing `KOSLI_ATTESTATION_NAME` value
- `--schema jsonschema.json` — the schema already in the repo, used verbatim
- No `--jq` rules initially; the Rego policy handles compliance logic, so JQ rules would duplicate it

---

## Step 2 — Update `simulate.sh` (the per-run attestation call)

**Replace** in step 3 of the loop (lines 93–97 of `simulate.sh`):

```bash
# Before
kosli attest generic \
  --name "${KOSLI_ATTESTATION_NAME}" \
  --user-data "${ATT_FILE}" \
  --trail "${COMMIT_SHA}" \
  --flow "${KOSLI_FLOW}"
```

```bash
# After
kosli attest custom \
  --type "${KOSLI_ATTESTATION_NAME}" \
  --name "${KOSLI_ATTESTATION_NAME}" \
  --attestation-data "${ATT_FILE}" \
  --annotate repo="https://github.com/${GITHUB_REPOSITORY}" \
  --trail "${COMMIT_SHA}" \
  --flow "${KOSLI_FLOW}"
```

Key flag differences vs `attest generic`:

| | `attest generic` | `attest custom` |
| --- | --- | --- |
| type flag | (none) | `--type scr-data` |
| data flag | `--user-data` | `--attestation-data` |
| annotations | (none) | `--annotate key=value` (repeatable) |

The `four-eyes-result` attestation stays as `kosli attest generic` — it's a different payload with no schema to enforce.

---

## Step 3 — Annotations

Annotations are key-value metadata attached to the attestation via `--annotate key=value` (`stringToString` flag, repeatable — comma-separate multiple pairs or repeat the flag).

### Planned annotations

| Key | Value | Status |
| --- | --- | --- |
| `repo` | `https://github.com/${GITHUB_REPOSITORY}` | **included above** |
| _(more TBD)_ | | coming later |

### Notes

- `GITHUB_REPOSITORY` is already set in `simulate.sh` (e.g. `kosli-dev/cli`), so the URL expands at runtime without hard-coding.
- Annotations are surfaced in the Kosli UI alongside the attestation and are queryable in Rego policy via the attestation object.
- When additional annotation keys are decided, add another `--annotate key=${VALUE}` pair (or extend the existing `--annotate` as a comma-separated list) to the `attest custom` call.

---

## Files affected

| File | Action |
| --- | --- |
| `setup-kosli-attestation-type.sh` | **Create** — one-time setup script |
| `simulate.sh` | **Modify** — switch step 3 from `attest generic` to `attest custom` |
| `jsonschema.json` | Unchanged — used as-is for `--schema` |
