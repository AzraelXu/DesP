#!/bin/bash
# Completed-project report state: remember which completed run was already
# shown so a finished project is reported only once in the no-argument scan.
# Sourced by scripts/status.sh; functions take explicit arguments so they do
# not depend on (or clobber) the caller's globals.

REPORTED_STATE_NAME="status_reported.env"

reported_state_file() {
    printf '%s/state/%s' "$1" "$REPORTED_STATE_NAME"
}

# project_already_reported PDIR EXPECTED_RUN_ID
# Returns 0 only when the marker exists and has an explicit RUN_ID line whose
# value equals EXPECTED_RUN_ID. An empty value is a valid match (legacy
# projects without jobs.env); a missing or damaged RUN_ID line is not.
project_already_reported() {
    local pdir="$1"
    local expected="${2:-}"
    local file
    file="$(reported_state_file "$pdir")"
    [[ -f "$file" ]] || return 1

    local key="" val="" recorded="" found=0
    while IFS='=' read -r key val || [[ -n "$key" ]]; do
        if [[ "$key" == "RUN_ID" ]]; then
            recorded="$val"
            found=1
            break
        fi
    done < "$file"

    (( found == 1 )) && [[ "$recorded" == "$expected" ]]
}

# mark_project_reported PDIR RUN_ID [PROJECT_NAME]
# Atomically record that the current run was reported. The file is parsed by
# callers, never sourced, so arbitrary project names are safe.
mark_project_reported() {
    local pdir="$1"
    local run_id="${2:-}"
    local project="${3:-}"
    local state_dir="$pdir/state"
    local target="$state_dir/$REPORTED_STATE_NAME"
    local tmp="$state_dir/.$REPORTED_STATE_NAME.$$"

    mkdir -p "$state_dir" || return 1
    {
        printf 'RUN_ID=%s\n' "$run_id"
        printf 'PROJECT=%s\n' "$project"
        printf 'REPORTED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
}
