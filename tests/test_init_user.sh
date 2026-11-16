#!/bin/bash
# init_user.sh: $PWD default, fallback, safety guards, managed ~/.bashrc block.
set -uo pipefail
source "$(dirname "$0")/lib/testlib.sh"
new_sandbox

# ---------------------------------------------------------------------------
# Default: the current directory, marker, managed .bashrc block.
# ---------------------------------------------------------------------------
h1="$(fresh_home h1)"
w1="$SANDBOX/w1"
mkdir -p "$w1"
out="$(INIT_HOME="$h1" run_init "$w1" --force)"
rc=$?
assert_eq 0 "$rc" "default init exit"
assert_file_exists "$w1/.desmond_work_root"
assert_file_exists "$w1/systems/example.conf"
assert_file_exists "$h1/.bashrc"
bashrc="$(cat "$h1/.bashrc")"
assert_contains "$bashrc" "export SCH_WORK_ROOT='$w1'" "bashrc export"
assert_contains "$bashrc" "alias desmond-init=$REPO_ROOT/scripts/init_user.sh" "bashrc init alias"
assert_contains "$bashrc" "alias desmond-status=$REPO_ROOT/scripts/status.sh" "bashrc status alias"

parsed="$(bash -c 'source "$1"; desmond_bashrc_managed_work_root "$2"' \
    _ "$REPO_ROOT/scripts/lib/bashrc.sh" "$h1/.bashrc")"
assert_eq "$w1" "$parsed" "managed root parser"
legacy="$SANDBOX/legacy.bashrc"
printf '%s\n' '# >>> desmond_md_pipeline (managed by init_user.sh) >>>' \
    'export SCH_WORK_ROOT="${SCH_WORK_ROOT:-/legacy/root}"' \
    '# <<< desmond_md_pipeline <<<' > "$legacy"
parsed="$(bash -c 'source "$1"; desmond_bashrc_managed_work_root "$2"' \
    _ "$REPO_ROOT/scripts/lib/bashrc.sh" "$legacy")"
assert_eq "/legacy/root" "$parsed" "legacy managed root parser"
quoted="$SANDBOX/quoted.bashrc"
printf '%s\n' '# >>> desmond_md_pipeline (managed by init_user.sh) >>>' \
    "export SCH_WORK_ROOT='/path;with;special'" \
    '# <<< desmond_md_pipeline <<<' > "$quoted"
parsed="$(bash -c 'source "$1"; desmond_bashrc_managed_work_root "$2"' \
    _ "$REPO_ROOT/scripts/lib/bashrc.sh" "$quoted")"
assert_eq "/path;with;special" "$parsed" "single-quoted managed root parser"

# ---------------------------------------------------------------------------
# Idempotent re-run: one block, byte-identical file.
# ---------------------------------------------------------------------------
cp "$h1/.bashrc" "$SANDBOX/bashrc.first"
out="$(INIT_HOME="$h1" run_init "$w1" --force)"
rc=$?
assert_eq 0 "$rc" "second init exit"
diff -q "$SANDBOX/bashrc.first" "$h1/.bashrc" >/dev/null
assert_eq 0 "$?" "bashrc idempotent"
assert_eq 1 "$(grep -c '^# >>> desmond_md_pipeline' "$h1/.bashrc")" "single managed block"

# ---------------------------------------------------------------------------
# --no-bashrc leaves .bashrc alone and prints manual instructions.
# ---------------------------------------------------------------------------
h2="$(fresh_home h2)"
w2="$SANDBOX/w2"
mkdir -p "$w2"
out="$(INIT_HOME="$h2" run_init "$w2" --force --no-bashrc)"
rc=$?
assert_eq 0 "$rc" "--no-bashrc exit"
assert_not_exists "$h2/.bashrc"
assert_file_exists "$w2/.desmond_work_root"
assert_contains "$out" "Shell setup (manual)" "manual shell setup"

# ---------------------------------------------------------------------------
# Changing the managed root requires --force.
# ---------------------------------------------------------------------------
h3="$(fresh_home h3)"
w3="$SANDBOX/w3"
w4="$SANDBOX/w4"
mkdir -p "$w3" "$w4"
out="$(INIT_HOME="$h3" run_init "$w3" --force)"
rc=$?
assert_eq 0 "$rc" "initial root exit"
cp "$h3/.bashrc" "$SANDBOX/bashrc.before-change"
out="$(INIT_HOME="$h3" run_init "$w4")"
rc=$?
if (( rc != 0 )); then pass; else fail "init in /tmp without --force should fail"; fi
diff -q "$SANDBOX/bashrc.before-change" "$h3/.bashrc" >/dev/null
assert_eq 0 "$?" "bashrc unchanged after refusal"
assert_file_exists "$w3/.desmond_work_root"
out="$(INIT_HOME="$h3" run_init "$w4" --force)"
rc=$?
assert_eq 0 "$rc" "root change with --force"
assert_contains "$(cat "$h3/.bashrc")" "export SCH_WORK_ROOT='$w4'" "bashrc points at new root"
assert_file_exists "$w3/.desmond_work_root"

# ---------------------------------------------------------------------------
# Missing .bashrc is created; a symlink is preserved.
# ---------------------------------------------------------------------------
h4="$(fresh_home h4)"
w5="$SANDBOX/w5"
mkdir -p "$w5"
out="$(INIT_HOME="$h4" run_init "$w5" --force)"
rc=$?
assert_eq 0 "$rc" "missing bashrc exit"
assert_file_exists "$h4/.bashrc"
assert_eq 644 "$(stat -c %a "$h4/.bashrc")" "created bashrc mode"

h5="$(fresh_home h5)"
mkdir -p "$h5/dotfiles"
: > "$h5/dotfiles/bashrc"
ln -s dotfiles/bashrc "$h5/.bashrc"
w6="$SANDBOX/w6"
mkdir -p "$w6"
out="$(INIT_HOME="$h5" run_init "$w6" --force)"
rc=$?
assert_eq 0 "$rc" "symlink bashrc exit"
if [[ -L "$h5/.bashrc" ]]; then pass; else fail "~/.bashrc symlink was replaced"; fi
assert_contains "$(cat "$h5/dotfiles/bashrc")" "export SCH_WORK_ROOT='$w6'" "symlink target updated"

# ---------------------------------------------------------------------------
# Unbalanced markers: do not touch the file, but init still succeeds.
# ---------------------------------------------------------------------------
h6="$(fresh_home h6)"
printf '%s\n' '# >>> desmond_md_pipeline (managed by init_user.sh) >>>' \
    'export SCH_WORK_ROOT=/old' > "$h6/.bashrc"
cp "$h6/.bashrc" "$SANDBOX/bashrc.unbalanced"
w7="$SANDBOX/w7"
mkdir -p "$w7"
out="$(INIT_HOME="$h6" run_init "$w7" --force)"
rc=$?
assert_eq 0 "$rc" "unbalanced markers init still succeeds"
assert_contains "$out" "unbalanced" "unbalanced warning"
diff -q "$SANDBOX/bashrc.unbalanced" "$h6/.bashrc" >/dev/null
assert_eq 0 "$?" "unbalanced bashrc unchanged"

# ---------------------------------------------------------------------------
# Safety guards: /tmp and the pipeline source tree require --force.
# ---------------------------------------------------------------------------
h7="$(fresh_home h7)"
w8="$SANDBOX/w8"
mkdir -p "$w8"
out="$(INIT_HOME="$h7" run_init "$w8")"
rc=$?
if (( rc != 0 )); then pass; else fail "/tmp init without --force should fail"; fi
assert_contains "$out" "refusing to use /tmp" "/tmp guard message"
assert_not_exists "$w8/.desmond_work_root"

h8="$(fresh_home h8)"
out="$(INIT_HOME="$h8" run_init "$REPO_ROOT")"
rc=$?
if (( rc != 0 )); then pass; else fail "source-tree init without --force should fail"; fi
assert_contains "$out" "pipeline source directory" "source-tree guard message"
assert_not_exists "$REPO_ROOT/.desmond_work_root"

# ---------------------------------------------------------------------------
# Unwritable $PWD falls back to $HOME/desmond_md_work.
# ---------------------------------------------------------------------------
h9="$(fresh_home h9)"
w9="$SANDBOX/w9"
mkdir -p "$w9"
chmod 0555 "$w9"
out="$(INIT_HOME="$h9" run_init "$w9" --force)"
rc=$?
chmod 0755 "$w9"
if [[ "$(id -u)" == "0" ]]; then
    pass  # root ignores mode bits; the case is covered on normal accounts
else
    assert_eq 0 "$rc" "unwritable fallback exit"
    assert_contains "$out" "not writable" "unwritable warning"
    assert_file_exists "$h9/desmond_md_work/.desmond_work_root"
fi

# ---------------------------------------------------------------------------
# A path with characters the pipeline rejects falls back instead of dying.
# ---------------------------------------------------------------------------
h10="$(fresh_home h10)"
w10="$SANDBOX/with space"
mkdir -p "$w10"
out="$(INIT_HOME="$h10" run_init "$w10" --force)"
rc=$?
assert_eq 0 "$rc" "illegal-character fallback exit"
assert_contains "$out" "unsupported characters" "illegal-character warning"
assert_file_exists "$h10/desmond_md_work/.desmond_work_root"

# ---------------------------------------------------------------------------
# --work-root and explicit SCH_WORK_ROOT override $PWD.
# ---------------------------------------------------------------------------
h11="$(fresh_home h11)"
w11="$SANDBOX/w11"
target11="$SANDBOX/custom_root"
mkdir -p "$w11"
out="$(INIT_HOME="$h11" run_init "$w11" --work-root "$target11" --force)"
rc=$?
assert_eq 0 "$rc" "--work-root exit"
assert_file_exists "$target11/.desmond_work_root"
assert_contains "$(cat "$h11/.bashrc")" "export SCH_WORK_ROOT='$target11'" "--work-root export"

h12="$(fresh_home h12)"
w12="$SANDBOX/w12"
target12="$SANDBOX/env_root"
mkdir -p "$w12"
out="$(INIT_HOME="$h12" INIT_SCH_WORK_ROOT="$target12" run_init "$w12" --force)"
rc=$?
assert_eq 0 "$rc" "explicit env exit"
assert_file_exists "$target12/.desmond_work_root"
assert_contains "$(cat "$h12/.bashrc")" "export SCH_WORK_ROOT='$target12'" "explicit env export"

finish
