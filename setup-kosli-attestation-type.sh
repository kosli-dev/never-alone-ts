#!/usr/bin/env bash
set -euo pipefail

# One-time setup: create the custom attestation type for scr-data.
# Run this once per Kosli org before using simulate.sh.

kosli create attestation-type scr-data \
  --description "Source code review data for never-alone four-eyes verification" \
  --schema jsonschema.json \
  --org sofus-test
