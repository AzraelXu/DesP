#!/bin/bash
# Shared UI layer: color parity, downgrade rules, argument parsing, Next steps.
set -uo pipefail
source "$(dirname "$0")/lib/testlib.sh"
new_sandbox

UI_SH="$REPO_ROOT/scripts/lib/ui.sh"
UI_PY_DIR="$REPO_ROOT/scripts"
PYTHON="$(command -v python3 || true)"
ESC=$'\033'

# Run a fixed Bash UI sequence after sourcing ui.sh.
bash_sequence() {
    local mode="$1"
    env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX/home" USER=testuser \
        LC_ALL=C TZ=UTC \
        bash -c '
            source "$1"
            ui_set_color "$2"
            ok "ok msg"
            info "info msg"
            warn "warn msg"
            error "err msg"
            debug "dbg msg"
            header "Header"
            rule "---"
            next_steps ok "desmond-status" "desmond-results"
        ' _ "$UI_SH" "$mode" 2>&1
}

# Run the same sequence through sch_ui.py.
python_sequence() {
    local mode="$1"
    env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX/home" USER=testuser \
        LC_ALL=C TZ=UTC \
        "$PYTHON" -c '
import sys
sys.path.insert(0, sys.argv[1])
import sch_ui
sch_ui.set_color(sys.argv[2])
sch_ui.ok("ok msg")
sch_ui.info("info msg")
sch_ui.warn("warn msg")
sch_ui.error("err msg")
sch_ui.debug("dbg msg")
sch_ui.header("Header")
sch_ui.rule("---")
sch_ui.next_steps("ok", ["desmond-status", "desmond-results"])
' "$UI_PY_DIR" "$mode" 2>&1
}

# Run one Bash UI command (helper name + arguments) and capture both streams.
bash_ui() {
    local mode="$1"
    shift
    env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX/home" USER=testuser \
        LC_ALL=C TZ=UTC \
        bash -c '
            source "$1"
            ui_set_color "$2"
            shift 2
            "$@"
        ' _ "$UI_SH" "$mode" "$@" 2>&1
}

strip_bash() {
    bash -c 'source "$1"; ui_strip "$2"' _ "$UI_SH" "$1"
}

strip_python() {
    "$PYTHON" -c '
import re
import sys
sys.stdout.write(re.sub(r"\033\[[0-9;]*m", "", sys.stdin.read()))
'
}

# ---------------------------------------------------------------------------
# Color palette and Bash/Python parity.
# ---------------------------------------------------------------------------
bash_colored="$(bash_sequence always)"
assert_contains "$bash_colored" "${ESC}[" "bash --color=always emits ANSI"
bash_plain="$(strip_bash "$bash_colored")"
assert_not_contains "$bash_plain" "${ESC}[" "bash strip removes ANSI"
assert_contains "$bash_plain" "Next steps:" "bash next steps header"
assert_contains "$bash_plain" "  1) desmond-status" "bash next steps numbering"
assert_contains "$bash_plain" "  2) desmond-results" "bash results step"

if [[ -n "$PYTHON" ]]; then
    python_colored="$(python_sequence always)"
    assert_contains "$python_colored" "${ESC}[" "python --color=always emits ANSI"
    python_plain="$(printf '%s' "$python_colored" | strip_python)"
    assert_eq "$bash_plain" "$python_plain" "bash/python parity (plain)"
    assert_eq "$(strip_bash "$bash_colored")" \
        "$(printf '%s' "$python_colored" | strip_python)" \
        "bash/python parity (stripped)"

    python_auto="$(python_sequence auto)"
    assert_not_contains "$python_auto" "${ESC}[" "python auto disables colors in a pipe"
    python_never="$(python_sequence never)"
    assert_not_contains "$python_never" "${ESC}[" "python never disables colors"
else
    printf 'SKIP: python3 not found; Python parity tests skipped\n' >&2
fi

# ---------------------------------------------------------------------------
# Automatic downgrade and precedence.
# ---------------------------------------------------------------------------
bash_auto="$(bash_sequence auto)"
assert_not_contains "$bash_auto" "${ESC}[" "bash auto disables colors in a pipe"
bash_never="$(bash_sequence never)"
assert_not_contains "$bash_never" "${ESC}[" "bash never disables colors"

downgrade_bash() {
    local var="$1"
    env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX/home" USER=testuser \
        LC_ALL=C TZ=UTC "$var" \
        bash -c 'source "$1"; ui_set_color auto; ok "x"' _ "$UI_SH" 2>&1
}
assert_not_contains "$(downgrade_bash NO_COLOR=1)" "${ESC}[" "NO_COLOR disables colors"
assert_not_contains "$(downgrade_bash CI=true)" "${ESC}[" "CI disables colors"
assert_not_contains "$(downgrade_bash TERM=dumb)" "${ESC}[" "TERM=dumb disables colors"

# Explicit always wins over the auto conditions.
precedence="$(env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX/home" \
    USER=testuser LC_ALL=C TZ=UTC NO_COLOR=1 \
    bash -c 'source "$1"; ui_set_color always; ok "x"' _ "$UI_SH" 2>&1)"
assert_contains "$precedence" "${ESC}[" "always overrides NO_COLOR"

# SCH_COLOR=always acts as the environment default.
env_always="$(env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX/home" \
    USER=testuser LC_ALL=C TZ=UTC SCH_COLOR=always \
    bash -c 'source "$1"; ok "x"' _ "$UI_SH" 2>&1)"
assert_contains "$env_always" "${ESC}[" "SCH_COLOR=always enables colors"

# ---------------------------------------------------------------------------
# --color argument parsing.
# ---------------------------------------------------------------------------
parse_out="$(bash -c '
    source "$1"
    ui_parse_color_args --all --color=always proj || exit $?
    printf "mode=%s args=%s\n" "$UI_COLOR_MODE" "${UI_ARGS[*]}"
' _ "$UI_SH")"
assert_eq "mode=always args=--all proj" "$parse_out" "--color=always parsing"

parse_out="$(bash -c '
    source "$1"
    ui_parse_color_args --color never proj || exit $?
    printf "mode=%s args=%s\n" "$UI_COLOR_MODE" "${UI_ARGS[*]}"
' _ "$UI_SH")"
assert_eq "mode=never args=proj" "$parse_out" "--color never parsing"

parse_out="$(bash -c '
    source "$1"
    ui_parse_color_args -- --color=always || exit $?
    printf "mode=%s args=%s\n" "$UI_COLOR_MODE" "${UI_ARGS[*]}"
' _ "$UI_SH")"
assert_eq "mode=auto args=-- --color=always" "$parse_out" "-- terminates color parsing"

rc=0
bash -c 'source "$1"; ui_parse_color_args --color=bogus' _ "$UI_SH" \
    >/dev/null 2>&1 || rc=$?
assert_eq 2 "$rc" "invalid --color exits 2"
rc=0
bash -c 'source "$1"; ui_parse_color_args --color' _ "$UI_SH" \
    >/dev/null 2>&1 || rc=$?
assert_eq 2 "$rc" "missing --color value exits 2"

if [[ -n "$PYTHON" ]]; then
    py_parse="$(env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX/home" \
        USER=testuser LC_ALL=C TZ=UTC "$PYTHON" -c '
import sys
sys.path.insert(0, sys.argv[1])
import sch_ui
rest = sch_ui.extract_color_arg(["--color=always", "--all", "proj"])
print("mode={} args={}".format(sch_ui.color_mode(), " ".join(rest)))
' "$UI_PY_DIR")"
    assert_eq "mode=always args=--all proj" "$py_parse" "python --color parsing"

    rc=0
    env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX/home" USER=testuser \
        LC_ALL=C TZ=UTC "$PYTHON" -c '
import sys
sys.path.insert(0, sys.argv[1])
import sch_ui
sch_ui.extract_color_arg(["--color=bogus"])
' "$UI_PY_DIR" >/dev/null 2>&1 || rc=$?
    assert_eq 2 "$rc" "python invalid --color exits 2"
fi

# ---------------------------------------------------------------------------
# next_steps: numbering, zero steps, footer, no implicit filtering.
# ---------------------------------------------------------------------------
steps_out="$(bash_ui never next_steps ok \
    --footer-line "foot one" --footer-line "foot two" \
    "Review generated configs" "desmond-status" "desmond-results")"
assert_contains "$steps_out" "Next steps:" "steps header"
assert_contains "$steps_out" "  1) Review generated configs" "step 1"
assert_contains "$steps_out" "  2) desmond-status" "step 2"
assert_contains "$steps_out" "  3) desmond-results" "step 3"
assert_contains "$steps_out" "     foot one" "footer first line indent"
assert_contains "$steps_out" "      foot two" "footer continuation indent"

zero_out="$(bash_ui never next_steps ok)"
assert_eq "" "$zero_out" "zero steps prints nothing"

filter_out="$(bash_ui never next_steps ok "desmond-check" "desmond-smoke")"
assert_contains "$filter_out" "desmond-check" "renderer does not filter check"
assert_contains "$filter_out" "desmond-smoke" "renderer does not filter smoke"

ten_args=()
for i in $(seq 1 10); do
    ten_args+=("step${i}")
done
ten_out="$(bash_ui never next_steps ok "${ten_args[@]}")"
assert_contains "$ten_out" "  9) step9" "step 9"
assert_contains "$ten_out" "  10) step10" "step 10 (no gap)"
assert_not_contains "$ten_out" "  0)" "no zero index"
assert_not_contains "$ten_out" "  11)" "no extra index"

if [[ -n "$PYTHON" ]]; then
    py_steps="$(env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX/home" \
        USER=testuser LC_ALL=C TZ=UTC "$PYTHON" -c '
import sys
sys.path.insert(0, sys.argv[1])
import sch_ui
sch_ui.next_steps("ok", ["desmond-check"], ["foot"])
' "$UI_PY_DIR")"
    assert_contains "$py_steps" "  1) desmond-check" "python no filtering"
    assert_contains "$py_steps" "     foot" "python footer indent"
    py_zero="$(env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX/home" \
        USER=testuser LC_ALL=C TZ=UTC "$PYTHON" -c '
import sys
sys.path.insert(0, sys.argv[1])
import sch_ui
sch_ui.next_steps("ok", [])
' "$UI_PY_DIR")"
    assert_eq "" "$py_zero" "python zero steps prints nothing"
fi

# ---------------------------------------------------------------------------
# ui_emit preserves legacy text after stripping ANSI.
# ---------------------------------------------------------------------------
emit_cases=(
    "WARN|[WARN] msg"
    "WARN|WARNING : msg"
    "WARN|WARNING: msg"
    "ERROR|ERROR: msg"
    "FATAL|FATAL: msg"
    "OK|[OK] msg"
    "OK|[PASS] msg"
    "FAIL|[FAIL] msg"
    "SKIP|[SKIP] msg"
    "DRY-RUN|[DRY-RUN] msg"
    "OK|PASS: msg"
    "FAIL|FAIL: msg"
    "INFO|plain text"
)
case_no=0
for item in "${emit_cases[@]}"; do
    level="${item%%|*}"
    text="${item#*|}"
    out="$(bash_ui always ui_emit "$level" "$text")"
    plain="$(strip_bash "$out")"
    assert_eq "$text" "$plain" "ui_emit preserves: ${text}"
    case_no=$((case_no + 1))
done

# FATAL label must use the red-background variant.
fatal_out="$(bash_ui always ui_emit FATAL "FATAL: boom")"
assert_contains "$fatal_out" "1;97;41" "FATAL label uses red background"

# ---------------------------------------------------------------------------
# ui_kv preserves the legacy alignment.
# ---------------------------------------------------------------------------
assert_eq "Work root : /x" "$(bash_ui never ui_kv "Work root" "/x" 10)" \
    "ui_kv width 10"
assert_eq "Progress: 1/2" "$(bash_ui never ui_kv "Progress" "1/2" 8)" \
    "ui_kv width 8"
kv_colored="$(bash_ui always ui_kv "Work root" "/x" 10)"
assert_contains "$kv_colored" "${ESC}[" "ui_kv colors when enabled"
assert_eq "Work root : /x" "$(strip_bash "$kv_colored")" "ui_kv strips cleanly"

if [[ -n "$PYTHON" ]]; then
    py_kv="$(env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX/home" \
        USER=testuser LC_ALL=C TZ=UTC "$PYTHON" -c '
import sys
sys.path.insert(0, sys.argv[1])
import sch_ui
sch_ui.kv("Work root", "/x", 10)
' "$UI_PY_DIR")"
    assert_eq "Work root : /x" "$py_kv" "python kv width 10"
fi

# ---------------------------------------------------------------------------
# ui_strip.
# ---------------------------------------------------------------------------
raw="${ESC}[1;31mred${ESC}[0m plain"
assert_eq "red plain" "$(bash -c 'source "$1"; ui_strip "$2"' _ "$UI_SH" "$raw")" \
    "ui_strip removes ANSI"

finish
