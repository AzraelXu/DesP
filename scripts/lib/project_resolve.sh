#!/bin/bash
# Shared explicit-project-argument resolution.
# Sourced by status_state.sh and collect_results.sh; never executed directly.
#
# Priority (matches status.sh):
#   1. an existing directory;
#   2. a project.resolved.conf file (its parent directory);
#   3. $SCH_WORK_ROOT/projects/<name>;
#   4. scan projects/*/project.resolved.conf for SYSTEM_NAME == <name>.

canon_project_dir() {
    readlink -f "$1" 2>/dev/null || printf '%s' "$1"
}

frozen_system_name() {
    bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${SYSTEM_NAME:-}"' _ "$1" 2>/dev/null || true
}

# resolve_project_arg ARG
# Print the canonical project directory and return 0 when found.
# Return 1 when ARG does not identify an initialized project.
resolve_project_arg() {
    local arg="${1:-}"
    [[ -n "$arg" ]] || return 1
    local p=""
    if [[ -d "$arg" ]]; then
        p="$arg"
    elif [[ -f "$arg" && "$(basename "$arg")" == "project.resolved.conf" ]]; then
        p="$(dirname "$arg")"
    elif [[ -d "${SCH_WORK_ROOT:-}/projects/${arg}" ]]; then
        p="${SCH_WORK_ROOT}/projects/${arg}"
    else
        local d name
        shopt -s nullglob
        for d in "${SCH_WORK_ROOT:-}/projects"/*; do
            [[ -d "$d" && -f "$d/project.resolved.conf" ]] || continue
            name="$(frozen_system_name "$d/project.resolved.conf")"
            if [[ "$name" == "$arg" ]]; then
                p="$d"
                break
            fi
        done
        shopt -u nullglob
    fi
    [[ -n "$p" && -d "$p" && -f "$p/project.resolved.conf" ]] || return 1
    canon_project_dir "$p"
}
