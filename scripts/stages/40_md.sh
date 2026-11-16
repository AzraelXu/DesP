#!/bin/bash
# Stage 4: Desmond production MD with standard NPT relaxation (1 GPU).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="${PIPELINE_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
PROJECT_DIR="${1:-${PROJECT_DIR:-}}"
[[ -n "$PROJECT_DIR" ]] || { echo "usage: $0 <project_dir>" >&2; exit 2; }

source "${PIPELINE_ROOT}/scripts/lib/common.sh"
load_project_env "$PROJECT_DIR"
source "${PIPELINE_ROOT}/scripts/lib/msj.sh"

stage_log_start "40_md"
P="$SYSTEM_NAME"

MD_DIR="${PROJECT_DIR}/desmond_md_job_${P}"
OUT="${MD_DIR}/desmond_md_job_${P}-out.cms"
TRJ="${MD_DIR}/desmond_md_job_${P}_trj"
ENGINE_LOG="${MD_DIR}/desmond_md_job_${P}.log"
CKPT="${MD_DIR}/desmond_md_job_${P}-multisim_checkpoint"
IN="${PROJECT_DIR}/desmond_min_job_${P}/desmond_min_job_${P}-out.cms"

is_complete() {
    [[ -f "$OUT" ]] || return 1
    [[ -d "$TRJ" ]] || return 1
    local chem
    chem="$(md_log_value "$ENGINE_LOG" chemical_ps || true)"
    [[ -n "$chem" ]] || return 1
    awk -v a="$chem" -v b="$MD_TIME_PS" 'BEGIN{exit !(a + 0 >= b * 0.99)}'
}

# Complete artifacts with a missing .done marker can be recovered after a
# crash between multisim finishing and mark_done.
if is_complete && ! force_stage md; then
    validate_cms "$OUT" "${MD_DIR}/desmond_md_job_${P}-in.cms"
    check_asls "$OUT"
    check_gpu_log "$ENGINE_LOG"
    if ! stage_is_done md; then
        log WARN "MD artifacts look complete but .done is missing; recording completion"
        chem="$(md_log_value "$ENGINE_LOG" chemical_ps || echo unknown)"
        rate="$(md_log_value "$ENGINE_LOG" ns_per_day || echo unknown)"
        EXTRA_DONE_FIELDS="$(printf 'CHEMICAL_TIME_PS=%s\nNS_PER_DAY=%s' "$chem" "$rate")"
        mark_done md "$OUT"
    else
        log SKIP "production MD already complete"
    fi
    finish_stage "40_md"
    exit 0
fi

if force_stage md; then
    archive_path "$MD_DIR"
    RESTART_MD="no"
fi

rm -f "${PROJECT_DIR}/state/md.done"
mkdir -p "$MD_DIR"
require_file "$IN" "minimization output CMS"

# A missing output but existing checkpoint/trajectory/tgz means a previous run
# was interrupted. Never silently start a fresh multi-day simulation over it.
if [[ "${RESTART_MD:-no}" != "yes" ]]; then
    if [[ -e "$CKPT" || -e "$TRJ" ]] || compgen -G "${MD_DIR}/desmond_md_job_${P}_*-out.tgz" >/dev/null; then
        die "partial MD output/checkpoint exists but RESTART_MD is not yes; use --restart-md to resume or --force md to archive and start fresh"
    fi
fi

common_args=(-HOST localhost -maxjob 1 -cpu 1)
if (( MD_MAX_WALLTIME_SEC > 0 )); then
    common_args+=(-max-walltime "$MD_MAX_WALLTIME_SEC")
fi

if [[ "${RESTART_MD:-no}" == "yes" ]]; then
    require_file "$CKPT" "multisim checkpoint"

    # A graceful -max-walltime stop leaves a halt marker. Remove it before
    # resuming, otherwise the restarted stage can halt again immediately.
    rm -f "${MD_DIR}/CHECKPOINT_WITH_RESTART_REQUESTED"

    # multisim removes the resolved -in.cfg after the first run. The restarted
    # production stage needs it; recreate it from the user .cfg.
    if [[ ! -f "${MD_DIR}/desmond_md_job_${P}-in.cfg" ]]; then
        if [[ -f "${MD_DIR}/desmond_md_job_${P}.cfg" ]]; then
            cp "${MD_DIR}/desmond_md_job_${P}.cfg" "${MD_DIR}/desmond_md_job_${P}-in.cfg"
            log WARN "recreated missing -in.cfg from desmond_md_job_${P}.cfg"
        else
            die "missing desmond_md_job_${P}-in.cfg and desmond_md_job_${P}.cfg; cannot restart"
        fi
    fi

    cd "$MD_DIR"
    probe_out="$("${SCHRODINGER}/utilities/multisim" -probe "$CKPT" 2>&1 || true)"
    log INFO "multisim -probe checkpoint:"
    while IFS= read -r line; do
        log INFO "  ${line}"
    done <<<"$probe_out"

    best_n=-1
    best_tgz=""
    shopt -s nullglob
    for f in "${MD_DIR}/desmond_md_job_${P}"_*-out.tgz; do
        base="$(basename "$f")"
        n="${base#desmond_md_job_${P}_}"
        n="${n%%-out.tgz}"
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        if (( n > best_n )); then
            best_n="$n"
            best_tgz="$f"
        fi
    done
    shopt -u nullglob

    [[ -n "$best_tgz" ]] || die "no stage-data tgz found for restart; use --force md to archive and start fresh"
    log INFO "restarting MD from checkpoint=${CKPT}"
    log INFO "restart stage data=${best_tgz}"

    "${SCHRODINGER}/utilities/multisim" \
        -RESTART "$CKPT" \
        -d "$best_tgz" \
        "${common_args[@]}" \
        -lic "$GPU_LICENSE" \
        -WAIT
else
    CFG="${MD_DIR}/desmond_md_job_${P}.cfg"
    MSJ="${MD_DIR}/desmond_md_job_${P}.msj"
    write_md_cfg "$CFG"
    write_md_msj "$MSJ" "$(basename "$CFG")"

    log INFO "starting production MD: ${MD_TIME_NS} ns at ${MD_TEMPERATURE} K"
    log INFO "trajectory interval=${MD_TRAJ_INTERVAL_PS} ps, cutoff=${MD_CUTOFF} A"
    log INFO "GPU_LICENSE=${GPU_LICENSE} CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<unset>}"

    cd "$MD_DIR"
    "${SCHRODINGER}/utilities/multisim" \
        -JOBNAME "desmond_md_job_${P}" \
        -m "$MSJ" \
        -c "$CFG" \
        "${common_args[@]}" \
        "$IN" \
        -mode umbrella \
        -o "$OUT" \
        -lic "$GPU_LICENSE" \
        -WAIT
fi

if [[ ! -f "$OUT" || ! -d "$TRJ" ]]; then
    if [[ -f "$CKPT" ]]; then
        log WARN "MD did not produce a complete -out.cms/_trj, but a checkpoint exists."
        log WARN "Resume with: scripts/submit_system.sh <system.conf> --from md --restart-md"
        exit 42
    fi
    die "MD output/trajectory missing and no checkpoint found"
fi

validate_cms "$OUT" "${MD_DIR}/desmond_md_job_${P}-in.cms"
[[ -d "$TRJ" ]] || die "trajectory directory not found: ${TRJ}"
check_asls "$OUT"
check_gpu_log "$ENGINE_LOG"

chem="$(md_log_value "$ENGINE_LOG" chemical_ps || true)"
rate="$(md_log_value "$ENGINE_LOG" ns_per_day || true)"
[[ -n "$chem" ]] || die "could not parse final Chemical time from ${ENGINE_LOG}"
log INFO "final chemical time: ${chem} ps (requested ${MD_TIME_PS} ps), last rate: ${rate:-unknown} ns/day"

if ! awk -v a="$chem" -v b="$MD_TIME_PS" 'BEGIN{exit !(a + 0 >= b * 0.99)}'; then
    log WARN "MD stopped before the requested time; checkpoint retained for restart."
    log WARN "resume with: scripts/submit_system.sh <system.conf> --from md --restart-md"
    exit 42
fi

EXTRA_DONE_FIELDS="$(printf 'CHEMICAL_TIME_PS=%s\nNS_PER_DAY=%s' "$chem" "${rate:-unknown}")"
mark_done md "$OUT"
finish_stage "40_md"
