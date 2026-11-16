#!/bin/bash
# Run the lightweight shell regression tests (no PBS/Schrodinger required).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

fail=0

echo "== Syntax checks =="
for f in config.sh scripts/lib/common.sh scripts/lib/bashrc.sh \
         scripts/lib/status_state.sh scripts/lib/status_report.sh \
         scripts/init_user.sh scripts/status.sh; do
    if bash -n "$f"; then
        printf '  OK   %s\n' "$f"
    else
        printf '  FAIL %s\n' "$f"
        fail=1
    fi
done
echo

if command -v shellcheck >/dev/null 2>&1; then
    echo "== shellcheck (errors only; informational) =="
    for f in config.sh scripts/lib/common.sh scripts/lib/bashrc.sh \
             scripts/lib/status_state.sh scripts/lib/status_report.sh \
             scripts/init_user.sh scripts/status.sh; do
        shellcheck -S error -x "$f" || true
    done
    echo
fi

for t in tests/test_*.sh; do
    printf '== %s ==\n' "$t"
    if ! bash "$t"; then
        fail=1
    fi
    echo
done

if (( fail != 0 )); then
    echo "TESTS FAILED"
    exit 1
fi
echo "ALL TESTS PASSED"
