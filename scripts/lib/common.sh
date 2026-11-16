#!/bin/bash
# Shared helpers: configuration, logging, state, validation, rendering.
# This file is sourced, never executed directly.

if [[ -z "${PIPELINE_ROOT:-}" ]]; then
    _common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PIPELINE_ROOT="$(cd "${_common_dir}/../.." && pwd)"
    export PIPELINE_ROOT
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
    local level="$1"
    shift
    local line
    line="[${level}] $(_timestamp) $*"
    printf '%s\n' "$line"
    if [[ -n "${PROJECT_DIR:-}" && -d "${PROJECT_DIR}/logs" ]]; then
        printf '%s\n' "$line" >> "${PROJECT_DIR}/logs/pipeline.log" 2>/dev/null || true
    fi
}

warn() { log WARN "$*"; }

die() {
    log FATAL "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------
resolve_path() {
    local p="$1"
    local base="$2"
    if [[ -z "$p" ]]; then
        printf ''
        return 0
    fi
    if [[ "$p" = /* ]]; then
        printf '%s' "$p"
    else
        printf '%s/%s' "$base" "$p"
    fi
}

require_file() {
    local f="$1"
    local label="${2:-file}"
    [[ -f "$f" ]] || die "${label} not found: $f"
    [[ -s "$f" ]] || die "${label} is empty: $f"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "command not found: $1"
}

walltime_to_sec() {
    local t="$1"
    if [[ "$t" =~ ^([0-9]+):([0-9]{2}):([0-9]{2})$ ]]; then
        printf '%s' $((10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]}))
    else
        printf '0'
    fi
}

job_slug() {
    local s="${1//[^A-Za-z0-9_]/_}"
    printf '%s' "${s:0:8}"
}

pbs_job_name() {
    printf '%s_%s' "$1" "$(job_slug "$2")"
}

# ---------------------------------------------------------------------------
# Configuration loading
# ---------------------------------------------------------------------------
load_system_conf() {
    local sysconf="$1"
    [[ -f "$sysconf" ]] || die "system config not found: $sysconf"

    SYSTEM_CONF="$(readlink -f "$sysconf")"
    SYSTEM_CONF_DIR="$(dirname "$SYSTEM_CONF")"

    # config.sh uses ${VAR:-default}, so environment overrides are honoured.
    source "${PIPELINE_ROOT}/config.sh"
    # Per-system overrides.
    source "$SYSTEM_CONF"

    : "${SYSTEM_NAME:?SYSTEM_NAME is required in ${SYSTEM_CONF}}"
    if [[ "$SYSTEM_NAME" == "." || "$SYSTEM_NAME" == ".." ]] \
        || [[ ! "$SYSTEM_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        die "SYSTEM_NAME must start with a letter/digit and contain only [A-Za-z0-9_.-]: ${SYSTEM_NAME}"
    fi

    INPUT_STRUCTURE="$(resolve_path "${INPUT_STRUCTURE:-}" "$SYSTEM_CONF_DIR")"
    PREPARED_STRUCTURE="$(resolve_path "${PREPARED_STRUCTURE:-}" "$SYSTEM_CONF_DIR")"

    if [[ -n "$PREPARED_STRUCTURE" ]]; then
        require_file "$PREPARED_STRUCTURE" "PREPARED_STRUCTURE"
    fi
    if [[ -n "$INPUT_STRUCTURE" ]]; then
        require_file "$INPUT_STRUCTURE" "INPUT_STRUCTURE"
    fi
    if [[ -z "$PREPARED_STRUCTURE" && -z "$INPUT_STRUCTURE" ]]; then
        die "Set INPUT_STRUCTURE or PREPARED_STRUCTURE in ${SYSTEM_CONF}"
    fi

    : "${RECEPTOR_ASL:?RECEPTOR_ASL is required in ${SYSTEM_CONF}}"
    : "${LIGAND_ASL:?LIGAND_ASL is required in ${SYSTEM_CONF}}"
    ALIGN_ASL="${ALIGN_ASL:-($RECEPTOR_ASL) and backbone and not (atom.ele H)}"

    PROJECT_DIR="${PROJECT_DIR:-${SCH_WORK_ROOT}/projects/${SYSTEM_NAME}}"
    if [[ "$PROJECT_DIR" != /* ]]; then
        PROJECT_DIR="${SCH_WORK_ROOT}/${PROJECT_DIR}"
    fi
    PROJECT_DIR="${PROJECT_DIR%/}"

    if [[ ! "$PROJECT_DIR" =~ ^[[:print:]]+$ ]] || LC_ALL=C grep -q '[^ -~]' <<<"$PROJECT_DIR"; then
        die "PROJECT_DIR must be printable ASCII because it is embedded into PBS scripts: ${PROJECT_DIR}"
    fi
    case "$PROJECT_DIR" in
        *' '*|*$'\t'*|*'"'*|*'$'*|*'`'*|*'\'*)
            die "PROJECT_DIR must not contain spaces, quotes, dollar signs, backticks, or backslashes: ${PROJECT_DIR}"
            ;;
    esac
    case "$PIPELINE_ROOT" in
        *' '*|*$'\t'*|*'"'*|*'$'*|*'`'*|*'\'*)
            die "PIPELINE_ROOT must not contain spaces, quotes, dollar signs, backticks, or backslashes: ${PIPELINE_ROOT}"
            ;;
    esac
    case "$SCH_WORK_ROOT" in
        *' '*|*$'\t'*|*'"'*|*'$'*|*'`'*|*'\'*)
            die "SCH_WORK_ROOT must not contain spaces, quotes, dollar signs, backticks, or backslashes: ${SCH_WORK_ROOT}"
            ;;
    esac

    # Numeric validation and derived values.
    awk -v x="$MD_TIME_NS" 'BEGIN{exit !(x+0 > 0)}' \
        || die "MD_TIME_NS must be a positive number: ${MD_TIME_NS}"
    awk -v x="$MD_TEMPERATURE" 'BEGIN{exit !(x+0 > 0)}' \
        || die "MD_TEMPERATURE must be a positive number: ${MD_TEMPERATURE}"
    awk -v x="$MD_TRAJ_INTERVAL_PS" 'BEGIN{exit !(x+0 > 0)}' \
        || die "MD_TRAJ_INTERVAL_PS must be a positive number: ${MD_TRAJ_INTERVAL_PS}"
    awk -v x="$MD_CUTOFF" 'BEGIN{exit !(x+0 > 0)}' \
        || die "MD_CUTOFF must be a positive number: ${MD_CUTOFF}"
    awk -v x="$BUFFER_SIZE" 'BEGIN{exit !(x+0 > 0)}' \
        || die "BUFFER_SIZE must be a positive number: ${BUFFER_SIZE}"

    MD_TIME_PS="$(awk -v t="$MD_TIME_NS" 'BEGIN{printf "%.1f", t * 1000}')"

    if [[ -n "${MD_SEED:-}" ]] && [[ ! "$MD_SEED" =~ ^[0-9]+$ ]]; then
        die "MD_SEED must be a non-negative integer or empty: ${MD_SEED}"
    fi

    if [[ "${MD_MAX_WALLTIME_SEC}" == "auto" ]]; then
        local wt_sec
        wt_sec="$(walltime_to_sec "${PBS_WALLTIME_MD:-}")"
        if (( wt_sec > 3600 )); then
            MD_MAX_WALLTIME_SEC=$((wt_sec - 1800))
        else
            MD_MAX_WALLTIME_SEC=0
        fi
    fi
    if [[ ! "$MD_MAX_WALLTIME_SEC" =~ ^[0-9]+$ ]]; then
        die "MD_MAX_WALLTIME_SEC must be auto, 0, or an integer number of seconds: ${MD_MAX_WALLTIME_SEC}"
    fi

    RUN_ANALYSIS="${RUN_ANALYSIS:-yes}"
    RUN_MMGBSA="${RUN_MMGBSA:-yes}"
    FORCE_STAGES="${FORCE_STAGES:-}"
    RESTART_MD="${RESTART_MD:-no}"
    SIGNATURE="${SIGNATURE:-}"

    export PIPELINE_ROOT SCH_WORK_ROOT GPU_LOCK_DIR PROJECT_DIR \
           SYSTEM_CONF SYSTEM_CONF_DIR SYSTEM_NAME
}

load_project_env() {
    local pdir="${1:-${PROJECT_DIR:-}}"
    [[ -n "$pdir" ]] || die "PROJECT_DIR is not set"
    [[ -d "$pdir" ]] || die "project directory not found: $pdir"

    PROJECT_DIR="$(readlink -f "$pdir")"
    local frozen="${PROJECT_DIR}/project.resolved.conf"
    [[ -f "$frozen" ]] || die "frozen configuration not found: ${frozen} (submit with submit_system.sh first)"

    source "$frozen"

    # New frozen configs set SCH_WORK_ROOT. Old frozen configs set WORK_ROOT;
    # migrate the value and then drop the legacy variable so it cannot leak
    # into child processes and collide with unrelated software.
    if [[ -z "${SCH_WORK_ROOT:-}" && -n "${WORK_ROOT:-}" ]]; then
        SCH_WORK_ROOT="$WORK_ROOT"
    fi
    unset WORK_ROOT
    : "${SCH_WORK_ROOT:?SCH_WORK_ROOT missing from frozen config}"
    : "${SYSTEM_NAME:?SYSTEM_NAME missing from frozen config}"
    : "${SCHRODINGER:?SCHRODINGER missing from frozen config}"
    : "${MD_TIME_PS:?MD_TIME_PS missing from frozen config}"
    : "${MD_SEED:?MD_SEED missing from frozen config}"

    # A frozen --force list belongs to the submitted PBS chain; manual
    # (non-PBS) stage runs must not inherit it and silently rerun stages.
    if [[ -z "${PBS_JOBID:-}" ]]; then
        FORCE_STAGES=""
    fi

    export PIPELINE_ROOT SCH_WORK_ROOT GPU_LOCK_DIR PROJECT_DIR SYSTEM_NAME
    export FORCE_STAGES RESTART_MD RUN_ANALYSIS RUN_MMGBSA

    setup_schrodinger_env
}

setup_schrodinger_env() {
    [[ -d "$SCHRODINGER" ]] || die "Schrodinger not found: ${SCHRODINGER}"

    export SCHRODINGER
    export PATH="${SCHRODINGER}:${SCHRODINGER}/utilities:${PATH:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
    export LC_ALL=C
    export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"

    # Empty values for these variables are harmful: an empty
    # SCHRODINGER_HOSTS makes jobcontrol fail with MMJOB_HOSTS_MISSING.
    if [[ -n "${SCHRODINGER_LICENSE_FILE:-}" ]]; then
        export SCHRODINGER_LICENSE_FILE
    else
        unset SCHRODINGER_LICENSE_FILE
    fi
    if [[ -n "${LM_LICENSE_FILE:-}" ]]; then
        export LM_LICENSE_FILE
    else
        unset LM_LICENSE_FILE
    fi
    if [[ -n "${SCHRODINGER_HOSTS:-}" ]]; then
        export SCHRODINGER_HOSTS
    else
        unset SCHRODINGER_HOSTS
    fi
}

# ---------------------------------------------------------------------------
# Frozen configuration
# ---------------------------------------------------------------------------
FREEZE_VARS=(
    PIPELINE_ROOT SCH_WORK_ROOT GPU_LOCK_DIR PROJECT_DIR SYSTEM_NAME SYSTEM_CONF SYSTEM_CONF_DIR
    SCHRODINGER SCHRODINGER_LICENSE_FILE LM_LICENSE_FILE SCHRODINGER_HOSTS
    QSUB QSTAT QDEL PBSNODES PBS_QUEUE
    PBS_PPN_PREP PBS_PPN_ANALYSIS PBS_PPN_MMGBSA
    PBS_WALLTIME_PREP PBS_WALLTIME_MIN PBS_WALLTIME_MD
    PBS_WALLTIME_ANALYSIS PBS_WALLTIME_MMGBSA
    GPU_LICENSE MD_MAX_WALLTIME_SEC
    PREPWIZARD_PH PREPWIZARD_DISULFIDES PREPWIZARD_FILLSIDECHAINS PREPWIZARD_FILLLOOPS
    PREPWIZARD_NOIMPREF PREPWIZARD_MINIMIZE_ADJ_H PREPWIZARD_LABEL_PKAS
    FORCEFIELD SOLVENT BUFFER_SIZE SALT_CONC
    MD_TIME_NS MD_TIME_PS MD_TEMPERATURE MD_TRAJ_INTERVAL_PS MD_CUTOFF
    MD_SEED MIN_SEED
    MMGBSA_LAST_NS MMGBSA_STEP_SIZE MMGBSA_START_FRAME MMGBSA_END_FRAME
    RUN_ANALYSIS RUN_MMGBSA
    INPUT_STRUCTURE PREPARED_STRUCTURE RECEPTOR_ASL LIGAND_ASL ALIGN_ASL
    RUN_ID FORCE_STAGES RESTART_MD SIGNATURE
)

freeze_config() {
    local out="${PROJECT_DIR}/project.resolved.conf"
    local tmp="${out}.tmp.$$"
    local v

    {
        printf '# Frozen by submit_system.sh at %s\n' "$(_timestamp)"
        printf '# Do not edit. Re-run submit_system.sh to create a new snapshot.\n'
        for v in "${FREEZE_VARS[@]}"; do
            if declare -p "$v" >/dev/null 2>&1; then
                printf 'export %s=%q\n' "$v" "${!v}"
            fi
        done
    } > "$tmp"

    mv "$tmp" "$out"
    chmod 644 "$out"
}

compute_signature() {
    local src="${PREPARED_STRUCTURE:-$INPUT_STRUCTURE}"
    {
        sha256sum "$src" | awk '{print "input_sha256 " $1}'
        printf 'system %s\n' "$SYSTEM_NAME"
        printf 'asl %s | %s | %s\n' "$RECEPTOR_ASL" "$LIGAND_ASL" "$ALIGN_ASL"
        printf 'prepwizard %s %s %s %s %s %s %s\n' \
            "$PREPWIZARD_PH" "$PREPWIZARD_DISULFIDES" "$PREPWIZARD_FILLSIDECHAINS" \
            "$PREPWIZARD_FILLLOOPS" "$PREPWIZARD_NOIMPREF" \
            "$PREPWIZARD_MINIMIZE_ADJ_H" "$PREPWIZARD_LABEL_PKAS"
        printf 'setup %s %s %s %s\n' "$FORCEFIELD" "$SOLVENT" "$BUFFER_SIZE" "$SALT_CONC"
        printf 'md %s %s %s %s %s\n' \
            "$MD_TIME_NS" "$MD_TEMPERATURE" "$MD_TRAJ_INTERVAL_PS" "$MD_CUTOFF" "$FORCEFIELD"
        printf 'analysis %s %s %s\n' "$RECEPTOR_ASL" "$LIGAND_ASL" "$ALIGN_ASL"
        printf 'mmgbsa %s %s %s %s\n' \
            "$MMGBSA_LAST_NS" "$MMGBSA_STEP_SIZE" "$MMGBSA_START_FRAME" "$MMGBSA_END_FRAME"
    } | sha256sum | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# Stage state
# ---------------------------------------------------------------------------
mark_done() {
    local stage="$1"
    local output="${2:-}"
    local dir="${PROJECT_DIR}/state"
    mkdir -p "$dir"
    {
        printf 'STAGE=%s\n' "$stage"
        printf 'STATUS=done\n'
        printf 'JOBID=%s\n' "${PBS_JOBID:-manual}"
        printf 'START=%s\n' "${STAGE_START:-}"
        printf 'END=%s\n' "$(_timestamp)"
        printf 'OUTPUT=%s\n' "$output"
        if [[ -n "${EXTRA_DONE_FIELDS:-}" ]]; then
            printf '%s\n' "$EXTRA_DONE_FIELDS"
        fi
    } > "${dir}/${stage}.done"
    log OK "stage ${stage} marked done"
}

stage_is_done() {
    [[ -f "${PROJECT_DIR}/state/$1.done" ]]
}

force_stage() {
    [[ ",${FORCE_STAGES:-}," == *",$1,"* ]]
}

archive_path() {
    local p="$1"
    [[ -e "$p" ]] || return 0
    local dst="${p}.bak.$(_timestamp | tr -d ' :-')"
    mv "$p" "$dst"
    log WARN "archived ${p} -> ${dst}"
}

# Start the per-stage detailed log. Call after load_project_env.
stage_log_start() {
    local stage="$1"
    local logdir="${PROJECT_DIR}/logs"
    mkdir -p "$logdir" "${PROJECT_DIR}/state"
    local job="${PBS_JOBID:-manual}"
    job="${job%%.*}"
    LOG="${logdir}/${stage}_${job}_$(_timestamp | tr -d ' :-').log"
    echo "Detailed log: ${LOG}"
    exec >> "${LOG}" 2>&1
    STAGE_START="$(_timestamp)"
    log INFO "===== stage ${stage} start ====="
    log INFO "host=$(hostname) job=${PBS_JOBID:-manual} project=${PROJECT_DIR}"
    log INFO "schrodinger=${SCHRODINGER}"
}

finish_stage() {
    log INFO "===== stage $1 end ====="
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
check_schrodinger() {
    [[ -d "$SCHRODINGER" ]] || die "Schrodinger not found: ${SCHRODINGER}"
    local -a need=(run utilities/licutil)
    if [[ "${PREFLIGHT_NEED_MULTISIM:-yes}" == "yes" ]]; then
        need+=(utilities/multisim)
    fi
    if [[ "${PREFLIGHT_NEED_PREPWIZARD:-yes}" == "yes" ]]; then
        need+=(utilities/prepwizard)
    fi
    local exe
    for exe in "${need[@]}"; do
        [[ -x "${SCHRODINGER}/${exe}" ]] || die "missing executable: ${SCHRODINGER}/${exe}"
    done
}

license_has_feature() {
    local feat="$1"
    local out
    out="$("${SCHRODINGER}/utilities/licutil" -list 2>/dev/null || true)"
    printf '%s\n' "$out" | grep -qw "$feat"
}

check_license_features() {
    local -a need=()
    local need_prime="${PREFLIGHT_NEED_PRIME:-${RUN_MMGBSA:-yes}}"
    [[ "${PREFLIGHT_NEED_DESMOND:-yes}" == "yes" ]] && need+=(DESMOND_MAIN)
    [[ "${PREFLIGHT_NEED_GPU:-yes}" == "yes" ]] && need+=(DESMOND_GPGPU)
    [[ "$need_prime" == "yes" ]] && need+=(PRIMEX_MAIN)
    (( ${#need[@]} > 0 )) || return 0
    local f
    local missing=()
    for f in "${need[@]}"; do
        license_has_feature "$f" || missing+=("$f")
    done
    if (( ${#missing[@]} > 0 )); then
        die "license feature(s) missing: ${missing[*]} (check ${SCHRODINGER}/license or SCHRODINGER_LICENSE_FILE)"
    fi
}

validate_cms() {
    local cms="$1"
    local ref="${2:-}"
    require_file "$cms" "CMS"
    local args=(--cms "$cms")
    if [[ -n "$ref" && -f "$ref" ]]; then
        args+=(--reference "$ref")
    fi
    local out rc=0
    out="$("${SCHRODINGER}/run" python3 "${PIPELINE_ROOT}/tools/validate_cms.py" "${args[@]}" 2>&1)" || rc=$?
    printf '%s\n' "$out"
    (( rc == 0 )) || die "CMS validation failed: ${cms}"
}

check_asls() {
    local struct="$1"
    local out rc=0
    out="$("${SCHRODINGER}/run" python3 "${PIPELINE_ROOT}/scripts/inspect_structure.py" \
        --structure "$struct" \
        --receptor-asl "$RECEPTOR_ASL" \
        --ligand-asl "$LIGAND_ASL" \
        --align-asl "$ALIGN_ASL" \
        --check 2>&1)" || rc=$?
    printf '%s\n' "$out"
    (( rc == 0 )) || die "ASL validation failed on ${struct}"
}

check_ascii() {
    local f="$1"
    LC_ALL=C awk '
        BEGIN { bad = 0 }
        /[^\t -~]/ { printf "%s:%d: non-ASCII\n", FILENAME, FNR; bad = 1 }
        END { exit bad }
    ' "$f" || die "non-ASCII content in ${f}; qsub rejects non-ASCII scripts"
}

check_bash_syntax() {
    bash -n "$1" || die "bash syntax error: $1"
}

# ---------------------------------------------------------------------------
# Template rendering
# ---------------------------------------------------------------------------
render_template() {
    local tmpl="$1"
    local out="$2"
    shift 2
    local content
    content="$(cat "$tmpl")"
    local pair key val
    for pair in "$@"; do
        key="${pair%%=*}"
        val="${pair#*=}"
        content="${content//@${key}@/${val}}"
    done
    printf '%s\n' "$content" > "$out"
    if grep -q '@[A-Z_][A-Z0-9_]*@' "$out"; then
        die "unrendered placeholder in ${out}"
    fi
}

queue_directive() {
    if [[ -n "${PBS_QUEUE:-}" ]]; then
        printf '#PBS -q %s' "$PBS_QUEUE"
    fi
}

walltime_directive() {
    local wt="$1"
    if [[ -n "$wt" ]]; then
        printf '#PBS -l walltime=%s' "$wt"
    fi
}

# ---------------------------------------------------------------------------
# Desmond log parsing
# ---------------------------------------------------------------------------
md_log_value() {
    local log="$1"
    local field="$2"
    [[ -f "$log" ]] || return 1
    case "$field" in
        chemical_ps)
            sed -n 's/^[[:space:]]*Chemical time:[[:space:]]*\([0-9.][0-9.]*\) ps.*/\1/p' "$log" | tail -1
            ;;
        ns_per_day)
            sed -n 's/.*ns\/day:[[:space:]]*\([0-9.][0-9.]*\).*/\1/p' "$log" | tail -1
            ;;
        *)
            return 1
            ;;
    esac
}

check_gpu_log() {
    local log="$1"
    [[ -f "$log" ]] || die "Desmond log not found: ${log}"
    grep -q 'GPU Desmond started' "$log" \
        || die "Desmond did not report GPU execution (log: ${log})"
    grep -m1 'uuid0: GPU-' "$log" || true
}
