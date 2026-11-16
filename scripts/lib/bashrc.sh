#!/bin/bash
# Managed ~/.bashrc block for the Desmond pipeline.
# This file is sourced, never executed directly.

DESMOND_BRC_BEGIN='# >>> desmond_md_pipeline (managed by init_user.sh) >>>'
DESMOND_BRC_END='# <<< desmond_md_pipeline <<<'

# Print the SCH_WORK_ROOT recorded in the managed block, if any.
desmond_bashrc_managed_work_root() {
    local brc="$1"
    [[ -f "$brc" ]] || return 1
    awk -v b="$DESMOND_BRC_BEGIN" -v e="$DESMOND_BRC_END" '
        { line = $0; sub(/\r$/, "", line) }
        line == b { inblk = 1; next }
        line == e { inblk = 0; next }
        inblk && line ~ /^[[:space:]]*export SCH_WORK_ROOT=/ {
            v = line
            sub(/^[[:space:]]*export SCH_WORK_ROOT=/, "", v)
            if (v ~ /^\047.*\047$/) {
                v = substr(v, 2, length(v) - 2)
            } else if (v ~ /^".*"$/) {
                v = substr(v, 2, length(v) - 2)
            }
            sub(/^\$\{SCH_WORK_ROOT:-/, "", v)
            sub(/\}$/, "", v)
            if (v ~ /^\047.*\047$/) {
                v = substr(v, 2, length(v) - 2)
            } else if (v ~ /^".*"$/) {
                v = substr(v, 2, length(v) - 2)
            }
            print v
            exit
        }
    ' "$brc"
}

# Render the managed block to stdout.
# Usage: desmond_bashrc_render <work_root> <alias_name=script_path>...
desmond_bashrc_render() {
    local root="$1"
    shift
    printf '%s\n' "$DESMOND_BRC_BEGIN"
    printf 'if [[ -z "${SCH_WORK_ROOT:-}" ]]; then\n'
    printf "  export SCH_WORK_ROOT='%s'\n" "$root"
    printf 'fi\n'
    local pair name path
    for pair in "$@"; do
        name="${pair%%=*}"
        path="${pair#*=}"
        printf 'alias %s=%q\n' "$name" "$path"
    done
    printf '%s\n' "$DESMOND_BRC_END"
}

# Install/replace the managed block in <bashrc>.
# Usage: desmond_bashrc_install <bashrc> <work_root> <alias_name=script_path>...
# Returns 0 when the file is up to date or updated; 1 when it could not be
# modified (the block is printed so the caller can show it to the user).
desmond_bashrc_install() {
    local brc="$1"
    local root="$2"
    shift 2
    local -a aliases=("$@")

    local target="$brc"
    if [[ -L "$brc" ]]; then
        target="$(readlink -f "$brc" 2>/dev/null || printf '%s' "$brc")"
    fi

    local dir
    dir="$(dirname "$target")"
    if [[ ! -d "$dir" ]]; then
        echo "WARNING: cannot update ${brc}: directory not found: ${dir}" >&2
        desmond_bashrc_render "$root" "${aliases[@]}" >&2
        return 1
    fi

    local block
    block="$(desmond_bashrc_render "$root" "${aliases[@]}")"

    if [[ ! -e "$target" ]]; then
        if ! printf '%s\n' "$block" > "$target"; then
            echo "WARNING: cannot create ${target}" >&2
            printf '%s\n' "$block" >&2
            return 1
        fi
        chmod 644 "$target" 2>/dev/null || true
        echo "Updated ${brc} (created managed block)"
        return 0
    fi

    if [[ ! -f "$target" ]]; then
        echo "WARNING: cannot update ${brc}: not a regular file" >&2
        printf '%s\n' "$block" >&2
        return 1
    fi

    local begin_count end_count
    begin_count="$(awk -v b="$DESMOND_BRC_BEGIN" '
        { line = $0; sub(/\r$/, "", line); if (line == b) n++ }
        END { print n + 0 }' "$target" 2>/dev/null || echo 0)"
    end_count="$(awk -v e="$DESMOND_BRC_END" '
        { line = $0; sub(/\r$/, "", line); if (line == e) n++ }
        END { print n + 0 }' "$target" 2>/dev/null || echo 0)"
    if (( begin_count != end_count )); then
        echo "WARNING: ${brc} has unbalanced desmond_md_pipeline markers; not modifying it." >&2
        echo "Add this block manually:" >&2
        printf '%s\n' "$block" >&2
        return 1
    fi

    if [[ ! -w "$target" ]]; then
        echo "WARNING: ${brc} is not writable; not modifying it." >&2
        echo "Add this block manually:" >&2
        printf '%s\n' "$block" >&2
        return 1
    fi

    local tmp
    if ! tmp="$(mktemp "${dir}/.bashrc.desmond.XXXXXX")"; then
        echo "WARNING: cannot create a temporary file in ${dir}" >&2
        printf '%s\n' "$block" >&2
        return 1
    fi

    if ! awk -v b="$DESMOND_BRC_BEGIN" -v e="$DESMOND_BRC_END" '
        { line = $0; cmp = line; sub(/\r$/, "", cmp) }
        cmp == b { inblk = 1; next }
        cmp == e { inblk = 0; next }
        !inblk { print line }
    ' "$target" > "$tmp"; then
        echo "WARNING: failed to read ${target}" >&2
        rm -f "$tmp"
        return 1
    fi

    if [[ -s "$tmp" ]] && [[ -n "$(tail -c 1 "$tmp")" ]]; then
        printf '\n' >> "$tmp"
    fi
    printf '%s\n' "$block" >> "$tmp"

    if cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
        echo "${brc} already up to date"
        return 0
    fi

    local backup="${target}.desmond.bak.$(date '+%Y%m%d%H%M%S')"
    cp -p "$target" "$backup" 2>/dev/null || true

    if ! cat "$tmp" > "$target"; then
        echo "WARNING: failed to write ${target}" >&2
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    echo "Updated ${brc} (backup: ${backup})"
    return 0
}
