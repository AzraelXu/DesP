#!/bin/bash
# Shared terminal output helpers for the Desmond pipeline.
# This file is sourced, never executed directly.
#
# Color mode precedence: --color=auto|always|never > $SCH_COLOR > auto.
# In auto mode colors are enabled per output stream only when that stream is a
# TTY and NO_COLOR/CI are unset and TERM is not "dumb".
#
# Business code must call these helpers instead of writing ANSI escapes.

UI_RESET=$'\033[0m'
UI_BOLD=$'\033[1m'
UI_RED=$'\033[1;31m'
UI_FATAL_LABEL=$'\033[1;97;41m'
UI_YELLOW=$'\033[1;33m'
UI_GREEN=$'\033[1;32m'
UI_CYAN=$'\033[36m'
UI_GRAY=$'\033[90m'

_UI_RE_WARN='^(\[WARN\]|WARNING[[:space:]]*:|WARN[[:space:]]*:)(.*)$'
_UI_RE_OK='^(\[OK\]|\[PASS\]|OK[[:space:]]*:|SUCCESS[[:space:]]*:)(.*)$'
_UI_RE_FAIL='^(\[FAIL\]|FAIL[[:space:]]*:)(.*)$'
_UI_RE_INFO='^(\[INFO\]|INFO[[:space:]]*:)(.*)$'
_UI_RE_DEBUG='^(\[DEBUG\]|DEBUG[[:space:]]*:)(.*)$'
_UI_RE_SKIP='^(\[SKIP\]|SKIP[[:space:]]*:)(.*)$'
_UI_RE_DRY='^(\[DRY-RUN\])(.*)$'
_UI_RE_FATAL='^(\[FATAL\]|FATAL[[:space:]]*:)(.*)$'

UI_COLOR_MODE=auto
UI_ARGS=()

_ui_valid_mode() {
    case "${1:-}" in
        auto|always|never) return 0 ;;
        *) return 1 ;;
    esac
}

_ui_invalid_mode() {
    printf 'Invalid --color value: %s (use auto, always, or never)\n' "${1:-}" >&2
}

# Initialise the mode from $SCH_COLOR (invalid values fall back to auto).
ui_init() {
    local mode="${SCH_COLOR:-auto}"
    _ui_valid_mode "$mode" || mode=auto
    UI_COLOR_MODE="$mode"
    export SCH_COLOR="$mode"
}

# Force a mode and make it visible to child processes.
ui_set_color() {
    _ui_valid_mode "${1:-}" || return 1
    UI_COLOR_MODE="$1"
    export SCH_COLOR="$1"
}

ui_color_mode() {
    printf '%s' "$UI_COLOR_MODE"
}

# True when colours should be used for file descriptor $1.
ui_color_enabled() {
    local fd="${1:-1}"
    case "$UI_COLOR_MODE" in
        always) return 0 ;;
        never) return 1 ;;
    esac
    [[ -t "$fd" ]] || return 1
    [[ -z "${NO_COLOR:-}" ]] || return 1
    [[ -z "${CI:-}" ]] || return 1
    [[ "${TERM:-}" != "dumb" ]] || return 1
    return 0
}

# Strip ANSI SGR sequences (used by tests and by callers that re-parse text).
# A regex loop is used because a glob pattern with "\[[0-9;]*m" is ambiguous.
ui_strip() {
    local text="${*:-}"
    local re=$'\033''\[[0-9;]*m'
    local out=""
    local match=""
    while [[ "$text" =~ $re ]]; do
        match="${BASH_REMATCH[0]}"
        out+="${text%%"$match"*}"
        text="${text#*"$match"}"
    done
    printf '%s%s' "$out" "$text"
}

_ui_write() {
    local fd="$1"
    local color="$2"
    local text="${3:-}"
    if ui_color_enabled "$fd"; then
        printf '%s%s%s\n' "$color" "$text" "$UI_RESET"
    else
        printf '%s\n' "$text"
    fi
}

_ui_emit_label() {
    local fd="$1"
    local color="$2"
    local re="$3"
    local text="${4:-}"
    if ! ui_color_enabled "$fd"; then
        printf '%s\n' "$text"
        return 0
    fi
    if [[ "$text" =~ $re ]]; then
        printf '%s%s%s%s\n' "$color" "${BASH_REMATCH[1]}" "$UI_RESET" "${BASH_REMATCH[2]}"
    else
        printf '%s\n' "$text"
    fi
}

_ui_emit_fatal() {
    local text="${1:-}"
    if ! ui_color_enabled 2; then
        printf '%s\n' "$text"
        return 0
    fi
    if [[ "$text" =~ $_UI_RE_FATAL ]]; then
        printf '%s%s%s%s%s%s\n' \
            "$UI_FATAL_LABEL" "${BASH_REMATCH[1]}" "$UI_RESET" \
            "$UI_RED" "${BASH_REMATCH[2]}" "$UI_RESET"
    else
        printf '%s%s%s\n' "$UI_RED" "$text" "$UI_RESET"
    fi
}

_ui_emit_dispatch() {
    local fd="$1"
    local level="$2"
    local text="${3:-}"
    case "$level" in
        FATAL)
            if (( fd == 2 )); then
                _ui_emit_fatal "$text"
            else
                _ui_write 1 "$UI_RED" "$text"
            fi
            ;;
        ERROR)              _ui_write "$fd" "$UI_RED" "$text" ;;
        WARN|WARNING)       _ui_emit_label "$fd" "$UI_YELLOW" "$_UI_RE_WARN" "$text" ;;
        OK|PASS|SUCCESS)    _ui_emit_label "$fd" "$UI_GREEN" "$_UI_RE_OK" "$text" ;;
        FAIL)               _ui_emit_label "$fd" "$UI_RED" "$_UI_RE_FAIL" "$text" ;;
        SKIP)               _ui_emit_label "$fd" "$UI_GRAY" "$_UI_RE_SKIP" "$text" ;;
        DRY-RUN|DRYRUN)     _ui_emit_label "$fd" "$UI_CYAN" "$_UI_RE_DRY" "$text" ;;
        INFO)               _ui_emit_label "$fd" "$UI_CYAN" "$_UI_RE_INFO" "$text" ;;
        DEBUG)              _ui_emit_label "$fd" "$UI_GRAY" "$_UI_RE_DEBUG" "$text" ;;
        *)                  printf '%s\n' "$text" ;;
    esac
}

# Text-preserving emitter: colour existing labels without adding new ones.
# FATAL/ERROR/WARN go to stderr; the other levels go to stdout.
ui_emit() {
    local level="${1:-INFO}"
    shift || true
    local text="${*:-}"
    case "$level" in
        FATAL|ERROR|WARN|WARNING) _ui_emit_dispatch 2 "$level" "$text" ;;
        *)                        _ui_emit_dispatch 1 "$level" "$text" ;;
    esac
}

# Same as ui_emit, but always writes to stdout. Use for report lines that keep
# their original stream (e.g. a dry-run plan's [ERROR] item).
ui_emit_out() {
    local level="${1:-INFO}"
    shift || true
    _ui_emit_dispatch 1 "$level" "${*:-}"
}

# High-level helpers with canonical prefixes.
ok()     { ui_emit OK "[OK] $*"; }
info()   { _ui_write 1 "$UI_CYAN" "$*"; }
warn()   { ui_emit WARN "WARNING: $*"; }
error()  { ui_emit ERROR "ERROR: $*"; }
fatal()  { ui_emit FATAL "FATAL: $*"; }
debug()  { _ui_write 1 "$UI_GRAY" "$*"; }
header() { _ui_write 1 "$UI_BOLD" "$*"; }

rule() {
    local text="${*:-============================================================}"
    _ui_write 1 "$UI_GRAY" "$text"
}

# Key/value line preserving the legacy "%-Ns: value" layout.
# Usage: ui_kv LABEL VALUE [WIDTH]
ui_kv() {
    local label="${1:-}"
    local value="${2:-}"
    local width="${3:-10}"
    if ui_color_enabled 1; then
        printf '%s%-*s%s: %s%s%s\n' \
            "$UI_BOLD" "$width" "$label" "$UI_RESET" \
            "$UI_CYAN" "$value" "$UI_RESET"
    else
        printf '%-*s: %s\n' "$width" "$label" "$value"
    fi
}

_ui_step_text() {
    local step="${1:-}"
    if ! ui_color_enabled 1; then
        printf '%s' "$step"
        return 0
    fi
    if [[ "$step" =~ ^([^[:space:]]+)(.*)$ ]]; then
        local first="${BASH_REMATCH[1]}"
        local rest="${BASH_REMATCH[2]}"
        case "$first" in
            desmond-*|*/scripts/*.sh|scripts/*.sh)
                printf '%s%s%s%s' "$UI_CYAN" "$first" "$UI_RESET" "$rest"
                return 0
                ;;
        esac
    fi
    printf '%s' "$step"
}

# Render a numbered "Next steps" block.
# Usage: next_steps STATUS [--footer-line LINE]... STEP...
# STATUS is a semantic label only; the renderer never adds or removes steps.
# With zero steps nothing is printed (not even the header).
next_steps() {
    local status="${1:-ok}"
    shift || true
    : "$status"
    local -a steps=()
    local -a footer=()
    local arg
    while (( $# > 0 )); do
        arg="$1"
        case "$arg" in
            --footer-line)
                if (( $# < 2 )); then
                    return 2
                fi
                footer+=("$2")
                shift 2
                ;;
            --)
                shift
                while (( $# > 0 )); do
                    steps+=("$1")
                    shift
                done
                ;;
            *)
                steps+=("$arg")
                shift
                ;;
        esac
    done
    if (( ${#steps[@]} == 0 )); then
        return 0
    fi
    header "Next steps:"
    local i=0
    local step
    for step in "${steps[@]}"; do
        i=$((i + 1))
        printf '  %d) ' "$i"
        _ui_step_text "$step"
        printf '\n'
    done
    if (( ${#footer[@]} > 0 )); then
        local j=0
        for step in "${footer[@]}"; do
            if (( j == 0 )); then
                printf '     '
            else
                printf '      '
            fi
            _ui_write 1 "$UI_GRAY" "$step"
            j=$((j + 1))
        done
    fi
    return 0
}

# Strip --color from an argument list into UI_ARGS.
# Supports both "--color=always" and "--color always"; "--" stops parsing.
# Returns 2 (after printing to stderr) for a missing or invalid value.
ui_parse_color_args() {
    UI_ARGS=()
    local arg
    local mode=""
    local have_mode=0
    local stop=0
    while (( $# > 0 )); do
        arg="$1"
        if (( stop )); then
            UI_ARGS+=("$arg")
            shift
            continue
        fi
        case "$arg" in
            --)
                stop=1
                UI_ARGS+=("$arg")
                shift
                ;;
            --color=*)
                mode="${arg#--color=}"
                if ! _ui_valid_mode "$mode"; then
                    _ui_invalid_mode "$mode"
                    return 2
                fi
                have_mode=1
                shift
                ;;
            --color)
                if (( $# < 2 )); then
                    _ui_invalid_mode "(missing)"
                    return 2
                fi
                mode="$2"
                if ! _ui_valid_mode "$mode"; then
                    _ui_invalid_mode "$mode"
                    return 2
                fi
                have_mode=1
                shift 2
                ;;
            *)
                UI_ARGS+=("$arg")
                shift
                ;;
        esac
    done
    if (( have_mode )); then
        ui_set_color "$mode"
    else
        ui_init
    fi
    return 0
}

ui_init
