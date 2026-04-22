#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
export KOSLI_ORG="sofus-test"           # Kosli organisation name
TIMESTAMP=$(date -u +"%Y%m%d%H%M%S")   # Unique suffix for flow name
KOSLI_FLOW="cli-granular-demo-${TIMESTAMP}"             # Flow to create and populate
KOSLI_ATTESTATION_NAME="scr-data"       # Attestation name written to each trail

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

  # Run the collector for the entire commit range.
  # First iteration: pass explicit BASE_TAG.
  # Subsequent iterations: omit BASE_TAG so the collector auto-resolves it from
  # KOSLI_FLOW (the most recently attested commit in the flow).
  echo "  Running collector..."
  if [[ $i -eq 1 ]]; then
    BASE_TAG="${BASE_TAG}" \
    CURRENT_TAG="${CURRENT_TAG}" \
    GITHUB_REPOSITORY="${GITHUB_REPOSITORY}" \
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

  # Determine commits in range for Kosli trail operations.
  # The shell always uses the explicit tag pair here; this is equivalent to the
  # collector's resolved base since every commit in the previous range was attested.
  COMMITS=$(git -C "${REPO}" log "${BASE_TAG}..${CURRENT_TAG}" --first-parent --pretty=format:%H)
  CURRENT_SHA=$(git -C "${REPO}" rev-parse "${CURRENT_TAG}^{commit}")

  if [[ -z "${COMMITS}" ]]; then
    echo "  No commits in range — skipping"
    continue
  fi

  while IFS= read -r SHA; do
    echo ""
    echo "  ── Commit ${SHA:0:7} ──"

    # 1. Begin trail — named by commit SHA
    echo "  Beginning trail..."
    kosli begin trail "${SHA}" \
      --flow "${KOSLI_FLOW}" \
      --commit "${SHA}" \
      --repo-root "${REPO}"

    # 2. Attest core data + raw attachment to the trail
    ATT_FILE="${SCRIPT_DIR}/att_data_${SHA}.json"
    RAW_FILE="${SCRIPT_DIR}/raw_${SHA}.json"
    echo "  Attesting ${ATT_FILE}..."
    kosli attest custom \
      --type "${KOSLI_ATTESTATION_NAME}" \
      --name "${KOSLI_ATTESTATION_NAME}" \
      --attestation-data "${ATT_FILE}" \
      --attachments "${RAW_FILE}" \
      --trail "${SHA}" \
      --flow "${KOSLI_FLOW}"

    if [[ "${CLEANUP}" == "true" ]]; then
      rm -f "${ATT_FILE}" "${RAW_FILE}"
      echo "  Cleaned up ${ATT_FILE} and ${RAW_FILE}"
    fi
  done <<< "${COMMITS}"

  # 3. Evaluate all commit trails in this release range together.
  #    One call covers the entire release — Rego sees input.trails (array).
  echo ""
  echo "  Evaluating ${BASE_TAG} → ${CURRENT_TAG}..."
  TRAIL_LIST=$(echo "${COMMITS}" | tr '\n' ' ')
  EVAL_FILE="${SCRIPT_DIR}/eval_result_${CURRENT_TAG}.json"
  EVAL_EXIT=0
  kosli evaluate trails ${TRAIL_LIST} \
    --policy "${SCRIPT_DIR}/four-eyes.rego" \
    --show-input \
    --flow "${KOSLI_FLOW}" \
    --output json > "${EVAL_FILE}" 2>/dev/null || EVAL_EXIT=$?

  COMPLIANT_FLAG="true"
  if [[ "${EVAL_EXIT}" -ne 0 ]]; then
    echo "  Policy violations found — attesting as non-compliant"
    COMPLIANT_FLAG="false"
  fi

  # Build a lean summary from the full eval output.
  # The full eval_result file (including echoed input) is kept as an attachment.
  BASE_SHA=$(git -C "${REPO}" rev-parse "${BASE_TAG}^{commit}")
  EVALUATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  SUMMARY_FILE="${SCRIPT_DIR}/eval_summary_${CURRENT_TAG}.json"
  jq -n \
    --argjson allow "$(jq '.allow' "${EVAL_FILE}")" \
    --argjson violations "$(jq '.violations' "${EVAL_FILE}")" \
    --arg evaluated_at "${EVALUATED_AT}" \
    --arg repository "${GITHUB_REPOSITORY}" \
    --arg base_commit "${BASE_SHA}" \
    --arg current_commit "${CURRENT_SHA}" \
    '{allow: $allow, violations: $violations, evaluated_at: $evaluated_at, repository: $repository, base_commit: $base_commit, current_commit: $current_commit}' \
    > "${SUMMARY_FILE}"

  echo "  Attesting evaluation result (allow=${COMPLIANT_FLAG})..."

  # 4. Attest evaluation result to the trail for the current tag's commit SHA.
  #    The current tag's commit is always the topmost commit in the range, so
  #    its trail was already begun in the inner loop above.
  #    Compliance is driven by the --jq ".allow == true" rule on the type:
  #    allow: false → is_compliant: false. four-eyes.rego is attached as evidence.
  kosli attest custom \
    --type "four-eyes-result" \
    --name "four-eyes-result" \
    --attestation-data "${SUMMARY_FILE}" \
    --attachments "${SCRIPT_DIR}/four-eyes.rego,${EVAL_FILE}" \
    --trail "${CURRENT_SHA}" \
    --flow "${KOSLI_FLOW}"

  if [[ "${CLEANUP}" == "true" ]]; then
    rm -f "${EVAL_FILE}" "${SUMMARY_FILE}"
  fi

done

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Simulation complete — trails created in ${KOSLI_FLOW}"
echo "  https://app.kosli.com/${KOSLI_ORG}/flows/${KOSLI_FLOW}/trails"
echo "══════════════════════════════════════════════════════"
