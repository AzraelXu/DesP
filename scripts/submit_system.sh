#!/bin/bash
# Submit one protein-ligand system as a chain of dependent PBS jobs.
#
#   prep (CPU) -> min (1 GPU) -> md (1 GPU) -> analysis (CPU)
#                                             \-> mmgbsa (CPU)
#
# Usage:
#   submit_system.sh systems/foo.conf [--dry-run]
#       [--from prep|min|md|analysis|mmgbsa]
#       [--force [prepwizard|setup|min|md|analysis|mmgbsa|all]]
#       [--restart-md] [--no-analysis] [--no-mmgbsa]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PIPELINE_ROOT
source "${PIPELINE_ROOT}/scripts/lib/common.sh"

ui_parse_color_args "$@" || exit $?
set -- "${UI_ARGS[@]+"${UI_ARGS[@]}"}"

usage() {
    cat <<'EOF'
Usage: submit_system.sh <system.conf> [options]

Options:
  --dry-run              Render PBS scripts and print qsub commands; do not submit.
                         NOTE: dry-run still freezes project.resolved.conf, copies
                         the input, and writes system.conf.snapshot/state/run.env.
  --from STAGE           Start from prep|min|md|analysis|mmgbsa (default: prep;
                         prepwizard/setup are accepted as aliases for prep)
  --force [STAGE]        Rerun STAGE and downstream stages, archiving old outputs.
                         Without STAGE, rerun everything. STAGE may be prepwizard,
                         setup, min, md, analysis, mmgbsa, or all.
  --restart-md           EXPERIMENTAL: resume a partial MD from its multisim
                         checkpoint (implies --from md; not combinable with
                         --force). Known to fail on interrupted production
                         stages in Schrodinger 2021-2; prefer a longer
                         PBS_WALLTIME_MD or split the MD. See README.md (known limitations).
  --no-analysis          Do not submit the RMSD analysis job
  --no-mmgbsa            Do not submit the MM-GBSA job
  --color MODE           auto (default), always, or never
  -h, --help             Show this help
EOF
}

SYS_CONF=""
DRY_RUN="no"
FROM_STAGE="prep"
FROM_EXPLICIT="no"
FORCE_ALL="no"
FORCE_ARG=""
RESTART_MD="no"
NO_ANALYSIS="no"
NO_MMGBSA="no"

while (( $# > 0 )); do
    case "$1" in
        --dry-run) DRY_RUN="yes"; shift ;;
        --from)
            [[ $# -ge 2 ]] || die "--from requires a stage"
            FROM_STAGE="$2"; FROM_EXPLICIT="yes"; shift 2 ;;
        --force)
            if [[ $# -ge 2 && "$2" != -* ]]; then
                FORCE_ARG="$2"; shift 2
            else
                FORCE_ALL="yes"; shift
            fi ;;
        --restart-md) RESTART_MD="yes"; shift ;;
        --no-analysis) NO_ANALYSIS="yes"; shift ;;
        --no-mmgbsa) NO_MMGBSA="yes"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*)
            usage
            die "unknown option: $1" ;;
        *)
            [[ -z "$SYS_CONF" ]] || die "only one system config is allowed"
            SYS_CONF="$1"; shift ;;
    esac
done

[[ -n "$SYS_CONF" ]] || { usage; die "system config is required"; }
[[ -z "${PBS_JOBID:-}" ]] || die "do not submit from inside a PBS job; run this on the login node"

case "$FROM_STAGE" in
    prep|min|md|analysis|mmgbsa) ;;
    prepwizard|setup) FROM_STAGE="prep" ;;
    *) die "--from must be prep, min, md, analysis, or mmgbsa (or prepwizard/setup as aliases): ${FROM_STAGE}" ;;
esac

if [[ "$RESTART_MD" == "yes" ]]; then
    if [[ "$FROM_EXPLICIT" == "yes" && "$FROM_STAGE" != "md" ]]; then
        die "--restart-md requires --from md (or no --from at all)"
    fi
    if [[ "$FORCE_ALL" == "yes" || -n "$FORCE_ARG" ]]; then
        die "--restart-md cannot be combined with --force"
    fi
    warn "EXPERIMENTAL: multisim -RESTART is known to fail for an interrupted production stage in Schrodinger 2021-2 (missing -in.cfg). Prefer a longer PBS walltime or split the MD; see README.md (known limitations)."
    FROM_STAGE="md"
fi

load_system_conf "$SYS_CONF"
if [[ "$NO_ANALYSIS" == "yes" ]]; then RUN_ANALYSIS="no"; fi
if [[ "$NO_MMGBSA" == "yes" ]]; then RUN_MMGBSA="no"; fi

# Stage-aware preflight: only require the binaries/licenses used by this chain.
PREFLIGHT_NEED_MULTISIM="no"
PREFLIGHT_NEED_PREPWIZARD="no"
PREFLIGHT_NEED_DESMOND="no"
PREFLIGHT_NEED_GPU="no"
case "$FROM_STAGE" in
    prep)
        PREFLIGHT_NEED_MULTISIM="yes"
        PREFLIGHT_NEED_DESMOND="yes"
        PREFLIGHT_NEED_GPU="yes"
        if [[ -z "${PREPARED_STRUCTURE:-}" && -n "${INPUT_STRUCTURE:-}" ]]; then
            PREFLIGHT_NEED_PREPWIZARD="yes"
        fi
        ;;
    min|md)
        PREFLIGHT_NEED_MULTISIM="yes"
        PREFLIGHT_NEED_DESMOND="yes"
        PREFLIGHT_NEED_GPU="yes"
        ;;
esac
if [[ "${RUN_MMGBSA:-yes}" == "yes" ]]; then
    PREFLIGHT_NEED_PRIME="yes"
else
    PREFLIGHT_NEED_PRIME="no"
fi
export PREFLIGHT_NEED_MULTISIM PREFLIGHT_NEED_PREPWIZARD \
       PREFLIGHT_NEED_DESMOND PREFLIGHT_NEED_GPU PREFLIGHT_NEED_PRIME

check_schrodinger
setup_schrodinger_env
require_command "$QSUB"
require_command "$QSTAT"
check_license_features

case "$FROM_STAGE" in
    analysis)
        [[ "$RUN_ANALYSIS" == "yes" ]] || die "analysis is disabled (RUN_ANALYSIS=no / --no-analysis)"
        ;;
    mmgbsa)
        [[ "$RUN_MMGBSA" == "yes" ]] || die "MM-GBSA is disabled (RUN_MMGBSA=no / --no-mmgbsa)"
        ;;
esac

P="$SYSTEM_NAME"
SETUP_CMS="${PROJECT_DIR}/desmond_setup_${P}/desmond_setup_${P}-out.cms"
MIN_CMS="${PROJECT_DIR}/desmond_min_job_${P}/desmond_min_job_${P}-out.cms"
MD_OUT="${PROJECT_DIR}/desmond_md_job_${P}/desmond_md_job_${P}-out.cms"
MD_CKPT="${PROJECT_DIR}/desmond_md_job_${P}/desmond_md_job_${P}-multisim_checkpoint"

case "$FROM_STAGE" in
    min) require_file "$SETUP_CMS" "setup output CMS (run --from prep first)" ;;
    md)  require_file "$MIN_CMS" "minimization output CMS (run --from min first)" ;;
    analysis|mmgbsa) require_file "$MD_OUT" "MD output CMS (run --from md first)" ;;
esac
if [[ "$RESTART_MD" == "yes" ]]; then
    require_file "$MD_CKPT" "multisim checkpoint for --restart-md"
fi

mkdir -p "${PROJECT_DIR}/inputs" "${PROJECT_DIR}/pbs" \
         "${PROJECT_DIR}/logs/pbs" "${PROJECT_DIR}/state" "${PROJECT_DIR}/results"

# ---------------------------------------------------------------------------
# Refuse to submit a second chain while earlier jobs are active.
# ---------------------------------------------------------------------------
if [[ -f "${PROJECT_DIR}/state/jobs.env" ]]; then
    active_jobs=()
    while IFS='=' read -r key id; do
        [[ "$key" =~ ^(PREP|MIN|MD|ANALYSIS|MMGBSA)_JOB$ ]] || continue
        [[ -n "$id" ]] || continue
        if ! qstat_out="$("$QSTAT" -f "$id" 2>&1)"; then
            if printf '%s\n' "$qstat_out" | grep -q 'Unknown Job Id'; then
                continue
            fi
            die "cannot query PBS job ${id}: ${qstat_out}"
        fi
        state="$(printf '%s\n' "$qstat_out" \
            | sed -n 's/^[[:space:]]*job_state = //p' | head -1)"
        if [[ "$state" == "Q" || "$state" == "R" || "$state" == "H" ]]; then
            active_jobs+=("${key}=${id}(${state})")
        fi
    done < "${PROJECT_DIR}/state/jobs.env"

    if (( ${#active_jobs[@]} > 0 )); then
        qdel_ids=()
        for entry in "${active_jobs[@]}"; do
            id="${entry#*=}"
            id="${id%%(*}"
            qdel_ids+=("$id")
        done
        die "existing PBS jobs are still queued/running/held: ${active_jobs[*]}. Wait for them, or cancel with: $QDEL ${qdel_ids[*]}"
    fi
fi

# ---------------------------------------------------------------------------
# Signature, seed, and force closure
# ---------------------------------------------------------------------------
RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"
SIGNATURE_NEW="$(compute_signature)"

old_seed=""
old_sig=""
if [[ -f "${PROJECT_DIR}/project.resolved.conf" ]]; then
    old_seed="$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${MD_SEED:-}"' _ "${PROJECT_DIR}/project.resolved.conf" || true)"
    old_sig="$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${SIGNATURE:-}"' _ "${PROJECT_DIR}/project.resolved.conf" || true)"
fi

config_seed="${MD_SEED:-}"
if [[ -n "$config_seed" ]]; then
    if [[ -n "$old_seed" && "$config_seed" != "$old_seed" ]]; then
        warn "MD_SEED changed from ${old_seed} to ${config_seed}; this affects new MD runs only"
    fi
    MD_SEED="$config_seed"
elif [[ -n "$old_seed" && "$old_seed" =~ ^[0-9]+$ ]]; then
    MD_SEED="$old_seed"
else
    MD_SEED="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
    [[ "$MD_SEED" =~ ^[0-9]+$ ]] || MD_SEED=$(( (RANDOM << 15) ^ RANDOM ))
fi
MIN_SEED="$MD_SEED"
export MD_SEED MIN_SEED

any_done="no"
if compgen -G "${PROJECT_DIR}/state/*.done" >/dev/null; then
    any_done="yes"
fi
allow_signature_change="no"
if [[ "$FORCE_ALL" == "yes" || -n "$FORCE_ARG" || "$RESTART_MD" == "yes" || "$FROM_EXPLICIT" == "yes" ]]; then
    allow_signature_change="yes"
fi
if [[ "$any_done" == "yes" && -n "$old_sig" && "$old_sig" != "$SIGNATURE_NEW" ]]; then
    if [[ "$allow_signature_change" != "yes" ]]; then
        die "input or parameters changed since the last run. Use --force (or an explicit --from) to acknowledge: old=${old_sig:0:12} new=${SIGNATURE_NEW:0:12}"
    fi
    warn "input/parameters changed since the last run; continuing because --force/--from was given"
fi

if [[ "$FORCE_ALL" == "yes" ]]; then
    FORCE_STAGES="prepwizard,setup,min,md,analysis,mmgbsa"
elif [[ -n "$FORCE_ARG" ]]; then
    case "$FORCE_ARG" in
        all) FORCE_STAGES="prepwizard,setup,min,md,analysis,mmgbsa" ;;
        prepwizard|prep) FORCE_STAGES="prepwizard,setup,min,md,analysis,mmgbsa" ;;
        setup) FORCE_STAGES="setup,min,md,analysis,mmgbsa" ;;
        min) FORCE_STAGES="min,md,analysis,mmgbsa" ;;
        md) FORCE_STAGES="md,analysis,mmgbsa" ;;
        analysis) FORCE_STAGES="analysis" ;;
        mmgbsa) FORCE_STAGES="mmgbsa" ;;
        *) die "--force stage must be prepwizard, setup, min, md, analysis, mmgbsa, or all" ;;
    esac
else
    FORCE_STAGES="${FORCE_STAGES:-}"
fi
if [[ "$RESTART_MD" == "yes" ]]; then
    # The resumed MD invalidates any previous downstream analysis.
    FORCE_STAGES="analysis,mmgbsa"
fi
export FORCE_STAGES RESTART_MD RUN_ANALYSIS RUN_MMGBSA

# ---------------------------------------------------------------------------
# Input inspection and self-contained input copy
# ---------------------------------------------------------------------------
STRUCT="${PREPARED_STRUCTURE:-$INPUT_STRUCTURE}"
require_file "$STRUCT" "input structure"
struct_report="${PROJECT_DIR}/state/structure_report_input.json"
inspect_out=""
if ! inspect_out="$(SCH_COLOR=never "$SCHRODINGER/run" python3 "${PIPELINE_ROOT}/scripts/inspect_structure.py" \
        --structure "$STRUCT" \
        --receptor-asl "$RECEPTOR_ASL" \
        --ligand-asl "$LIGAND_ASL" \
        --align-asl "$ALIGN_ASL" \
        --check --json-out "$struct_report" 2>&1)"; then
    printf '%s\n' "$inspect_out"
    die "input structure / ASL validation failed"
fi
printf '%s\n' "$inspect_out" | while IFS= read -r line; do
    log INFO "  ${line}"
done

input_base="$(basename "$STRUCT")"
input_copy="${PROJECT_DIR}/inputs/${input_base}"
if [[ ! -f "$input_copy" ]] || ! cmp -s "$STRUCT" "$input_copy"; then
    cp -fLp "$STRUCT" "$input_copy"
    log OK "copied input structure to ${input_copy}"
fi
sha256sum "$input_copy" > "${PROJECT_DIR}/inputs/sha256.txt"

if [[ -n "$PREPARED_STRUCTURE" ]]; then
    PREPARED_STRUCTURE="$input_copy"
    INPUT_STRUCTURE=""
else
    INPUT_STRUCTURE="$input_copy"
    PREPARED_STRUCTURE=""
fi
export INPUT_STRUCTURE PREPARED_STRUCTURE

# ---------------------------------------------------------------------------
# Freeze configuration
# ---------------------------------------------------------------------------
SIGNATURE="$SIGNATURE_NEW"
export SIGNATURE RUN_ID
freeze_config
cp -f "$SYSTEM_CONF" "${PROJECT_DIR}/system.conf.snapshot"

cat > "${PROJECT_DIR}/state/run.env" <<EOF
RUN_ID=${RUN_ID}
MD_SEED=${MD_SEED}
MIN_SEED=${MIN_SEED}
SIGNATURE=${SIGNATURE}
SUBMITTED_AT=$(_timestamp)
EOF

log INFO "system=${P} project=${PROJECT_DIR}"
log INFO "run_id=${RUN_ID} md_seed=${MD_SEED} signature=${SIGNATURE:0:12}"
log INFO "frozen config: ${PROJECT_DIR}/project.resolved.conf"

# ---------------------------------------------------------------------------
# Select stages and render PBS scripts
# ---------------------------------------------------------------------------
STAGE_ORDER=(prep min md analysis mmgbsa)
start_index=-1
for i in "${!STAGE_ORDER[@]}"; do
    if [[ "${STAGE_ORDER[$i]}" == "$FROM_STAGE" ]]; then
        start_index=$i
        break
    fi
done
(( start_index >= 0 )) || die "internal error: bad --from stage"

selected=()
for ((i = start_index; i < ${#STAGE_ORDER[@]}; i++)); do
    s="${STAGE_ORDER[$i]}"
    case "$s" in
        analysis) [[ "$RUN_ANALYSIS" == "yes" ]] || continue ;;
        mmgbsa) [[ "$RUN_MMGBSA" == "yes" ]] || continue ;;
    esac
    selected+=("$s")
done
(( ${#selected[@]} > 0 )) || die "no stages selected"

PBS_DIR="${PIPELINE_ROOT}/pbs"
STAGES_DIR="${PIPELINE_ROOT}/scripts/stages"
LAST_PBS_SCRIPT=""

render_stage() {
    local stage="$1"
    local template="$2"
    local jobprefix="$3"
    local ppn="$4"
    local wt="$5"
    local stage_script="$6"
    local job out pbs_out

    job="$(pbs_job_name "$jobprefix" "$SYSTEM_NAME")"
    out="${PROJECT_DIR}/pbs/${stage}.${RUN_ID}.pbs"
    pbs_out="${PROJECT_DIR}/logs/pbs/${stage}.${RUN_ID}.out"

    render_template "$template" "$out" \
        "JOBNAME=${job}" \
        "PPN=${ppn}" \
        "QUEUE_DIRECTIVE=$(queue_directive)" \
        "WALLTIME_DIRECTIVE=$(walltime_directive "$wt")" \
        "PBS_OUT=${pbs_out}" \
        "SYSTEM_NAME=${SYSTEM_NAME}" \
        "PIPELINE_ROOT=${PIPELINE_ROOT}" \
        "PROJECT_DIR=${PROJECT_DIR}" \
        "RUN_ID=${RUN_ID}" \
        "STAGE=${stage}" \
        "STAGE_SCRIPT=${stage_script}"

    check_ascii "$out"
    check_bash_syntax "$out"
    LAST_PBS_SCRIPT="$out"
    log INFO "rendered ${stage} PBS: ${out}"
}

prep_pbs=""
min_pbs=""
md_pbs=""
analysis_pbs=""
mmgbsa_pbs=""

for s in "${selected[@]}"; do
    case "$s" in
        prep)
            render_stage prep "${PBS_DIR}/prep.pbs.in" "mpP" \
                "$PBS_PPN_PREP" "$PBS_WALLTIME_PREP" ""
            prep_pbs="$LAST_PBS_SCRIPT"
            ;;
        min)
            render_stage min "${PBS_DIR}/gpu.pbs.in" "mpM" \
                1 "$PBS_WALLTIME_MIN" "${STAGES_DIR}/30_min.sh"
            min_pbs="$LAST_PBS_SCRIPT"
            ;;
        md)
            render_stage md "${PBS_DIR}/gpu.pbs.in" "mpD" \
                1 "$PBS_WALLTIME_MD" "${STAGES_DIR}/40_md.sh"
            md_pbs="$LAST_PBS_SCRIPT"
            ;;
        analysis)
            render_stage analysis "${PBS_DIR}/analysis.pbs.in" "mpA" \
                "$PBS_PPN_ANALYSIS" "$PBS_WALLTIME_ANALYSIS" ""
            analysis_pbs="$LAST_PBS_SCRIPT"
            ;;
        mmgbsa)
            render_stage mmgbsa "${PBS_DIR}/mmgbsa.pbs.in" "mpG" \
                "$PBS_PPN_MMGBSA" "$PBS_WALLTIME_MMGBSA" ""
            mmgbsa_pbs="$LAST_PBS_SCRIPT"
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == "yes" ]]; then
    echo
    header "================ submission plan: ${SYSTEM_NAME} ================"
    ui_kv "project" "$PROJECT_DIR" 13
    ui_kv "run id" "$RUN_ID" 13
    ui_kv "stages" "${selected[*]}" 13
    ui_kv "frozen config" "${PROJECT_DIR}/project.resolved.conf" 13
    echo
    for s in "${selected[@]}"; do
        case "$s" in
            prep) script="$prep_pbs" ;;
            min) script="$min_pbs" ;;
            md) script="$md_pbs" ;;
            analysis) script="$analysis_pbs" ;;
            mmgbsa) script="$mmgbsa_pbs" ;;
        esac
        header "--- ${s}: ${script}"
        grep '^#PBS' "$script" | sed 's/^/    /'
        echo
    done
    header "qsub chain (job IDs are filled in at real submission time):"
    prep_label=""
    min_label=""
    md_label=""
    for s in "${selected[@]}"; do
        case "$s" in
            prep)
                echo "  ${QSUB} ${prep_pbs}"
                prep_label="<prep_job>"
                ;;
            min)
                if [[ -n "$prep_label" ]]; then
                    echo "  ${QSUB} -W depend=afterok:${prep_label} ${min_pbs}"
                else
                    echo "  ${QSUB} ${min_pbs}"
                fi
                min_label="<min_job>"
                ;;
            md)
                if [[ -n "$min_label" ]]; then
                    echo "  ${QSUB} -W depend=afterok:${min_label} ${md_pbs}"
                else
                    echo "  ${QSUB} ${md_pbs}"
                fi
                md_label="<md_job>"
                ;;
            analysis)
                if [[ -n "$md_label" ]]; then
                    echo "  ${QSUB} -W depend=afterok:${md_label} ${analysis_pbs}"
                else
                    echo "  ${QSUB} ${analysis_pbs}"
                fi
                ;;
            mmgbsa)
                if [[ -n "$md_label" ]]; then
                    echo "  ${QSUB} -W depend=afterok:${md_label} ${mmgbsa_pbs}"
                else
                    echo "  ${QSUB} ${mmgbsa_pbs}"
                fi
                ;;
        esac
    done
    echo
    info "Dry run only; no jobs submitted."
    exit 0
fi

# ---------------------------------------------------------------------------
# Submit
# ---------------------------------------------------------------------------
prep_job=""
min_job=""
md_job=""
analysis_job=""
mmgbsa_job=""
LAST_JOB_ID=""

submit_one() {
    local stage="$1"
    local script="$2"
    local dep="${3:-}"
    local -a cmd=("$QSUB")
    if [[ -n "$dep" ]]; then cmd+=(-W "depend=afterok:${dep}"); fi
    cmd+=("$script")

    log INFO "submitting ${stage}: ${cmd[*]}"
    local out rc=0
    out="$(SCH_COLOR=never "${cmd[@]}" 2>&1)" || rc=$?
    if (( rc != 0 )); then
        log FATAL "qsub failed for ${stage} (rc=${rc}): ${out}"
        return 1
    fi
    out="$(printf '%s' "$out" | tr -d '\r')"
    log INFO "qsub ${stage} output: ${out}"
    local id
    id="$(printf '%s\n' "$out" | awk 'NF{print $NF}' | tail -1)"
    if [[ ! "$id" =~ ^[0-9]+(\.[A-Za-z0-9._-]+)?$ ]]; then
        log FATAL "unexpected qsub output for ${stage}: ${out}"
        return 1
    fi
    LAST_JOB_ID="$id"
}

write_jobs_env() {
    if [[ -f "${PROJECT_DIR}/state/jobs.env" ]]; then
        old_run="$(sed -n 's/^RUN_ID=//p' "${PROJECT_DIR}/state/jobs.env" | head -1 || true)"
        if [[ -n "$old_run" ]]; then
            cp -f "${PROJECT_DIR}/state/jobs.env" "${PROJECT_DIR}/state/jobs.${old_run}.env"
        fi
    fi
    cat > "${PROJECT_DIR}/state/jobs.env" <<EOF
RUN_ID=${RUN_ID}
PREP_JOB=${prep_job:-}
MIN_JOB=${min_job:-}
MD_JOB=${md_job:-}
ANALYSIS_JOB=${analysis_job:-}
MMGBSA_JOB=${mmgbsa_job:-}
SUBMITTED_AT=$(_timestamp)
EOF
}

submit_failed="no"
for s in "${selected[@]}"; do
    case "$s" in
        prep)
            submit_one prep "$prep_pbs" "" || { submit_failed="yes"; break; }
            prep_job="$LAST_JOB_ID"
            ;;
        min)
            dep="$prep_job"
            submit_one min "$min_pbs" "$dep" || { submit_failed="yes"; break; }
            min_job="$LAST_JOB_ID"
            ;;
        md)
            dep="$min_job"
            submit_one md "$md_pbs" "$dep" || { submit_failed="yes"; break; }
            md_job="$LAST_JOB_ID"
            ;;
        analysis)
            dep="$md_job"
            submit_one analysis "$analysis_pbs" "$dep" || { submit_failed="yes"; break; }
            analysis_job="$LAST_JOB_ID"
            ;;
        mmgbsa)
            dep="$md_job"
            submit_one mmgbsa "$mmgbsa_pbs" "$dep" || { submit_failed="yes"; break; }
            mmgbsa_job="$LAST_JOB_ID"
            ;;
    esac
done

write_jobs_env

if [[ "$submit_failed" == "yes" ]]; then
    ids=()
    if [[ -n "$prep_job" ]]; then ids+=("$prep_job"); fi
    if [[ -n "$min_job" ]]; then ids+=("$min_job"); fi
    if [[ -n "$md_job" ]]; then ids+=("$md_job"); fi
    if [[ -n "$analysis_job" ]]; then ids+=("$analysis_job"); fi
    if [[ -n "$mmgbsa_job" ]]; then ids+=("$mmgbsa_job"); fi
    die "submission chain incomplete. Already submitted job IDs: ${ids[*]:-none}. Cancel them with: $QDEL ${ids[*]:-}"
fi

log OK "submitted ${SYSTEM_NAME} run ${RUN_ID}"
echo
header "================ submitted: ${SYSTEM_NAME} ================"
printf '  %-10s %-14s %s\n' "stage" "PBS job id" "PBS stdout"
if [[ -n "$prep_job" ]]; then printf '  %-10s %-14s %s\n' "prep" "$prep_job" "${PROJECT_DIR}/logs/pbs/prep.${RUN_ID}.out"; fi
if [[ -n "$min_job" ]]; then printf '  %-10s %-14s %s\n' "min" "$min_job" "${PROJECT_DIR}/logs/pbs/min.${RUN_ID}.out"; fi
if [[ -n "$md_job" ]]; then printf '  %-10s %-14s %s\n' "md" "$md_job" "${PROJECT_DIR}/logs/pbs/md.${RUN_ID}.out"; fi
if [[ -n "$analysis_job" ]]; then printf '  %-10s %-14s %s\n' "analysis" "$analysis_job" "${PROJECT_DIR}/logs/pbs/analysis.${RUN_ID}.out"; fi
if [[ -n "$mmgbsa_job" ]]; then printf '  %-10s %-14s %s\n' "mmgbsa" "$mmgbsa_job" "${PROJECT_DIR}/logs/pbs/mmgbsa.${RUN_ID}.out"; fi
echo
next_steps ok \
    "${PIPELINE_ROOT}/scripts/status.sh ${SYSTEM_NAME}" \
    "${PIPELINE_ROOT}/scripts/collect_results.sh ${SYSTEM_NAME}"
debug "Logs   : ${PROJECT_DIR}/logs/"
rule "==========================================================="
