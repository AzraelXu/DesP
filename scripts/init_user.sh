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
INVOCATION_DIR="$(pwd -P 2>/dev/null || printf '%s' "${PWD:-}")"
source "${PIPELINE_ROOT}/scripts/lib/bashrc.sh"
source "${PIPELINE_ROOT}/scripts/lib/ui.sh"

die()  { fatal "$*"; exit 1; }
warn() { ui_emit WARN "WARNING: $*"; }

usage() {
    cat <<'EOF'
Usage: init_user.sh [options]

Options:
  --work-root DIR   Use DIR as the work root (default: current directory).
  -f, --force       Allow unsafe locations (pipeline source tree, $HOME, /,
                    /tmp) and replace a ~/.bashrc block that points elsewhere.
  --no-bashrc       Do not modify ~/.bashrc.
  --color MODE      Color output: auto (default), always, or never.
  -h, --help        Show this help.

System generation (runs after the work root is created):
  By default, init_user.sh scans the directory it was run from for
  .pdb/.mae/.maegz complexes and writes systems/<name>.conf for each one.
  All complexes must have the ligand on the same chain. If generation has
  failures, init still completes the work-root setup but exits non-zero;
  use --no-systems to skip generation entirely.

  --no-systems      Do not scan for structures or generate configs.
  --input-dir DIR   Scan DIR instead of the invocation directory.
  --manifest FILE   Use an explicit list of structure files.
  --recursive       Scan subdirectories (skips nested work roots).
  --ligand-chain ID Force the ligand chain (default: auto-detect).
  --ligand-resname NAME[,NAME...]  Select the ligand by residue name.
  --ligand-asl ASL  Explicit ligand ASL (supports ligand/protein shared chains).
  --ligand-regex RE Extract {ligand} from the file name.
  --structure-field {input,prepared}
                    Write INPUT_STRUCTURE (default) or PREPARED_STRUCTURE.
  --name-template TPL
                    System-name template (default: {stem}); fields:
                    {stem} {target} {ligand} {index}.
  --target NAME     Value for {target}.
  --ligand-name-source LIST
                    Priority list for {ligand} (default: filename,resname,index).
  --name-conflict {error,suffix}
                    Action for normalized name collisions (default: error).
  --on-existing {skip,overwrite,error}
                    Action when systems/<name>.conf already exists (default: skip).
  --overwrite       Shortcut for --on-existing overwrite.
  --skip            Shortcut for --on-existing skip (default).
  --dry-run         Preview system generation only; init still creates the
                    work-root layout and the managed ~/.bashrc block.

The work root is recorded in DIR/.desmond_work_root and exported from the
managed ~/.bashrc block. If DIR is not writable, $HOME/desmond_md_work is used.
EOF
}

ui_parse_color_args "$@" || exit $?
set -- "${UI_ARGS[@]+"${UI_ARGS[@]}"}"

WORK_ROOT_ARG=""
FORCE="no"
NO_BASHRC="no"

NO_SYSTEMS="no"
INPUT_DIR=""
INPUT_DIR_SET="no"
MANIFEST=""
RECURSIVE="no"
GEN_ARGS=()
GEN_FLAGS_USED="no"
EXISTING_MODE=""
SYS_DRY="no"

while (( $# > 0 )); do
    case "$1" in
        --work-root)
            [[ $# -ge 2 && -n "$2" ]] || die "--work-root requires a directory"
            WORK_ROOT_ARG="$2"
            shift 2
            ;;
        -f|--force)
            FORCE="yes"
            shift
            ;;
        --no-bashrc)
            NO_BASHRC="yes"
            shift
            ;;
        --no-systems)
            NO_SYSTEMS="yes"
            shift
            ;;
        --input-dir)
            [[ $# -ge 2 && -n "$2" ]] || die "--input-dir requires a directory"
            INPUT_DIR="$2"
            INPUT_DIR_SET="yes"
            GEN_FLAGS_USED="yes"
            shift 2
            ;;
        --manifest)
            [[ $# -ge 2 && -n "$2" ]] || die "--manifest requires a file"
            MANIFEST="$2"
            GEN_FLAGS_USED="yes"
            shift 2
            ;;
        --recursive)
            RECURSIVE="yes"
            GEN_ARGS+=(--recursive)
            GEN_FLAGS_USED="yes"
            shift
            ;;
        --ligand-chain|--ligand-resname|--ligand-asl|--ligand-regex|--name-template|--target|--ligand-name-source)
            [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
            GEN_ARGS+=("$1" "$2")
            GEN_FLAGS_USED="yes"
            shift 2
            ;;
        --structure-field)
            [[ $# -ge 2 && -n "$2" ]] || die "--structure-field requires a value"
            case "$2" in
                input|prepared) ;;
                *) die "--structure-field must be input or prepared" ;;
            esac
            GEN_ARGS+=("$1" "$2")
            GEN_FLAGS_USED="yes"
            shift 2
            ;;
        --name-conflict)
            [[ $# -ge 2 && -n "$2" ]] || die "--name-conflict requires a value"
            case "$2" in
                error|suffix) ;;
                *) die "--name-conflict must be error or suffix" ;;
            esac
            GEN_ARGS+=("$1" "$2")
            GEN_FLAGS_USED="yes"
            shift 2
            ;;
        --on-existing)
            [[ $# -ge 2 && -n "$2" ]] || die "--on-existing requires a value"
            case "$2" in
                skip|overwrite|error) ;;
                *) die "--on-existing must be skip, overwrite, or error" ;;
            esac
            [[ -z "$EXISTING_MODE" ]] || die "--on-existing/--overwrite/--skip may be given only once"
            EXISTING_MODE="$2"
            GEN_ARGS+=("$1" "$2")
            GEN_FLAGS_USED="yes"
            shift 2
            ;;
        --overwrite|--skip)
            [[ -z "$EXISTING_MODE" ]] || die "--on-existing/--overwrite/--skip may be given only once"
            EXISTING_MODE="${1#--}"
            GEN_ARGS+=(--on-existing "$EXISTING_MODE")
            GEN_FLAGS_USED="yes"
            shift
            ;;
        --dry-run)
            GEN_ARGS+=(--dry-run)
            GEN_FLAGS_USED="yes"
            SYS_DRY="yes"
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

if [[ "$NO_SYSTEMS" == "yes" && "$GEN_FLAGS_USED" == "yes" ]]; then
    die "--no-systems cannot be combined with system-generation options"
fi
if [[ -n "$MANIFEST" && "$INPUT_DIR_SET" == "yes" ]]; then
    die "--manifest and --input-dir are mutually exclusive"
fi
if [[ -z "$INPUT_DIR" ]]; then
    INPUT_DIR="$INVOCATION_DIR"
fi
if [[ "$NO_SYSTEMS" == "no" ]]; then
    if [[ -n "$MANIFEST" ]]; then
        [[ -f "$MANIFEST" ]] || die "--manifest file not found: $MANIFEST"
    elif [[ "$INPUT_DIR_SET" == "yes" ]]; then
        [[ -d "$INPUT_DIR" ]] || die "--input-dir is not a directory: $INPUT_DIR"
    fi
fi

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

# Validate generation arguments before creating the layout or touching
# ~/.bashrc. This uses generate_systems.py's own parser, so the checks stay in
# sync with the standalone CLI.
if [[ "$NO_SYSTEMS" == "no" && "$GEN_FLAGS_USED" == "yes" \
      && -x "${SCHRODINGER}/run" && ( -n "$MANIFEST" || -d "$INPUT_DIR" ) ]]; then
    ARG_CHECK=(--check-args)
    if [[ -n "$MANIFEST" ]]; then
        ARG_CHECK+=(--manifest "$MANIFEST")
    else
        ARG_CHECK+=(--input-dir "$INPUT_DIR")
    fi
    if (( ${#GEN_ARGS[@]} > 0 )); then
        ARG_CHECK+=("${GEN_ARGS[@]}")
    fi
    env SCH_WORK_ROOT="$SCH_WORK_ROOT" SCHRODINGER="$SCHRODINGER" \
        "${SCHRODINGER}/run" python3 "${PIPELINE_ROOT}/scripts/generate_systems.py" \
        "${ARG_CHECK[@]}" || exit $?
fi

# ---------------------------------------------------------------------------
# Create the layout and record the marker.
# ---------------------------------------------------------------------------
mkdir -p "${SCH_WORK_ROOT}/projects" "${SCH_WORK_ROOT}/results" \
         "${SCH_WORK_ROOT}/systems" "${GPU_LOCK_DIR}"

if [[ ! -f "${SCH_WORK_ROOT}/systems/example.conf" ]]; then
    cp "${PIPELINE_ROOT}/systems/example.conf.example" \
       "${SCH_WORK_ROOT}/systems/example.conf"
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
    "desmond-systems=${PIPELINE_ROOT}/scripts/generate_systems.sh"
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
# Batch system generation. The find below is only a cheap "should we invoke"
# probe; generate_systems.py performs the authoritative discovery.
# ---------------------------------------------------------------------------
SYS_RC=0
SYS_RAN="no"
if [[ "$NO_SYSTEMS" == "no" && -z "$MANIFEST" && ! -d "$INPUT_DIR" ]]; then
    echo "Input directory is not usable: ${INPUT_DIR}; system generation skipped."
    NO_SYSTEMS="yes"
fi
if [[ "$NO_SYSTEMS" == "no" ]]; then
    HAVE_INPUTS=""
    FIND_RC=0
    if [[ -n "$MANIFEST" ]]; then
        HAVE_INPUTS="yes"
    elif [[ "$RECURSIVE" == "yes" ]]; then
        HAVE_INPUTS="$(find -H "$INPUT_DIR" -mindepth 1 \
            -type d \( -name '.*' -o -name .gpu_locks -o -name projects -o -name results \
               -o -name systems -o -name __pycache__ \) -prune -o \
            -type d -exec sh -c 'test -f "$1/.desmond_work_root"' sh {} \; -prune -o \
            -xtype f \( -iname '*.pdb' -o -iname '*.mae' -o -iname '*.maegz' \) \
            -print -quit 2>/dev/null)" || FIND_RC=$?
    else
        HAVE_INPUTS="$(find -H "$INPUT_DIR" -maxdepth 1 \
            -xtype f \( -iname '*.pdb' -o -iname '*.mae' -o -iname '*.maegz' \) \
            -print -quit 2>/dev/null)" || FIND_RC=$?
    fi
    if [[ -z "$HAVE_INPUTS" && "$FIND_RC" != "0" ]]; then
        warn "cannot scan ${INPUT_DIR}; attempting system generation anyway"
        HAVE_INPUTS="yes"
    fi

    if [[ -n "$HAVE_INPUTS" ]]; then
        if [[ -x "${SCHRODINGER}/run" ]]; then
            GEN_CMD=(bash "${PIPELINE_ROOT}/scripts/generate_systems.sh")
            if [[ -n "$MANIFEST" ]]; then
                GEN_CMD+=(--manifest "$MANIFEST")
            else
                GEN_CMD+=(--input-dir "$INPUT_DIR")
            fi
            if (( ${#GEN_ARGS[@]} > 0 )); then
                GEN_CMD+=("${GEN_ARGS[@]}")
            fi
            SYS_RAN="yes"
            SYS_RC=0
            env SCH_WORK_ROOT="$SCH_WORK_ROOT" SCHRODINGER="$SCHRODINGER" \
                "${GEN_CMD[@]}" || SYS_RC=$?
        else
            warn "Schrodinger not found at ${SCHRODINGER}; skipping system config generation (use --no-systems to silence)"
        fi
    else
        echo "No .pdb/.mae/.maegz found in ${INPUT_DIR}; system generation skipped."
    fi
fi

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
ui_kv "Work root" "${SCH_WORK_ROOT}  (${SOURCE})"
ui_kv "Marker" "${SCH_WORK_ROOT}/.desmond_work_root"
ui_kv "Systems" "${SCH_WORK_ROOT}/systems"
ui_kv "Projects" "${SCH_WORK_ROOT}/projects"
ui_kv "Results" "${SCH_WORK_ROOT}/results"
ui_kv "GPU locks" "${GPU_LOCK_DIR}"
echo

if [[ "$BASHRC_OK" == "yes" ]]; then
    header "Shell setup:"
    echo "  Updated ${BASHRC} (managed block):"
    printf "    export SCH_WORK_ROOT='%s'  " "$SCH_WORK_ROOT"
    debug "(only when it is not already set)"
    echo "    aliases: desmond-init desmond-check desmond-smoke desmond-submit desmond-batch desmond-status desmond-results desmond-systems"
    echo "  For the current shell:"
    if [[ -n "$CALLER_SCH_WORK_ROOT" && "$CALLER_SCH_WORK_ROOT" != "$SCH_WORK_ROOT" ]]; then
        echo "    unset SCH_WORK_ROOT && source ${BASHRC}"
    else
        echo "    source ${BASHRC}"
    fi
    echo "  New interactive shells pick this up automatically."
else
    header "Shell setup (manual):"
    printf '  export SCH_WORK_ROOT=%q\n' "$SCH_WORK_ROOT"
    _pair=""
    for _pair in "${ALIASES[@]}"; do
        printf '  alias %s=%q\n' "${_pair%%=*}" "${_pair#*=}"
    done
    echo "  Aliases only work in interactive shells; scripts/cron need the"
    echo "  absolute script paths or an exported SCH_WORK_ROOT."
fi
echo
_steps=()
if [[ "$SYS_RAN" == "yes" && "$SYS_RC" == "0" ]]; then
    if [[ "$SYS_DRY" == "yes" ]]; then
        _steps+=("Dry run only; re-run init_user.sh without --dry-run (or run desmond-systems) to write configs.")
    else
        _steps+=("Review generated configs in ${SCH_WORK_ROOT}/systems/.")
    fi
    if [[ "$BASHRC_OK" == "yes" ]]; then
        _steps+=("desmond-batch ${SCH_WORK_ROOT}/systems/")
        _steps+=("desmond-status")
        _steps+=("desmond-results")
    else
        _steps+=("${PIPELINE_ROOT}/scripts/submit_batch.sh ${SCH_WORK_ROOT}/systems/")
        _steps+=("${PIPELINE_ROOT}/scripts/status.sh")
        _steps+=("${PIPELINE_ROOT}/scripts/collect_results.sh")
    fi
    next_steps ok "${_steps[@]}" \
        --footer-line "(example.conf is a template; directory batch submission skips it" \
        --footer-line "by default. Pass it explicitly if you really need to run it.)"
else
    _steps+=("Edit ${SCH_WORK_ROOT}/systems/example.conf (input path + ASLs).")
    if [[ "$BASHRC_OK" == "yes" ]]; then
        _steps+=("desmond-check")
        _steps+=("desmond-smoke")
        _steps+=("desmond-submit ${SCH_WORK_ROOT}/systems/example.conf")
        _steps+=("desmond-status example")
        _steps+=("desmond-results example")
    else
        _steps+=("${PIPELINE_ROOT}/scripts/check_env.sh")
        _steps+=("${PIPELINE_ROOT}/scripts/submit_smoke.sh")
        _steps+=("${PIPELINE_ROOT}/scripts/submit_system.sh ${SCH_WORK_ROOT}/systems/example.conf")
        _steps+=("${PIPELINE_ROOT}/scripts/status.sh example")
        _steps+=("${PIPELINE_ROOT}/scripts/collect_results.sh example")
    fi
    next_steps failed "${_steps[@]}"
fi
if [[ "$SYS_RC" != "0" ]]; then
    echo
    warn "system generation had failures; fix the input structures and re-run desmond-systems."
fi
exit "$SYS_RC"
