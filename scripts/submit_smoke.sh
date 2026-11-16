#!/bin/bash
# Submit a one-GPU PBS smoke test: checks GPU visibility, PBS_GPUFILE/CVD,
# licenses, bundled Python, and shared-filesystem writes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PIPELINE_ROOT
source "${PIPELINE_ROOT}/scripts/lib/common.sh"
source "${PIPELINE_ROOT}/config.sh"
setup_schrodinger_env
require_command "$QSUB"

SMOKE_DIR="${SCH_WORK_ROOT}/projects/_smoke"
mkdir -p "${SMOKE_DIR}/pbs" "${SMOKE_DIR}/logs/pbs"

RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"
JOBNAME="mpS_$(job_slug "${USER:-user}")"
TEMPLATE="${PIPELINE_ROOT}/pbs/smoke.pbs.in"
OUT="${SMOKE_DIR}/pbs/smoke.${RUN_ID}.pbs"
PBS_OUT="${SMOKE_DIR}/logs/pbs/smoke.${RUN_ID}.out"

LICENSE_ENV=""
if [[ -n "${SCHRODINGER_LICENSE_FILE:-}" ]]; then
    LICENSE_ENV+="export SCHRODINGER_LICENSE_FILE=$(printf '%q' "$SCHRODINGER_LICENSE_FILE")"$'\n'
fi
if [[ -n "${LM_LICENSE_FILE:-}" ]]; then
    LICENSE_ENV+="export LM_LICENSE_FILE=$(printf '%q' "$LM_LICENSE_FILE")"$'\n'
fi
if [[ -n "${SCHRODINGER_HOSTS:-}" ]]; then
    LICENSE_ENV+="export SCHRODINGER_HOSTS=$(printf '%q' "$SCHRODINGER_HOSTS")"$'\n'
fi

render_template "$TEMPLATE" "$OUT" \
    "JOBNAME=${JOBNAME}" \
    "QUEUE_DIRECTIVE=$(queue_directive)" \
    "WALLTIME_DIRECTIVE=$(walltime_directive '00:10:00')" \
    "PBS_OUT=${PBS_OUT}" \
    "PIPELINE_ROOT=${PIPELINE_ROOT}" \
    "SCH_WORK_ROOT=${SCH_WORK_ROOT}" \
    "SCHRODINGER=${SCHRODINGER}" \
    "LICENSE_ENV=${LICENSE_ENV}"

check_ascii "$OUT"
check_bash_syntax "$OUT"

log INFO "submitting GPU smoke test: ${OUT}"
qsub_out="$("$QSUB" "$OUT" 2>&1)" || die "qsub failed: ${qsub_out}"
qsub_out="$(printf '%s' "$qsub_out" | tr -d '\r')"
job_id="$(printf '%s\n' "$qsub_out" | awk 'NF{print $NF}' | tail -1)"
[[ "$job_id" =~ ^[0-9]+(\.[A-Za-z0-9._-]+)?$ ]] || die "unexpected qsub output: ${qsub_out}"

echo
echo "GPU smoke test submitted: ${job_id}"
echo "PBS script : ${OUT}"
echo "PBS stdout : ${PBS_OUT}"
echo "Monitor    : $QSTAT -f ${job_id}"
echo "Cancel     : $QDEL ${job_id}"
