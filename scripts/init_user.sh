#!/bin/bash
# Initialize a per-user work root for the shared Desmond pipeline.
# The shared code directory is read-only; all outputs go under $SCH_WORK_ROOT.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PIPELINE_ROOT
source "${PIPELINE_ROOT}/config.sh"

mkdir -p "${SCH_WORK_ROOT}/projects" "${SCH_WORK_ROOT}/results" \
         "${SCH_WORK_ROOT}/systems" "${GPU_LOCK_DIR}"

if [[ ! -f "${SCH_WORK_ROOT}/systems/example.conf" ]]; then
    cp "${PIPELINE_ROOT}/systems/example.conf.example" \
       "${SCH_WORK_ROOT}/systems/example.conf"
fi
if [[ ! -f "${SCH_WORK_ROOT}/systems/gda10_pilot.conf" ]] \
    && [[ -f "${PIPELINE_ROOT}/examples/gda10_pilot.conf.example" ]]; then
    cp "${PIPELINE_ROOT}/examples/gda10_pilot.conf.example" \
       "${SCH_WORK_ROOT}/systems/gda10_pilot.conf"
fi

echo "Work root : ${SCH_WORK_ROOT}"
echo "Systems   : ${SCH_WORK_ROOT}/systems"
echo "Projects  : ${SCH_WORK_ROOT}/projects"
echo "Results   : ${SCH_WORK_ROOT}/results"
echo "GPU locks : ${GPU_LOCK_DIR}"
echo
echo "Next steps:"
echo "  1) Edit ${SCH_WORK_ROOT}/systems/example.conf (input path + ASLs)."
echo "  2) ${PIPELINE_ROOT}/scripts/check_env.sh"
echo "  3) ${PIPELINE_ROOT}/scripts/submit_smoke.sh"
echo "  4) ${PIPELINE_ROOT}/scripts/submit_system.sh ${SCH_WORK_ROOT}/systems/example.conf"
echo "  5) ${PIPELINE_ROOT}/scripts/status.sh example"
