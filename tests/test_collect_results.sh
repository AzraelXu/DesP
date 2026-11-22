#!/bin/bash
# collect_results.sh: all-project mode, optional system/directory filter.
set -uo pipefail
source "$(dirname "$0")/lib/testlib.sh"
new_sandbox

FAKE_SCHRODINGER="$SANDBOX/fake-schrodinger"
mkdir -p "$FAKE_SCHRODINGER"
cat > "$FAKE_SCHRODINGER/run" <<'EOF'
#!/bin/bash
# The caller passes the interpreter as $1 (run python3 ...).
exec "$@"
EOF
chmod +x "$FAKE_SCHRODINGER/run"

WORK="$SANDBOX/work"
make_collect_project() {
    local dir_name="$1"
    local system_name="$2"
    local mean="$3"
    local p="$WORK/projects/$dir_name"
    mkdir -p "$p/results"
    printf 'SYSTEM_NAME="%s"\n' "$system_name" > "$p/project.resolved.conf"
    printf '{"mean": %s, "sem": 0.5, "n": 10, "csv": ""}\n' "$mean" \
        > "$p/results/mmgbsa_summary.json"
    : > "$p/results/${dir_name}-out_Ligand_RMSD.png"
}

make_collect_project p1 p1 -42.1
make_collect_project p2 p2 -30.0
make_collect_project aliasdir p3 -20.0

run_collect() {
    env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX/home" USER=testuser \
        LC_ALL=C TZ=UTC SCH_WORK_ROOT="$WORK" SCHRODINGER="$FAKE_SCHRODINGER" \
        SCH_SCRATCH_DIR="$SANDBOX/scratch" \
        bash "$REPO_ROOT/scripts/collect_results.sh" "$@" 2>&1
}

# ---------------------------------------------------------------------------
# No argument: all projects, Next steps, no ANSI with --color=never.
# ---------------------------------------------------------------------------
out="$(run_collect --color=never)"
rc=$?
assert_eq 0 "$rc" "collect all exit"
assert_contains "$out" "Next steps:" "collect next steps header"
assert_contains "$out" "1) Review $WORK/results/mmgbsa_summary.md" "summary step"
assert_contains "$out" "2) Review $WORK/results/ligand_rmsd_index.md" "index step"
assert_not_contains "$out" $'\033[' "collect --color=never is plain"
summary="$(cat "$WORK/results/mmgbsa_summary.md")"
index="$(cat "$WORK/results/ligand_rmsd_index.md")"
assert_contains "$summary" "| p1 |" "collect all p1"
assert_contains "$summary" "| p2 |" "collect all p2"
assert_contains "$summary" "| aliasdir |" "collect all aliasdir"
assert_contains "$index" "| p1 |" "index all p1"
assert_contains "$index" "| p2 |" "index all p2"

# ---------------------------------------------------------------------------
# System name and directory filters.
# ---------------------------------------------------------------------------
out="$(run_collect --color=never p1)"
rc=$?
assert_eq 0 "$rc" "collect by name exit"
summary="$(cat "$WORK/results/mmgbsa_summary.md")"
assert_contains "$summary" "| p1 |" "name filter keeps p1"
assert_not_contains "$summary" "| p2 |" "name filter drops p2"
assert_not_contains "$summary" "| aliasdir |" "name filter drops aliasdir"

out="$(run_collect --color=never "$WORK/projects/p2")"
rc=$?
assert_eq 0 "$rc" "collect by directory exit"
summary="$(cat "$WORK/results/mmgbsa_summary.md")"
assert_contains "$summary" "| p2 |" "directory filter keeps p2"
assert_not_contains "$summary" "| p1 |" "directory filter drops p1"

# SYSTEM_NAME may differ from the directory name.
out="$(run_collect --color=never p3)"
rc=$?
assert_eq 0 "$rc" "collect by frozen system name exit"
summary="$(cat "$WORK/results/mmgbsa_summary.md")"
assert_contains "$summary" "| aliasdir |" "frozen name resolves aliasdir"
assert_not_contains "$summary" "| p1 |" "frozen name drops p1"

# ---------------------------------------------------------------------------
# Errors and argument validation.
# ---------------------------------------------------------------------------
rc=0
out="$(run_collect --color=never does-not-exist)" || rc=$?
assert_eq 1 "$rc" "unknown project exit"
assert_contains "$out" "Project not found: does-not-exist" "unknown project message"
assert_contains "$out" "Work root: $WORK" "unknown project work root"

rc=0
run_collect --color=never p1 p2 >/dev/null 2>&1 || rc=$?
assert_eq 2 "$rc" "two project arguments exit"

rc=0
run_collect --color=never --bogus >/dev/null 2>&1 || rc=$?
assert_eq 2 "$rc" "unknown option exit"

# ---------------------------------------------------------------------------
# Color switch and help.
# ---------------------------------------------------------------------------
colored="$(run_collect --color=always)"
assert_contains "$colored" $'\033[' "collect --color=always colors"

help_out="$(run_collect --help)"
rc=$?
assert_eq 0 "$rc" "collect help exit"
assert_contains "$help_out" "Usage: collect_results.sh" "collect help usage"

finish
