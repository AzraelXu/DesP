#!/bin/bash
# Show PBS queue, GPU nodes, and per-project stage/MD/MM-GBSA status.
# Usage: status.sh [SYSTEM_NAME | PROJECT_DIR]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PIPELINE_ROOT
source "${PIPELINE_ROOT}/scripts/lib/common.sh"
source "${PIPELINE_ROOT}/config.sh"

username="${USER:-$(id -un)}"

echo "============================================================"
echo "PBS queue for ${username}"
echo "============================================================"
if command -v "$QSTAT" >/dev/null 2>&1; then
    "$QSTAT" -u "$username" 2>&1 || true
else
    echo "qstat not found: ${QSTAT}"
fi
echo

echo "============================================================"
echo "Nodes and GPUs"
echo "============================================================"
if command -v "$PBSNODES" >/dev/null 2>&1; then
    printf '%-10s %-10s %-6s %-6s\n' "node" "state" "np" "gpus"
    "$PBSNODES" -a 2>/dev/null | awk '
        /^[A-Za-z]/ {
            if (node != "") printf "%-10s %-10s %-6s %-6s\n", node, state, np, gpus
            node = $1; state = "-"; np = "-"; gpus = "0"; next
        }
        /state =/ { state = $3 }
        /np =/    { np = $3 }
        /gpus =/  { gpus = $3 }
        END { if (node != "") printf "%-10s %-10s %-6s %-6s\n", node, state, np, gpus }
    '
else
    echo "pbsnodes not found: ${PBSNODES}"
fi
echo

projects=()
if (( $# > 0 )); then
    if [[ -d "$1" ]]; then
        projects=("$1")
    else
        projects=("${SCH_WORK_ROOT}/projects/$1")
    fi
else
    shopt -s nullglob
    for d in "${SCH_WORK_ROOT}/projects"/*; do
        if [[ -d "$d" && -f "$d/project.resolved.conf" ]]; then
            projects+=("$d")
        fi
    done
    shopt -u nullglob
fi

if (( ${#projects[@]} == 0 )); then
    echo "No initialized projects under ${SCH_WORK_ROOT}/projects"
    exit 0
fi

for pdir in "${projects[@]}"; do
    [[ -f "$pdir/project.resolved.conf" ]] || continue
    name="$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${SYSTEM_NAME:-}"' _ "$pdir/project.resolved.conf" 2>/dev/null || true)"
    [[ -n "$name" ]] || name="$(basename "$pdir")"
    target="$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${MD_TIME_PS:-}"' _ "$pdir/project.resolved.conf" 2>/dev/null || true)"

    echo "============================================================"
    echo "Project: ${name}"
    echo "Dir    : ${pdir}"
    echo "============================================================"

    done_list=()
    for s in prepwizard setup min md analysis mmgbsa; do
        if [[ -f "$pdir/state/${s}.done" ]]; then
            done_list+=("$s")
        fi
    done
    if (( ${#done_list[@]} == 0 )); then
        echo "Completed stages: none"
    else
        echo "Completed stages: ${done_list[*]}"
    fi

    if [[ -f "$pdir/state/jobs.env" ]]; then
        run_id="$(sed -n 's/^RUN_ID=//p' "$pdir/state/jobs.env" | head -1)"
        echo "Latest run      : ${run_id:-unknown}"
        for key in PREP_JOB MIN_JOB MD_JOB ANALYSIS_JOB MMGBSA_JOB; do
            id="$(sed -n "s/^${key}=//p" "$pdir/state/jobs.env" | head -1)"
            [[ -n "$id" ]] || continue
            state="$("$QSTAT" -f "$id" 2>/dev/null \
                | sed -n 's/^[[:space:]]*job_state = //p' | head -1 || true)"
            printf '  %-12s %-14s %s\n' "$key" "$id" "${state:--}"
        done
    else
        echo "Latest run      : not submitted yet"
    fi

    md_log="$pdir/desmond_md_job_${name}/desmond_md_job_${name}.log"
    if [[ -f "$md_log" ]]; then
        chem="$(md_log_value "$md_log" chemical_ps || true)"
        rate="$(md_log_value "$md_log" ns_per_day || true)"
        if [[ -n "$chem" && -n "$target" ]]; then
            pct="$(awk -v a="$chem" -v b="$target" 'BEGIN {if (b > 0) printf "%.1f", 100 * a / b; else print "?"}')"
            echo "MD progress     : ${pct}% (${chem} / ${target} ps), last rate ${rate:-?} ns/day"
        elif [[ -n "$chem" ]]; then
            echo "MD progress     : ${chem} ps, last rate ${rate:-?} ns/day"
        fi
    fi

    if [[ -f "$pdir/results/mmgbsa_summary.md" ]]; then
        mean_line="$(grep 'Mean dG_bind' "$pdir/results/mmgbsa_summary.md" | head -1 || true)"
        echo "MM-GBSA         : ${mean_line:-summary present}"
    fi

    if [[ -d "$pdir/results" ]]; then
        nfiles="$(find "$pdir/results" -maxdepth 1 -type f ! -name '*.bak.*' 2>/dev/null | wc -l)"
        echo "Results         : ${nfiles} file(s) in ${pdir}/results"
    fi
    echo
done
