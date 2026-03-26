#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
export KOSLI_ORG="sofus-test"           # Kosli organisation name

KOSLI_FLOW="cli-simulation-x1"             # Flow to create and populate
KOSLI_ATTESTATION_NAME="scr-data"       # Attestation name written to each trail

CLEANUP="false"                          # Set to "false" to keep att_data_*.json files

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

if [[ ! -f "${SCRIPT_DIR}/dist/index.js" ]]; then
  echo "dist/index.js not found — building never-alone..."
  npm --prefix "${SCRIPT_DIR}" run build
fi

# ── Create flow (idempotent — safe to re-run) ─────────────────────────────────
echo "Creating Kosli flow: ${KOSLI_FLOW}..."
kosli create flow "${KOSLI_FLOW}" \
  --description "Simulation of never-alone SCR verification against kosli-dev/cli" \
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

  COMMIT_SHA=$(git -C "${REPO}" rev-parse "${CURRENT_TAG}")
  echo "  Commit: ${COMMIT_SHA}"

  # 1. Begin trail — full SHA as trail name, linked to the git commit
  echo "  Beginning trail..."
  kosli begin trail "${COMMIT_SHA}" \
    --flow "${KOSLI_FLOW}" \
    --commit "${COMMIT_SHA}" \
    --description "Trail for ${CURRENT_TAG}" \
    --repo-root "${REPO}"

  # 2. Run never-alone collector
  echo "  Running collector..."
  BASE_TAG="${BASE_TAG}" \
  CURRENT_TAG="${CURRENT_TAG}" \
  GITHUB_REPOSITORY="${GITHUB_REPOSITORY}" \
  node "${SCRIPT_DIR}/dist/index.js" \
    --repo  "${REPO}" \
    --config "scr.config.json"

  # 3. Attest the collected data to the trail
  ATT_FILE="${SCRIPT_DIR}/att_data_${CURRENT_TAG}.json"
  echo "  Attesting ${ATT_FILE}..."
  kosli attest generic \
    --name "${KOSLI_ATTESTATION_NAME}" \
    --user-data "${ATT_FILE}" \
    --trail "${COMMIT_SHA}" \
    --flow "${KOSLI_FLOW}"

  # 4. Evaluate the trail against the four-eyes policy
  EVAL_FILE="${SCRIPT_DIR}/eval_result_${CURRENT_TAG}.json"
  echo "  Evaluating trail..."
  kosli evaluate trail "${COMMIT_SHA}" \
    --policy "${SCRIPT_DIR}/four-eyes.rego" \
    --flow "${KOSLI_FLOW}" \
    --output json > "${EVAL_FILE}"

  # 5. Attest the evaluation result (with the policy file attached for auditability)
  echo "  Attesting evaluation result..."
  kosli attest generic \
    --name "four-eyes-result" \
    --user-data "${EVAL_FILE}" \
    --attachments "${SCRIPT_DIR}/four-eyes.rego" \
    --trail "${COMMIT_SHA}" \
    --flow "${KOSLI_FLOW}"

  # 6. Cleanup
  if [[ "${CLEANUP}" == "true" ]]; then
    rm -f "${ATT_FILE}" "${EVAL_FILE}"
    echo "  Cleaned up ${ATT_FILE} and ${EVAL_FILE}"
  fi
done

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Simulation complete — 9 trails created in ${KOSLI_FLOW}"
echo "  https://app.kosli.com/${KOSLI_ORG}/flows/${KOSLI_FLOW}/trails"
echo "══════════════════════════════════════════════════════"
