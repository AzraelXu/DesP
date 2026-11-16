#!/bin/bash
# Stage 6: MM-GBSA on selected MD frames (CPU, Prime subjobs on localhost).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="${PIPELINE_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
PROJECT_DIR="${1:-${PROJECT_DIR:-}}"
[[ -n "$PROJECT_DIR" ]] || { echo "usage: $0 <project_dir>" >&2; exit 2; }

source "${PIPELINE_ROOT}/scripts/lib/common.sh"
load_project_env "$PROJECT_DIR"

stage_log_start "60_mmgbsa"
P="$SYSTEM_NAME"

MM_DIR="${PROJECT_DIR}/analysis/mmgbsa"
MD_OUT="${PROJECT_DIR}/desmond_md_job_${P}/desmond_md_job_${P}-out.cms"

if stage_is_done mmgbsa && [[ -f "${MM_DIR}/summary.json" ]] && ! force_stage mmgbsa; then
    log SKIP "MM-GBSA already complete"
    finish_stage "60_mmgbsa"
    exit 0
fi

if force_stage mmgbsa; then
    archive_path "$MM_DIR"
    for f in "${PROJECT_DIR}/results/mmgbsa_summary.json" \
             "${PROJECT_DIR}/results/mmgbsa_summary.md"; do
        archive_path "$f"
    done
fi

rm -f "${PROJECT_DIR}/state/mmgbsa.done"
mkdir -p "$MM_DIR"
require_file "$MD_OUT" "MD output CMS"

if [[ ! "$MMGBSA_STEP_SIZE" =~ ^[1-9][0-9]*$ ]]; then
    die "MMGBSA_STEP_SIZE must be a positive integer: ${MMGBSA_STEP_SIZE}"
fi

# Desmond writes a frame at t=0 plus one per trajectory interval, so a run of
# MD_TIME_PS with interval MD_TRAJ_INTERVAL_PS has floor(MD_TIME_PS/interval)+1 frames.
total_frames="$(awk -v a="$MD_TIME_PS" -v b="$MD_TRAJ_INTERVAL_PS" 'BEGIN{printf "%d", a / b + 1}')"
(( total_frames > 0 )) || die "computed zero total frames from MD_TIME_PS=${MD_TIME_PS} and interval=${MD_TRAJ_INTERVAL_PS}"

if [[ -n "${MMGBSA_START_FRAME:-}" || -n "${MMGBSA_END_FRAME:-}" ]]; then
    start="${MMGBSA_START_FRAME:-0}"
    end="${MMGBSA_END_FRAME:-$total_frames}"
else
    window_ns="${MMGBSA_LAST_NS:-0}"
    if [[ -z "$window_ns" ]] || [[ "$window_ns" == "0" ]]; then
        start=0
    else
        if awk -v w="$window_ns" -v m="$MD_TIME_NS" 'BEGIN{exit !(w + 0 > m + 0)}'; then
            window_ns="$MD_TIME_NS"
        fi
        # First frame at or after (MD end - window), i.e. ceil(delta/interval).
        start="$(awk -v a="$MD_TIME_PS" -v w="$window_ns" -v i="$MD_TRAJ_INTERVAL_PS" 'BEGIN{
            d = a - w * 1000
            if (d < 0) d = 0
            printf "%d", (d + i - 1e-9) / i
        }')"
    fi
    end="$total_frames"
fi

if [[ ! "$start" =~ ^[0-9]+$ ]] || [[ ! "$end" =~ ^[0-9]+$ ]]; then
    die "invalid MM-GBSA frame range: start=${start} end=${end}"
fi
if (( end <= start )); then
    die "empty MM-GBSA frame range: start=${start} end=${end} (end is exclusive)"
fi

log INFO "MM-GBSA frames: start=${start} end=${end} (exclusive) step=${MMGBSA_STEP_SIZE} of ${total_frames} total"
log INFO "MM-GBSA host=localhost:${PBS_PPN_MMGBSA} NJOBS=${PBS_PPN_MMGBSA}"

cd "$MM_DIR"

"${SCHRODINGER}/run" thermal_mmgbsa.py \
    "$MD_OUT" \
    -HOST "localhost:${PBS_PPN_MMGBSA}" \
    -NJOBS "$PBS_PPN_MMGBSA" \
    -lig_asl "$LIGAND_ASL" \
    -frozen \
    -step_size "$MMGBSA_STEP_SIZE" \
    -j "mmgbsa_${P}" \
    -start_frame "$start" \
    -end_frame "$end"

csv_file="$(find "$MM_DIR" -maxdepth 1 -name '*prime-out.csv' -print -quit)"
if [[ -z "$csv_file" ]]; then
    csv_file="$(find "$MM_DIR" -maxdepth 1 -name '*.csv' -print -quit)"
fi
[[ -n "$csv_file" ]] || die "MM-GBSA produced no CSV in ${MM_DIR}"

"${SCHRODINGER}/run" python3 "${PIPELINE_ROOT}/tools/summarize_mmgbsa.py" \
    "$csv_file" \
    --output-dir "$MM_DIR" \
    --project "$P"

mkdir -p "${PROJECT_DIR}/results"
cp -f "${MM_DIR}/summary.md" "${PROJECT_DIR}/results/mmgbsa_summary.md"
cp -f "${MM_DIR}/summary.json" "${PROJECT_DIR}/results/mmgbsa_summary.json"

EXTRA_DONE_FIELDS="$(printf 'FRAME_START=%s\nFRAME_END=%s\nFRAME_STEP=%s\nCSV=%s' \
    "$start" "$end" "$MMGBSA_STEP_SIZE" "$csv_file")"
mark_done mmgbsa "$csv_file"
finish_stage "60_mmgbsa"
