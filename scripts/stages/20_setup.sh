#!/bin/bash
# Stage 2: Desmond system building (CPU): solvate, neutralize, add 0.15 M NaCl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="${PIPELINE_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
PROJECT_DIR="${1:-${PROJECT_DIR:-}}"
[[ -n "$PROJECT_DIR" ]] || { echo "usage: $0 <project_dir>" >&2; exit 2; }

source "${PIPELINE_ROOT}/scripts/lib/common.sh"
load_project_env "$PROJECT_DIR"
source "${PIPELINE_ROOT}/scripts/lib/msj.sh"

stage_log_start "20_setup"
P="$SYSTEM_NAME"

SETUP_DIR="${PROJECT_DIR}/desmond_setup_${P}"
OUT="${SETUP_DIR}/desmond_setup_${P}-out.cms"
IN="${PROJECT_DIR}/prepwizard/prepwizard-out.maegz"

if stage_is_done setup && [[ -f "$OUT" ]] && ! force_stage setup; then
    validate_cms "$OUT"
    check_asls "$OUT"
    log SKIP "Desmond setup already complete"
    finish_stage "20_setup"
    exit 0
fi

if force_stage setup; then
    archive_path "$SETUP_DIR"
fi

rm -f "${PROJECT_DIR}/state/setup.done"
mkdir -p "$SETUP_DIR"
require_file "$IN" "PrepWizard output"

MSJ="${SETUP_DIR}/desmond_setup_${P}.msj"
write_setup_msj "$MSJ"

log INFO "building Desmond system: forcefield=${FORCEFIELD} solvent=${SOLVENT} buffer=${BUFFER_SIZE} A salt=${SALT_CONC} M"
cd "$SETUP_DIR"

"${SCHRODINGER}/utilities/multisim" \
    -JOBNAME "desmond_setup_${P}" \
    -m "$MSJ" \
    "$IN" \
    -o "$OUT" \
    -HOST localhost \
    -WAIT

validate_cms "$OUT"
check_asls "$OUT"
mark_done setup "$OUT"
finish_stage "20_setup"
