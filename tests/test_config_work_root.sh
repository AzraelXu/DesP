#!/bin/bash
# config.sh work-root precedence: explicit > marker upward search > fallback.
set -uo pipefail
source "$(dirname "$0")/lib/testlib.sh"
new_sandbox

config_root() {
    local cwd="$1"
    local home="$2"
    shift 2
    ( cd "$cwd" && env -i PATH=/usr/bin:/bin HOME="$home" "$@" \
        bash -c 'source "$1" 2>/dev/null; printf "%s" "$SCH_WORK_ROOT"' \
        _ "$REPO_ROOT/config.sh" )
}

mkdir -p "$SANDBOX/other" "$SANDBOX/work/projects/x/deep"
printf 'SCH_WORK_ROOT=%s\n' "$SANDBOX/work" > "$SANDBOX/work/.desmond_work_root"

out="$(config_root "$SANDBOX/other" "$SANDBOX/home" "SCH_WORK_ROOT=$SANDBOX/custom")"
assert_eq "$SANDBOX/custom" "$out" "explicit SCH_WORK_ROOT wins"

out="$(config_root "$SANDBOX/work/projects/x/deep" "$SANDBOX/home")"
assert_eq "$SANDBOX/work" "$out" "marker found upward from a subdirectory"

out="$(config_root "$SANDBOX/other" "$SANDBOX/home")"
assert_eq "$SANDBOX/home/desmond_md_work" "$out" "fallback is HOME/desmond_md_work"

out="$(config_root "$SANDBOX/other" "$SANDBOX/home" "PIPELINE_WORK_ROOT=$SANDBOX/legacy")"
assert_eq "$SANDBOX/legacy" "$out" "deprecated PIPELINE_WORK_ROOT is honored"

out="$(config_root "$SANDBOX/work/projects/x/deep" "$SANDBOX/home" "SCH_WORK_ROOT=$SANDBOX/custom")"
assert_eq "$SANDBOX/custom" "$out" "explicit value beats the marker"

ln -s "$SANDBOX/work" "$SANDBOX/work_link"
out="$(config_root "$SANDBOX/work_link/projects/x" "$SANDBOX/home")"
assert_eq "$SANDBOX/work" "$out" "marker search follows the physical path"

finish
