#!/bin/bash
# Stage 1: PrepWizard (CPU).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="${PIPELINE_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
PROJECT_DIR="${1:-${PROJECT_DIR:-}}"
[[ -n "$PROJECT_DIR" ]] || { echo "usage: $0 <project_dir>" >&2; exit 2; }

source "${PIPELINE_ROOT}/scripts/lib/common.sh"
load_project_env "$PROJECT_DIR"

stage_log_start "10_prepwizard"
P="$SYSTEM_NAME"

PW_DIR="${PROJECT_DIR}/prepwizard"
OUT="${PW_DIR}/prepwizard-out.maegz"

log INFO "INPUT_STRUCTURE=${INPUT_STRUCTURE:-<none>}"
log INFO "PREPARED_STRUCTURE=${PREPARED_STRUCTURE:-<none>}"

# Already prepared input: copy it into the canonical path and skip PrepWizard.
if [[ -n "$PREPARED_STRUCTURE" ]]; then
    if force_stage prepwizard; then
        archive_path "$PW_DIR"
    fi
    rm -f "${PROJECT_DIR}/state/prepwizard.done"
    mkdir -p "$PW_DIR"

    if [[ ! -f "$OUT" ]]; then
        cp -p "$PREPARED_STRUCTURE" "$OUT"
        log OK "copied prepared structure to ${OUT}"
    else
        log SKIP "prepared structure already present: ${OUT}"
    fi

    validate_cms "$OUT"
    check_asls "$OUT"
    mark_done prepwizard "$OUT"
    finish_stage "10_prepwizard"
    exit 0
fi

if stage_is_done prepwizard && [[ -f "$OUT" ]] && ! force_stage prepwizard; then
    validate_cms "$OUT"
    check_asls "$OUT"
    log SKIP "PrepWizard already complete"
    finish_stage "10_prepwizard"
    exit 0
fi

if force_stage prepwizard; then
    archive_path "$PW_DIR"
fi

rm -f "${PROJECT_DIR}/state/prepwizard.done"
mkdir -p "$PW_DIR"
require_file "$INPUT_STRUCTURE" "INPUT_STRUCTURE"
cd "$PW_DIR"

args=(
    -propka_pH "$PREPWIZARD_PH"
    -f "$FORCEFIELD"
    -HOST localhost
    -WAIT
)
if [[ "${PREPWIZARD_DISULFIDES:-yes}" == "yes" ]]; then args+=(-disulfides); fi
if [[ "$PREPWIZARD_MINIMIZE_ADJ_H" == "yes" ]]; then args+=(-minimize_adj_h); fi
if [[ "$PREPWIZARD_LABEL_PKAS" == "yes" ]]; then args+=(-label_pkas); fi
if [[ "$PREPWIZARD_FILLSIDECHAINS" == "yes" ]]; then args+=(-fillsidechains); fi
if [[ "$PREPWIZARD_FILLLOOPS" == "yes" ]]; then args+=(-fillloops); fi
if [[ "$PREPWIZARD_NOIMPREF" == "yes" ]]; then args+=(-noimpref); fi

log INFO "running PrepWizard (pH=${PREPWIZARD_PH}, forcefield=${FORCEFIELD}, disulfides=${PREPWIZARD_DISULFIDES:-yes})"
"${SCHRODINGER}/utilities/prepwizard" "$INPUT_STRUCTURE" "prepwizard-out.maegz" "${args[@]}"

validate_cms "$OUT"
check_asls "$OUT"
mark_done prepwizard "$OUT"
finish_stage "10_prepwizard"
