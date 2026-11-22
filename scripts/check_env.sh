#!/bin/bash
# Preflight checks for the Desmond pipeline.
# Run on the login node before submitting jobs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PIPELINE_ROOT
source "${PIPELINE_ROOT}/config.sh"
source "${PIPELINE_ROOT}/scripts/lib/ui.sh"

ui_parse_color_args "$@" || exit $?
set -- "${UI_ARGS[@]+"${UI_ARGS[@]}"}"

PASS=0
WARN=0
FAIL=0

ok()   { ui_emit OK "[PASS] $*"; PASS=$((PASS + 1)); }
warn() { ui_emit WARN "[WARN] $*"; WARN=$((WARN + 1)); }
bad()  { ui_emit FAIL "[FAIL] $*"; FAIL=$((FAIL + 1)); }

rule "============================================================"
header "Desmond pipeline environment check"
ui_kv "host" "$(hostname)"
ui_kv "user" "${USER:-unknown}"
ui_kv "pipeline" "${PIPELINE_ROOT}"
ui_kv "work root" "${SCH_WORK_ROOT}"
ui_kv "SCHRODINGER" "${SCHRODINGER}"
rule "============================================================"
echo

# ---------------------------------------------------------------------------
# Runtime context
# ---------------------------------------------------------------------------
if [[ -n "${PBS_JOBID:-}" ]]; then
    warn "PBS_JOBID is set (${PBS_JOBID}). Submit new jobs from the login node, not from a compute-node job."
else
    ok "running outside a PBS job (login node expected)"
fi

# ---------------------------------------------------------------------------
# Schrodinger
# ---------------------------------------------------------------------------
if [[ -d "$SCHRODINGER" ]]; then
    ok "Schrodinger directory exists: ${SCHRODINGER}"
    if [[ -f "${SCHRODINGER}/version.txt" ]]; then
        printf '       '
        debug "$(head -1 "${SCHRODINGER}/version.txt")"
    else
        warn "version.txt not found in ${SCHRODINGER}"
    fi
else
    bad "Schrodinger directory not found: ${SCHRODINGER}"
fi

for exe in run utilities/multisim utilities/prepwizard utilities/licutil; do
    if [[ -x "${SCHRODINGER}/${exe}" ]]; then
        ok "executable: ${exe}"
    else
        bad "missing executable: ${SCHRODINGER}/${exe}"
    fi
done

# ---------------------------------------------------------------------------
# License
# ---------------------------------------------------------------------------
if [[ -x "${SCHRODINGER}/utilities/licutil" ]]; then
    lic_out="$("${SCHRODINGER}/utilities/licutil" -list 2>&1 || true)"
    if [[ -z "$lic_out" ]]; then
        bad "licutil -list returned nothing (license file/server problem?)"
    else
        for feat in DESMOND_MAIN DESMOND_GPGPU PRIMEX_MAIN; do
            if printf '%s\n' "$lic_out" | grep -qw "$feat"; then
                ok "license feature: ${feat}"
            else
                bad "license feature missing: ${feat}"
            fi
        done
    fi
    if [[ -n "${SCHRODINGER_LICENSE_FILE:-}" ]]; then
        ok "SCHRODINGER_LICENSE_FILE is set"
    fi
    if [[ -n "${LM_LICENSE_FILE:-}" ]]; then
        ok "LM_LICENSE_FILE is set"
    fi
else
    bad "licutil not found; cannot inspect licenses"
fi

# ---------------------------------------------------------------------------
# PBS / Torque
# ---------------------------------------------------------------------------
for cmd in "$QSUB" "$QSTAT" "$QDEL" "$PBSNODES"; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "PBS command: ${cmd} -> $(command -v "$cmd")"
    else
        bad "PBS command not found: ${cmd}"
    fi
done

if command -v "$QSTAT" >/dev/null 2>&1; then
    echo
    header "--- queue summary (${QSTAT} -q) ---"
    "$QSTAT" -q 2>&1 | sed 's/^/    /'
    echo
fi

if command -v "$PBSNODES" >/dev/null 2>&1; then
    header "--- nodes and GPUs (${PBSNODES} -a) ---"
    printf '    %-10s %-10s %-6s %-6s\n' "node" "state" "np" "gpus"
    node_report="$("$PBSNODES" -a 2>/dev/null | awk '
        /^[A-Za-z]/ {
            if (node != "") printf "    %-10s %-10s %-6s %-6s\n", node, state, np, gpus
            node = $1; state = "-"; np = "-"; gpus = "0"; next
        }
        /state =/ { state = $3 }
        /np =/    { np = $3 }
        /gpus =/  { gpus = $3 }
        END { if (node != "") printf "    %-10s %-10s %-6s %-6s\n", node, state, np, gpus }
    ')"
    printf '%s\n' "$node_report"
    total_gpus="$(printf '%s\n' "$node_report" | awk '$4 ~ /^[0-9]+$/ {s += $4} END {print s + 0}')"
    if (( total_gpus > 0 )); then
        ok "total GPU slots visible to the scheduler: ${total_gpus}"
        debug "       Each min/MD job requests 1 GPU; at most ${total_gpus} of them can run at once."
    else
        warn "no 'gpus' resources found in pbsnodes output; check Torque GPU configuration"
    fi
    echo
fi

# ---------------------------------------------------------------------------
# GPU on this node (login nodes normally have none)
# ---------------------------------------------------------------------------
if command -v nvidia-smi >/dev/null 2>&1; then
    if nvidia-smi -L >/dev/null 2>&1; then
        ok "nvidia-smi works on this node"
        nvidia-smi -L 2>&1 | sed 's/^/       /'
    else
        warn "nvidia-smi exists but cannot talk to the driver (expected on a login node; use the smoke PBS job)"
    fi
else
    warn "nvidia-smi not found on this node (expected on a login node)"
fi

# ---------------------------------------------------------------------------
# Schrodinger Python and plotting dependencies
# ---------------------------------------------------------------------------
if [[ -x "${SCHRODINGER}/run" ]]; then
    py_out="$("${SCHRODINGER}/run" python3 - <<'PY' 2>&1
import sys
print("python", sys.version.split()[0])
import pandas, matplotlib, openpyxl
print("pandas", pandas.__version__)
print("matplotlib", matplotlib.__version__)
print("openpyxl", openpyxl.__version__)
from schrodinger import structure
from schrodinger.structutils import analyze
from schrodinger.application.desmond.packages import analysis, topo, traj_util
print("desmond_api OK")
PY
)"
    if printf '%s\n' "$py_out" | grep -q 'desmond_api OK'; then
        ok "Schrodinger Python + pandas/matplotlib/openpyxl + Desmond API"
        printf '%s\n' "$py_out" | sed 's/^/       /'
    else
        bad "Schrodinger Python dependency check failed:"
        printf '%s\n' "$py_out" | sed 's/^/       /'
    fi
fi

# ---------------------------------------------------------------------------
# Basic commands
# ---------------------------------------------------------------------------
for cmd in awk sed grep tr cut sort sha256sum readlink flock; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "command available: ${cmd}"
    else
        bad "command missing: ${cmd}"
    fi
done

# ---------------------------------------------------------------------------
# Writable directories and disk space
# ---------------------------------------------------------------------------
for d in "${SCH_WORK_ROOT}/projects" "${SCH_WORK_ROOT}/.gpu_locks"; do
    if mkdir -p "$d" 2>/dev/null && [[ -w "$d" ]]; then
        tmp="${d}/.write_test.$$"
        if touch "$tmp" 2>/dev/null; then
            rm -f "$tmp"
            ok "writable directory: ${d}"
        else
            bad "cannot write to directory: ${d}"
        fi
    else
        bad "cannot create/write directory: ${d}"
    fi
done

if command -v df >/dev/null 2>&1; then
    echo
    header "--- disk space ---"
    df -h "${SCH_WORK_ROOT}" 2>/dev/null | sed 's/^/    /'
    echo
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
rule "============================================================"
info "PASS=${PASS}  WARN=${WARN}  FAIL=${FAIL}"
if (( FAIL > 0 )); then
    echo "Result: FAIL - fix the items above before submitting production jobs."
    exit 1
fi
if (( WARN > 0 )); then
    echo "Result: OK (warnings are expected on a login node; use the smoke job for GPU checks)"
else
    echo "Result: OK"
fi
exit 0
