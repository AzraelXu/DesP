#!/bin/bash
# Stage 3: Desmond energy minimization / low-temperature relaxation (1 GPU).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="${PIPELINE_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
PROJECT_DIR="${1:-${PROJECT_DIR:-}}"
[[ -n "$PROJECT_DIR" ]] || { echo "usage: $0 <project_dir>" >&2; exit 2; }

source "${PIPELINE_ROOT}/scripts/lib/common.sh"
load_project_env "$PROJECT_DIR"
source "${PIPELINE_ROOT}/scripts/lib/msj.sh"

stage_log_start "30_min"
P="$SYSTEM_NAME"

MIN_DIR="${PROJECT_DIR}/desmond_min_job_${P}"
OUT="${MIN_DIR}/desmond_min_job_${P}-out.cms"
IN="${PROJECT_DIR}/desmond_setup_${P}/desmond_setup_${P}-out.cms"
ENGINE_LOG="${MIN_DIR}/desmond_min_job_${P}.log"

if stage_is_done min && [[ -f "$OUT" ]] && ! force_stage min; then
    validate_cms "$OUT"
    check_asls "$OUT"
    log SKIP "minimization already complete"
    finish_stage "30_min"
    exit 0
fi

if force_stage min; then
    archive_path "$MIN_DIR"
fi

rm -f "${PROJECT_DIR}/state/min.done"
mkdir -p "$MIN_DIR"
require_file "$IN" "setup output CMS"

CFG="${MIN_DIR}/desmond_min_job_${P}.cfg"
MSJ="${MIN_DIR}/desmond_min_job_${P}.msj"
write_min_cfg "$CFG"
write_min_msj "$MSJ" "$(basename "$CFG")"

log INFO "running Desmond minimization (GPU_LICENSE=${GPU_LICENSE})"
log INFO "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<unset>} SCHRODINGER_CUDA_VISIBLE_DEVICES=${SCHRODINGER_CUDA_VISIBLE_DEVICES:-<unset>}"
cd "$MIN_DIR"

"${SCHRODINGER}/utilities/multisim" \
    -JOBNAME "desmond_min_job_${P}" \
    -m "$MSJ" \
    -c "$CFG" \
    -HOST localhost \
    -maxjob 1 -cpu 1 \
    "$IN" \
    -mode umbrella \
    -o "$OUT" \
    -lic "$GPU_LICENSE" \
    -WAIT

validate_cms "$OUT" "${MIN_DIR}/desmond_min_job_${P}-in.cms"
check_asls "$OUT"
check_gpu_log "$ENGINE_LOG"

EXTRA_DONE_FIELDS="$(printf 'CHEMICAL_TIME_PS=%s' "$(md_log_value "$ENGINE_LOG" chemical_ps || echo unknown)")"
mark_done min "$OUT"
finish_stage "30_min"
