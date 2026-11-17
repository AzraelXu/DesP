#!/bin/bash
# Project-centric status: current stage, ETA, and warnings/errors from the
# current run. This intentionally does not print the full PBS queue or
# node/GPU tables; use qstat/pbsnodes for that.
# Usage: status.sh [SYSTEM_NAME | PROJECT_DIR]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PIPELINE_ROOT
source "${PIPELINE_ROOT}/scripts/lib/common.sh"
source "${PIPELINE_ROOT}/config.sh"
export LC_ALL=C

STATUS_NOW="${STATUS_NOW:-$(date +%s)}"
[[ "$STATUS_NOW" =~ ^[0-9]+$ ]] || STATUS_NOW="$(date +%s)"

STATUS_STAGES=(prepwizard setup min md analysis mmgbsa)
declare -A STAGE_PREFIX=(
    [prepwizard]=10_prepwizard [setup]=20_setup [min]=30_min [md]=40_md
    [analysis]=50_analysis [mmgbsa]=60_mmgbsa
)
declare -A STAGE_PBS=(
    [prepwizard]=prep [setup]=prep [min]=min [md]=md
    [analysis]=analysis [mmgbsa]=mmgbsa
)
declare -A STAGE_WALLVAR=(
    [prepwizard]=PBS_WALLTIME_PREP [setup]=PBS_WALLTIME_PREP
    [min]=PBS_WALLTIME_MIN [md]=PBS_WALLTIME_MD
    [analysis]=PBS_WALLTIME_ANALYSIS [mmgbsa]=PBS_WALLTIME_MMGBSA
)

# Per-project state.
declare -A STAGE_STATE=() STAGE_INDEX=()
declare -A STAGE_QSTATE=() STAGE_QSTART=() STAGE_QUSED=() STAGE_QLIMIT=()
declare -A STAGE_QEXIT=() STAGE_QCOMMENT=() STAGE_QHOLD=() STAGE_QEST=()
declare -A STAGE_SLOG=()
PROJECTS=()
declare -A PROJECT_SEEN=()
PROJECT_RESULT=""
CURRENT_STAGES=()
STAGE_TOTAL=0

# Frozen configuration fields.
F_SYSTEM_NAME=""
F_MD_TIME_NS=""
F_MD_TIME_PS=""
F_RUN_ANALYSIS=""
F_RUN_MMGBSA=""
F_FORCE_STAGES=""
F_PBS_WALLTIME_PREP=""
F_PBS_WALLTIME_MIN=""
F_PBS_WALLTIME_MD=""
F_PBS_WALLTIME_ANALYSIS=""
F_PBS_WALLTIME_MMGBSA=""

# jobs.env fields.
J_HAS_JOBS="no"
J_RUN_ID=""
J_SUBMITTED_AT=""
J_PREP=""
J_MIN=""
J_MD=""
J_ANALYSIS=""
J_MMGBSA=""

# qstat cache.
declare -A Q_QUERIED=() Q_CACHE_STATE=() Q_CACHE_USED=() Q_CACHE_LIMIT=()
declare -A Q_CACHE_START=() Q_CACHE_EXIT=() Q_CACHE_COMMENT=()
declare -A Q_CACHE_HOLD=() Q_CACHE_EST=() Q_CACHE_ERR=()
CUR_STATE=""
CUR_USED=""
CUR_LIMIT=""
CUR_START=""
CUR_EXIT=""
CUR_COMMENT=""
CUR_HOLD=""
CUR_EST=""
CUR_ERR=""
PBS_ERROR_PRINTED="no"

# MD progress.
MD_CHEM=""
MD_RATE=""
MD_RATE_SRC=""
MD_PCT=""
MD_ETA=""
MD_LOG=""


source "${PIPELINE_ROOT}/scripts/lib/status_state.sh"
source "${PIPELINE_ROOT}/scripts/lib/status_report.sh"

status_usage() {
    cat <<'EOF'
Usage: status.sh [SYSTEM_NAME | PROJECT_DIR]

For each initialized project, show:
  - the current stage and its PBS state,
  - elapsed time and ETA (MD uses chemical time + ns/day),
  - warnings/errors recorded in the current run.

The full PBS queue and node/GPU tables are deliberately omitted; use qstat
or pbsnodes if you need them.
EOF
}

main() {
    local arg="${1:-}"
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        status_usage
        exit 0
    fi
    if (( $# > 1 )); then
        status_usage
        printf 'Only one project argument is allowed.\n' >&2
        exit 2
    fi

    if ! command -v "$QSTAT" >/dev/null 2>&1; then
        printf 'Note: qstat not found (QSTAT=%s); showing file-based status only.\n' "$QSTAT"
        echo
    fi

    collect_projects "$arg"
    if (( ${#PROJECTS[@]} == 0 )); then
        if [[ -n "$arg" ]]; then
            printf 'Project not found: %s\n' "$arg" >&2
            printf 'Work root: %s\n' "$SCH_WORK_ROOT" >&2
            exit 1
        fi
        printf 'No initialized projects under %s/projects\n' "$SCH_WORK_ROOT"
        printf 'Run init_user.sh in your work directory, or export SCH_WORK_ROOT=<root> and retry.\n'
        exit 0
    fi
    mapfile -t PROJECTS < <(printf '%s\n' "${PROJECTS[@]}" | LC_ALL=C sort)

    local i
    for ((i = 0; i < ${#PROJECTS[@]}; i++)); do
        (( i > 0 )) && echo
        print_project "${PROJECTS[$i]}"
    done
}

main "$@"
