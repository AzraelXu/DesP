#!/bin/bash
# submit_batch.sh: directory mode skips placeholder templates.
set -uo pipefail
source "$(dirname "$0")/lib/testlib.sh"
new_sandbox

run_batch() {
    local dir="$1"
    env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX/home" USER=testuser \
        LC_ALL=C TZ=UTC SCH_WORK_ROOT="$SANDBOX" \
        bash "$REPO_ROOT/scripts/submit_batch.sh" "$dir" 2>&1
}

d1="$SANDBOX/templates-only"
mkdir -p "$d1"
printf 'SYSTEM_NAME="example"\n' > "$d1/example.conf"
out="$(run_batch "$d1")"
rc=$?
assert_eq 1 "$rc" "example-only directory exit"
assert_contains "$out" "no *.conf files found" "example-only directory message"

d2="$SANDBOX/legacy-templates"
mkdir -p "$d2"
printf 'SYSTEM_NAME="example"\n' > "$d2/example.conf"
printf 'SYSTEM_NAME="gda10_pilot"\n' > "$d2/gda10_pilot.conf"
out="$(run_batch "$d2")"
rc=$?
assert_eq 1 "$rc" "legacy templates directory exit"
assert_contains "$out" "no *.conf files found" "legacy templates message"

finish
