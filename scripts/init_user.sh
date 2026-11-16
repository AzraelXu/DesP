#!/bin/bash
# Initialize a per-user work root for the shared Desmond pipeline.
# The shared code directory is read-only; all outputs go under $SCH_WORK_ROOT.
# By default the work root is the current directory; if it is not writable,
# fall back to $HOME/desmond_md_work. A .desmond_work_root marker and a managed
# ~/.bashrc block make the choice stable from any subdirectory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PIPELINE_ROOT
source "${PIPELINE_ROOT}/scripts/lib/bashrc.sh"

die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
Usage: init_user.sh [options]

Options:
  --work-root DIR   Use DIR as the work root (default: current directory).
  --force           Allow unsafe locations (pipeline source tree, $HOME, /,
                    /tmp) and replace a ~/.bashrc block that points elsewhere.
  --no-bashrc       Do not modify ~/.bashrc.
  -h, --help        Show this help.

The work root is recorded in DIR/.desmond_work_root and exported from the
managed ~/.bashrc block. If DIR is not writable, $HOME/desmond_md_work is used.
EOF
}

WORK_ROOT_ARG=""
FORCE="no"
NO_BASHRC="no"

while (( $# > 0 )); do
    case "$1" in
        --work-root)
            [[ $# -ge 2 && -n "$2" ]] || die "--work-root requires a directory"
            WORK_ROOT_ARG="$2"
            shift 2
            ;;
        --force)
            FORCE="yes"
            shift
            ;;
        --no-bashrc)
            NO_BASHRC="yes"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            die "unknown option: $1"
            ;;
    esac
done

CALLER_SCH_WORK_ROOT="${SCH_WORK_ROOT:-}"
CALLER_PIPELINE_WORK_ROOT="${PIPELINE_WORK_ROOT:-}"
BASHRC="${HOME}/.bashrc"
MANAGED_OLD="$(desmond_bashrc_managed_work_root "$BASHRC" 2>/dev/null || true)"

canon_path() {
    local p="$1"
    if [[ "$p" != /* ]]; then
        p="${PWD}/${p}"
    fi
    if command -v readlink >/dev/null 2>&1; then
        readlink -m "$p" 2>/dev/null || printf '%s' "$p"
    else
        printf '%s' "$p"
    fi
}

env_root_path() {
    local p="$1"
    if [[ "$p" != /* ]]; then
        p="${HOME}/${p}"
    fi
    canon_path "$p"
}

valid_root_chars() {
    local p="$1"
    [[ -n "$p" ]] || return 1
    [[ "$p" =~ ^[[:print:]]+$ ]] || return 1
    case "$p" in
        *' '*|*$'\t'*|*'"'*|*'$'*|*'`'*|*'\'*) return 1 ;;
    esac
    return 0
}

probe_writable() {
    local d="$1"
    [[ -d "$d" && -w "$d" && -x "$d" ]] || return 1
    local probe="$d/.desmond_init_probe.$$"
    if mkdir "$probe" 2>/dev/null; then
        rmdir "$probe" 2>/dev/null || true
        return 0
    fi
    return 1
}

find_marker_up() {
    local d
    d="$(pwd -P 2>/dev/null || true)"
    [[ -n "$d" ]] || return 1
    while :; do
        if [[ -f "$d/.desmond_work_root" ]]; then
            printf '%s' "$d"
            return 0
        fi
        [[ "$d" == "/" ]] && break
        d="$(dirname "$d")"
    done
    return 1
}

refuse() {
    local msg="$1"
    if [[ "$FORCE" == "yes" ]]; then
        warn "overriding safety check: ${msg}"
        return 0
    fi
    die "${msg} (use --force to override)"
}

# ---------------------------------------------------------------------------
# Select the work root. $PWD is only the init-time default; other commands use
# the .desmond_work_root marker or an explicit SCH_WORK_ROOT.
# ---------------------------------------------------------------------------
SELECTED=""
SOURCE=""
EXPLICIT="no"

if [[ -n "$WORK_ROOT_ARG" ]]; then
    SELECTED="$(canon_path "$WORK_ROOT_ARG")"
    SOURCE="--work-root"
    EXPLICIT="yes"
elif [[ -n "$CALLER_SCH_WORK_ROOT" && "$CALLER_SCH_WORK_ROOT" != "$MANAGED_OLD" ]]; then
    SELECTED="$(env_root_path "$CALLER_SCH_WORK_ROOT")"
    SOURCE="environment"
    EXPLICIT="yes"
elif [[ -n "$CALLER_PIPELINE_WORK_ROOT" && "$CALLER_PIPELINE_WORK_ROOT" != "$MANAGED_OLD" ]]; then
    SELECTED="$(env_root_path "$CALLER_PIPELINE_WORK_ROOT")"
    SOURCE="environment (PIPELINE_WORK_ROOT, deprecated)"
    EXPLICIT="yes"
else
    SELECTED="$(pwd -P 2>/dev/null || true)"
    [[ -n "$SELECTED" ]] || SELECTED="${PWD:-}"
    SOURCE="current directory"
fi

CANON_PIPELINE="$(canon_path "$PIPELINE_ROOT")"
CANON_HOME="$(canon_path "$HOME")"
CANON_SELECTED=""
[[ -n "$SELECTED" ]] && CANON_SELECTED="$(canon_path "$SELECTED")"

# Safety checks run before creating any file or directory.
if [[ -n "$CANON_SELECTED" ]]; then
    case "$CANON_SELECTED" in
        "$CANON_PIPELINE"|"$CANON_PIPELINE"/*)
            refuse "refusing to use the pipeline source directory as the work root: ${CANON_SELECTED}"
            ;;
    esac
    if [[ "$CANON_SELECTED" == "$CANON_HOME" ]]; then
        refuse "refusing to use \$HOME as the work root: ${CANON_SELECTED}"
    fi
    if [[ "$CANON_SELECTED" == "/" ]]; then
        refuse "refusing to use / as the work root"
    fi
    case "$CANON_SELECTED" in
        /tmp|/tmp/*)
            refuse "refusing to use /tmp as the work root: ${CANON_SELECTED}"
            ;;
    esac
fi

EXISTING_UP="$(find_marker_up || true)"
if [[ -n "$EXISTING_UP" ]]; then
    CANON_UP="$(canon_path "$EXISTING_UP")"
    if [[ "$CANON_UP" != "$CANON_SELECTED" ]]; then
        refuse "current directory is inside an existing work root (${CANON_UP}); refusing to create a nested root at ${CANON_SELECTED}"
    fi
fi

if [[ -n "$MANAGED_OLD" ]]; then
    CANON_MANAGED="$(canon_path "$MANAGED_OLD")"
    if [[ "$CANON_MANAGED" != "$CANON_SELECTED" ]]; then
        refuse "${BASHRC} already points SCH_WORK_ROOT at ${CANON_MANAGED}; refusing to change it to ${CANON_SELECTED}"
    fi
fi

# ---------------------------------------------------------------------------
# Validate/fallback. Explicit bad paths are fatal; an unusable $PWD falls back.
# ---------------------------------------------------------------------------
if [[ -z "$CANON_SELECTED" ]]; then
    if [[ "$EXPLICIT" == "yes" ]]; then
        die "work root is empty"
    fi
    warn "current directory is not usable; using ${HOME}/desmond_md_work"
    CANON_SELECTED="$(canon_path "${HOME}/desmond_md_work")"
    SOURCE="fallback"
fi

if ! valid_root_chars "$CANON_SELECTED"; then
    if [[ "$EXPLICIT" == "yes" ]]; then
        die "work root contains unsupported characters (spaces, tabs, quotes, \$, backticks, or backslashes): ${CANON_SELECTED}"
    fi
    warn "current directory contains unsupported characters; using ${HOME}/desmond_md_work"
    CANON_SELECTED="$(canon_path "${HOME}/desmond_md_work")"
    SOURCE="fallback"
    valid_root_chars "$CANON_SELECTED" \
        || die "fallback work root contains unsupported characters: ${CANON_SELECTED}"
fi

if [[ ! -d "$CANON_SELECTED" ]]; then
    if [[ "$EXPLICIT" == "yes" ]]; then
        mkdir -p "$CANON_SELECTED" 2>/dev/null \
            || die "cannot create work root: ${CANON_SELECTED}"
    else
        warn "current directory is not usable; using ${HOME}/desmond_md_work"
        CANON_SELECTED="$(canon_path "${HOME}/desmond_md_work")"
        SOURCE="fallback"
        mkdir -p "$CANON_SELECTED" 2>/dev/null \
            || die "cannot create fallback work root: ${CANON_SELECTED}"
    fi
fi

if ! probe_writable "$CANON_SELECTED"; then
    if [[ "$EXPLICIT" == "yes" ]]; then
        die "work root is not writable: ${CANON_SELECTED}"
    fi
    warn "current directory is not writable; using ${HOME}/desmond_md_work"
    CANON_SELECTED="$(canon_path "${HOME}/desmond_md_work")"
    SOURCE="fallback"
    mkdir -p "$CANON_SELECTED" 2>/dev/null \
        || die "cannot create fallback work root: ${CANON_SELECTED}"
    probe_writable "$CANON_SELECTED" \
        || die "fallback work root is not writable: ${CANON_SELECTED}"
fi

export SCH_WORK_ROOT="$CANON_SELECTED"
unset PIPELINE_WORK_ROOT
source "${PIPELINE_ROOT}/config.sh"

# ---------------------------------------------------------------------------
# Create the layout and record the marker.
# ---------------------------------------------------------------------------
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

{
    printf 'SCH_WORK_ROOT=%s\n' "$SCH_WORK_ROOT"
    printf 'CREATED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
} > "${SCH_WORK_ROOT}/.desmond_work_root"

# ---------------------------------------------------------------------------
# ~/.bashrc shortcuts.
# ---------------------------------------------------------------------------
ALIASES=(
    "desmond-init=${PIPELINE_ROOT}/scripts/init_user.sh"
    "desmond-check=${PIPELINE_ROOT}/scripts/check_env.sh"
    "desmond-smoke=${PIPELINE_ROOT}/scripts/submit_smoke.sh"
    "desmond-submit=${PIPELINE_ROOT}/scripts/submit_system.sh"
    "desmond-batch=${PIPELINE_ROOT}/scripts/submit_batch.sh"
    "desmond-status=${PIPELINE_ROOT}/scripts/status.sh"
    "desmond-results=${PIPELINE_ROOT}/scripts/collect_results.sh"
)

BASHRC_OK="no"
if [[ "$NO_BASHRC" == "no" ]]; then
    if desmond_bashrc_install "$BASHRC" "$SCH_WORK_ROOT" "${ALIASES[@]}"; then
        BASHRC_OK="yes"
    else
        warn "${BASHRC} was not updated; use the export/aliases printed below."
    fi
fi

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
echo "Work root : ${SCH_WORK_ROOT}  (${SOURCE})"
echo "Marker    : ${SCH_WORK_ROOT}/.desmond_work_root"
echo "Systems   : ${SCH_WORK_ROOT}/systems"
echo "Projects  : ${SCH_WORK_ROOT}/projects"
echo "Results   : ${SCH_WORK_ROOT}/results"
echo "GPU locks : ${GPU_LOCK_DIR}"
echo

if [[ "$BASHRC_OK" == "yes" ]]; then
    echo "Shell setup:"
    echo "  Updated ${BASHRC} (managed block):"
    printf "    export SCH_WORK_ROOT='%s'  (only when it is not already set)\n" "$SCH_WORK_ROOT"
    echo "    aliases: desmond-init desmond-check desmond-smoke desmond-submit desmond-batch desmond-status desmond-results"
    echo "  For the current shell:"
    if [[ -n "$CALLER_SCH_WORK_ROOT" && "$CALLER_SCH_WORK_ROOT" != "$SCH_WORK_ROOT" ]]; then
        echo "    unset SCH_WORK_ROOT && source ${BASHRC}"
    else
        echo "    source ${BASHRC}"
    fi
    echo "  New interactive shells pick this up automatically."
else
    echo "Shell setup (manual):"
    printf '  export SCH_WORK_ROOT=%q\n' "$SCH_WORK_ROOT"
    _pair=""
    for _pair in "${ALIASES[@]}"; do
        printf '  alias %s=%q\n' "${_pair%%=*}" "${_pair#*=}"
    done
    echo "  Aliases only work in interactive shells; scripts/cron need the"
    echo "  absolute script paths or an exported SCH_WORK_ROOT."
fi
echo
echo "Next steps:"
echo "  1) Edit ${SCH_WORK_ROOT}/systems/example.conf (input path + ASLs)."
if [[ "$BASHRC_OK" == "yes" ]]; then
    echo "  2) desmond-check"
    echo "  3) desmond-smoke"
    echo "  4) desmond-submit ${SCH_WORK_ROOT}/systems/example.conf"
    echo "  5) desmond-status example"
else
    echo "  2) ${PIPELINE_ROOT}/scripts/check_env.sh"
    echo "  3) ${PIPELINE_ROOT}/scripts/submit_smoke.sh"
    echo "  4) ${PIPELINE_ROOT}/scripts/submit_system.sh ${SCH_WORK_ROOT}/systems/example.conf"
    echo "  5) ${PIPELINE_ROOT}/scripts/status.sh example"
fi
