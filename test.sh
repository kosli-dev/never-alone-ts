#!/bin/bash
set -e
export KOSLI_ORG=sofus-test
export KOSLI_FLOW=never-alone
export KOSLI_API_TOKEN=
# Get the current git commit SHA
GIT_SHA=$(git rev-parse HEAD)
TRUNKATED_DATE=$(date +%s)

kosli begin trail ${GIT_SHA}$TRUNKATED_DATE --description "Trail A for commit ${GIT_SHA}"
kosli attest generic \
  --name scr-data \
  --user-data att_data_v2.11.46.json \
  --trail ${GIT_SHA}$TRUNKATED_DATE

kosli evaluate trail ${GIT_SHA}$TRUNKATED_DATE\
  --policy four-eyes.rego \
  --output json