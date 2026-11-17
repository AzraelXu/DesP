#!/bin/bash
# Generate per-system configs from protein-ligand complexes.
# Thin wrapper: resolves the work root and Schrodinger, then runs
# generate_systems.py under the Schrodinger Python interpreter.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PIPELINE_ROOT

source "${PIPELINE_ROOT}/scripts/lib/common.sh"
source "${PIPELINE_ROOT}/config.sh"
export SCHRODINGER

case "${1:-}" in
    -h|--help)
        if command -v python3 >/dev/null 2>&1; then
            exec python3 "${SCRIPT_DIR}/generate_systems.py" "$@"
        fi
        ;;
esac

[[ -x "${SCHRODINGER}/run" ]] || die "Schrodinger not found: ${SCHRODINGER}"
exec "${SCHRODINGER}/run" python3 "${SCRIPT_DIR}/generate_systems.py" "$@"
