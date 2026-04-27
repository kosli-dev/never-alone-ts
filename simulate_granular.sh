#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
export KOSLI_ORG="sofus-test"           # Kosli organisation name
TIMESTAMP=$(date -u +"%Y%m%d%H%M%S")   # Unique suffix for flow name
KOSLI_FLOW="cli-granular-demo-${TIMESTAMP}"
KOSLI_ATTESTATION_NAME="pr-review"

CLEANUP="false"                          # Set to "false" to keep generated files

REPO="/home/sofus/git/cli"
GITHUB_REPOSITORY="kosli-dev/cli"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TAGS=(
  "v2.11.41"
  "v2.11.42"
  "v2.11.43"
  "v2.11.44"
  "v2.11.45"
  "v2.11.46"
  "v2.12.0"
  "v2.12.1"
  "v2.13.0"
  "v2.13.1"
)

# ── Pre-flight checks ─────────────────────────────────────────────────────────
if [[ -z "${KOSLI_API_TOKEN:-}" ]]; then
  echo "ERROR: KOSLI_API_TOKEN is not set" >&2
  exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "ERROR: GITHUB_TOKEN is not set" >&2
  exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/dist/index.js" ]]; then
  echo "dist/index.js not found — building never-alone..."
  npm --prefix "${SCRIPT_DIR}" run build
fi

# ── Create flow ───────────────────────────────────────────────────────────────
echo "Creating Kosli flow: ${KOSLI_FLOW}..."
kosli create flow "${KOSLI_FLOW}" \
  --description "Granular per-commit simulation against kosli-dev/cli" \
  --visibility private \
  --use-empty-template

# ── Process each tag pair ─────────────────────────────────────────────────────
for (( i=1; i<${#TAGS[@]}; i++ )); do
  BASE_TAG="${TAGS[$((i-1))]}"
  CURRENT_TAG="${TAGS[$i]}"

  echo ""
  echo "══════════════════════════════════════════════════════"
  echo "  ${BASE_TAG} → ${CURRENT_TAG}"
  echo "══════════════════════════════════════════════════════"

  # Begin trails and attest PR data for all commits in the range.
  # First iteration: pass explicit BASE_TAG.
  # Subsequent iterations: omit BASE_TAG so the collector auto-resolves it from
  # KOSLI_FLOW (the most recently attested commit in the flow).
  echo "  Beginning trails and attesting PRs..."
  if [[ $i -eq 1 ]]; then
    BASE_TAG="${BASE_TAG}" \
    CURRENT_TAG="${CURRENT_TAG}" \
    GITHUB_REPOSITORY="${GITHUB_REPOSITORY}" \
    KOSLI_FLOW="${KOSLI_FLOW}" \
    KOSLI_ATTESTATION_NAME="${KOSLI_ATTESTATION_NAME}" \
    node "${SCRIPT_DIR}/dist/index.js" \
      --repo "${REPO}"
  else
    CURRENT_TAG="${CURRENT_TAG}" \
    GITHUB_REPOSITORY="${GITHUB_REPOSITORY}" \
    KOSLI_FLOW="${KOSLI_FLOW}" \
    KOSLI_ATTESTATION_NAME="${KOSLI_ATTESTATION_NAME}" \
    node "${SCRIPT_DIR}/dist/index.js" \
      --repo "${REPO}"
  fi

  # Determine commits in range for the evaluation loop.
  COMMITS=$(git -C "${REPO}" log "${BASE_TAG}..${CURRENT_TAG}" --first-parent --pretty=format:%H)
  CURRENT_SHA=$(git -C "${REPO}" rev-parse "${CURRENT_TAG}^{commit}")

  if [[ -z "${COMMITS}" ]]; then
    echo "  No commits in range — skipping"
    continue
  fi

  while IFS= read -r SHA; do
    echo ""
    echo "  ── Commit ${SHA:0:7} ──"

    # Evaluate this single commit trail and attest the per-commit four-eyes result.
    COMMIT_EVAL_FILE="${SCRIPT_DIR}/commit_eval_${SHA}.json"
    kosli evaluate trails "${SHA}" \
      --policy "${SCRIPT_DIR}/four-eyes.rego" \
      --flow "${KOSLI_FLOW}" \
      --show-input \
      --output json > "${COMMIT_EVAL_FILE}" 2>/dev/null || true

    echo "  Attesting per-commit four-eyes result..."
    kosli attest custom \
      --type "four-eyes-result" \
      --name "four-eyes-result" \
      --attestation-data "${COMMIT_EVAL_FILE}" \
      --attachments "${SCRIPT_DIR}/four-eyes.rego" \
      --trail "${SHA}" \
      --flow "${KOSLI_FLOW}"

    if [[ "${CLEANUP}" == "true" ]]; then
      rm -f "${COMMIT_EVAL_FILE}"
    fi
  done <<< "${COMMITS}"

  # Begin a tag-level trail for the release-range four-eyes evaluation.
  echo ""
  echo "  Beginning tag trail ${CURRENT_TAG}..."
  kosli begin trail "${CURRENT_TAG}" \
    --flow "${KOSLI_FLOW}" \
    --commit "${CURRENT_SHA}" \
    --repo-root "${REPO}"

  # Evaluate all commit trails in this release range together.
  echo "  Evaluating ${BASE_TAG} → ${CURRENT_TAG}..."
  TRAIL_LIST=$(echo "${COMMITS}" | tr '\n' ' ')
  EVAL_FILE="${SCRIPT_DIR}/eval_result_${CURRENT_TAG}.json"
  kosli evaluate trails ${TRAIL_LIST} \
    --policy "${SCRIPT_DIR}/four-eyes.rego" \
    --show-input \
    --flow "${KOSLI_FLOW}" \
    --output json > "${EVAL_FILE}" 2>/dev/null || true

  echo "  Attesting release evaluation result to trail ${CURRENT_TAG}..."
  kosli attest custom \
    --type "four-eyes-result" \
    --name "four-eyes-result" \
    --attestation-data "${EVAL_FILE}" \
    --attachments "${SCRIPT_DIR}/four-eyes.rego" \
    --trail "${CURRENT_TAG}" \
    --flow "${KOSLI_FLOW}"

  if [[ "${CLEANUP}" == "true" ]]; then
    rm -f "${EVAL_FILE}"
  fi

done

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Simulation complete — trails created in ${KOSLI_FLOW}"
echo "  https://app.kosli.com/${KOSLI_ORG}/flows/${KOSLI_FLOW}/trails"
echo "══════════════════════════════════════════════════════"
