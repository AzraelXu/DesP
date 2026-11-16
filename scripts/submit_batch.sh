#!/bin/bash
# Submit several systems. Each system gets its own chain of PBS jobs; Torque
# queues them according to the available GPU slots.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PIPELINE_ROOT
source "${PIPELINE_ROOT}/scripts/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: submit_batch.sh [options] <systems/dir-or-conf> [<conf> ...]

Options are passed to submit_system.sh for every system:
  --dry-run
  --from STAGE
  --force-stage STAGE      (translated to --force STAGE; use "all" for everything)
  --restart-md
  --no-analysis
  --no-mmgbsa
EOF
}

CONFIG_ARGS=()
PASS=()
DRY_RUN="no"

while (( $# > 0 )); do
    case "$1" in
        --dry-run)
            DRY_RUN="yes"; PASS+=("$1"); shift ;;
        --restart-md|--no-analysis|--no-mmgbsa)
            PASS+=("$1"); shift ;;
        --from)
            [[ $# -ge 2 ]] || die "--from requires a stage"
            PASS+=(--from "$2"); shift 2 ;;
        --force-stage)
            [[ $# -ge 2 ]] || die "--force-stage requires a stage"
            PASS+=(--force "$2"); shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        -*)
            usage; die "unknown option: $1" ;;
        *)
            CONFIG_ARGS+=("$1"); shift ;;
    esac
done

(( ${#CONFIG_ARGS[@]} > 0 )) || { usage; die "no system configs given"; }

FILES=()
for p in "${CONFIG_ARGS[@]}"; do
    if [[ -d "$p" ]]; then
        shopt -s nullglob
        for f in "$p"/*.conf; do
            FILES+=("$f")
        done
        shopt -u nullglob
    elif [[ -f "$p" ]]; then
        FILES+=("$p")
    else
        die "not a file or directory: $p"
    fi
done
(( ${#FILES[@]} > 0 )) || die "no *.conf files found"

# Reject duplicate SYSTEM_NAME values before submitting anything.
declare -A seen=()
for f in "${FILES[@]}"; do
    name="$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${SYSTEM_NAME:-}"' _ "$f" || true)"
    [[ -n "$name" ]] || die "SYSTEM_NAME is missing or unreadable in $f"
    if [[ -n "${seen[$name]:-}" ]]; then
        die "duplicate SYSTEM_NAME '$name' in $f and ${seen[$name]}"
    fi
    seen[$name]="$f"
done

echo "Batch: ${#FILES[@]} system(s)"
for f in "${FILES[@]}"; do
    echo "  $f"
done
echo

ok=0
failed=0
failed_names=()

for f in "${FILES[@]}"; do
    name="$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${SYSTEM_NAME:-}"' _ "$f" || true)"
    echo "=================================================================="
    if [[ "$DRY_RUN" == "yes" ]]; then
        echo "Processing system (dry run): ${name}"
    else
        echo "Submitting system: ${name}"
    fi
    echo "Config: ${f}"
    echo "=================================================================="

    cmd=(bash "${SCRIPT_DIR}/submit_system.sh" "$f")
    if (( ${#PASS[@]} > 0 )); then
        cmd+=("${PASS[@]}")
    fi

    if "${cmd[@]}"; then
        ok=$((ok + 1))
    else
        failed=$((failed + 1))
        failed_names+=("$name")
        warn "submission failed for: ${name}"
    fi
    echo
done

echo "=================================================================="
if [[ "$DRY_RUN" == "yes" ]]; then
    echo "Batch summary (dry run): ${ok} processed, ${failed} failed"
else
    echo "Batch summary: ${ok} submitted, ${failed} failed"
fi
if (( failed > 0 )); then
    echo "Failed systems: ${failed_names[*]}"
    exit 1
fi
if [[ "$DRY_RUN" != "yes" ]]; then
    echo "Use scripts/status.sh to monitor all projects."
fi
