#!/usr/bin/env bash
set -euo pipefail

# One-time setup: create (or recreate) the custom attestation type for scr-data.
# Run this after any change to jsonschema.json.
# If the type already exists it will be deleted and recreated with the new schema.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${KOSLI_API_TOKEN:-}" ]]; then
  echo "ERROR: KOSLI_API_TOKEN is not set" >&2
  exit 1
fi

echo "Creating scr-data attestation type with new per-commit schema..."
kosli create attestation-type scr-data \
  --description "Source code review data for never-alone four-eyes verification (per-commit)" \
  --schema "${SCRIPT_DIR}/jsonschema.json" \
  --org sofus-test

echo "Done — scr-data attestation type ready."
