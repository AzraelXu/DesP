#!/bin/bash
# Stage 5: trajectory alignment, RMSD analysis, and plots (CPU).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="${PIPELINE_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
PROJECT_DIR="${1:-${PROJECT_DIR:-}}"
[[ -n "$PROJECT_DIR" ]] || { echo "usage: $0 <project_dir>" >&2; exit 2; }

source "${PIPELINE_ROOT}/scripts/lib/common.sh"
load_project_env "$PROJECT_DIR"

stage_log_start "50_analysis"
P="$SYSTEM_NAME"

ALIGN_DIR="${PROJECT_DIR}/analysis/align"
RMSD_DIR="${PROJECT_DIR}/analysis/rmsd"
MD_DIR="${PROJECT_DIR}/desmond_md_job_${P}"
MD_OUT="${MD_DIR}/desmond_md_job_${P}-out.cms"
MD_TRJ="${MD_DIR}/desmond_md_job_${P}_trj"
ALIGNED_CMS="${ALIGN_DIR}/aligned_${P}-out.cms"
ALIGNED_TRJ="${ALIGN_DIR}/aligned_${P}_trj"

if stage_is_done analysis \
    && [[ -f "$ALIGNED_CMS" && -d "$ALIGNED_TRJ" ]] \
    && [[ -f "${RMSD_DIR}/${P}-out.eaf" ]] \
    && [[ -f "${RMSD_DIR}/${P}-out_Ligand_RMSD.csv" ]] \
    && ! force_stage analysis; then
    validate_cms "$ALIGNED_CMS"
    log SKIP "RMSD analysis already complete"
    finish_stage "50_analysis"
    exit 0
fi

if force_stage analysis; then
    archive_path "$ALIGN_DIR"
    archive_path "$RMSD_DIR"
    shopt -s nullglob
    for f in "${PROJECT_DIR}/results/${P}-out_"*; do
        archive_path "$f"
    done
    shopt -u nullglob
fi

rm -f "${PROJECT_DIR}/state/analysis.done"
mkdir -p "$ALIGN_DIR" "$RMSD_DIR"
require_file "$MD_OUT" "MD output CMS"
[[ -d "$MD_TRJ" ]] || die "MD trajectory directory not found: ${MD_TRJ}"
validate_cms "$MD_OUT"

log INFO "aligning trajectory on ASL: ${ALIGN_ASL}"
cd "$ALIGN_DIR"
"${SCHRODINGER}/run" trj_align.py \
    "$MD_OUT" \
    "$MD_TRJ" \
    "aligned_${P}" \
    -asl "$ALIGN_ASL"

require_file "$ALIGNED_CMS" "aligned CMS"
[[ -d "$ALIGNED_TRJ" ]] || die "aligned trajectory directory not found: ${ALIGNED_TRJ}"
validate_cms "$ALIGNED_CMS"

cd "$RMSD_DIR"

log INFO "generating EAF (protein=${RECEPTOR_ASL}; ligand=${LIGAND_ASL})"
"${SCHRODINGER}/run" event_analysis.py analyze \
    "$ALIGNED_CMS" \
    -prot "$RECEPTOR_ASL" \
    -lig "$LIGAND_ASL" \
    -out "$P"
require_file "${RMSD_DIR}/${P}-in.eaf" "event-analysis EAF"

log INFO "computing RMSD from EAF"
"${SCHRODINGER}/run" analyze_simulation.py \
    "$ALIGNED_CMS" \
    "$ALIGNED_TRJ" \
    "${P}-out.eaf" \
    "${P}-in.eaf" \
    -NOJOBID
require_file "${RMSD_DIR}/${P}-out.eaf" "RMSD EAF"

log INFO "computing ligand RMSD with Desmond LigandRMSD"
"${SCHRODINGER}/run" python3 "${PIPELINE_ROOT}/tools/compute_ligand_rmsd.py" \
    --cms "$ALIGNED_CMS" \
    --ligand-asl "$LIGAND_ASL" \
    --fit-asl "$ALIGN_ASL" \
    --output-dir "$RMSD_DIR" \
    --prefix "$P" \
    --traj-interval "$MD_TRAJ_INTERVAL_PS"

log INFO "generating XLSX/PNG plots"
"${SCHRODINGER}/run" python3 "${PIPELINE_ROOT}/tools/generate_rmsd_plots.py" \
    --traj-interval "$MD_TRAJ_INTERVAL_PS" \
    --output-dir "$RMSD_DIR" \
    "${P}-out.eaf"

mkdir -p "${PROJECT_DIR}/results"
cp -f "${RMSD_DIR}"/*.png "${PROJECT_DIR}/results/" 2>/dev/null || true
cp -f "${RMSD_DIR}"/*.xlsx "${PROJECT_DIR}/results/" 2>/dev/null || true
cp -f "${RMSD_DIR}"/*.csv "${PROJECT_DIR}/results/" 2>/dev/null || true

EXTRA_DONE_FIELDS="$(printf 'ALIGNED_CMS=%s\nTRAJ_INTERVAL_PS=%s' "$ALIGNED_CMS" "$MD_TRAJ_INTERVAL_PS")"
mark_done analysis "$ALIGNED_CMS"
finish_stage "50_analysis"
