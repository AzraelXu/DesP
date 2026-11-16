#!/bin/bash
# Shared helpers for the Desmond pipeline shell tests.
# This file is sourced, never executed directly.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAILS=0
PASSES=0
SANDBOX=""
QSTAT_LOG=""

new_sandbox() {
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/desmond_test.XXXXXX")"
    mkdir -p "$SANDBOX/home" "$SANDBOX/work" "$SANDBOX/bin" "$SANDBOX/qstat"
    cp "$REPO_ROOT/tests/fixtures/qstat" "$SANDBOX/bin/qstat"
    cp "$REPO_ROOT/tests/fixtures/pbsnodes" "$SANDBOX/bin/pbsnodes"
    chmod +x "$SANDBOX/bin/qstat" "$SANDBOX/bin/pbsnodes"
    QSTAT_LOG="$SANDBOX/qstat.log"
    export SANDBOX QSTAT_LOG
    trap cleanup_sandbox EXIT
}

cleanup_sandbox() {
    [[ -n "${SANDBOX:-}" && -d "${SANDBOX:-}" ]] || return 0
    chmod -R u+rwX "$SANDBOX" 2>/dev/null || true
    rm -rf "$SANDBOX"
}

pass() { PASSES=$((PASSES + 1)); }
fail() { FAILS=$((FAILS + 1)); printf 'FAIL: %s\n' "$*" >&2; }

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="${3:-value}"
    if [[ "$expected" == "$actual" ]]; then
        pass
    else
        fail "$label: expected [$expected], got [$actual]"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="${3:-output}"
    if printf '%s\n' "$haystack" | grep -Fq -- "$needle"; then
        pass
    else
        fail "$label: missing [$needle]"
        printf '%s\n' "$haystack" | sed 's/^/  | /' >&2
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local label="${3:-output}"
    if printf '%s\n' "$haystack" | grep -Fq -- "$needle"; then
        fail "$label: unexpected [$needle]"
        printf '%s\n' "$haystack" | sed 's/^/  | /' >&2
    else
        pass
    fi
}

assert_file_exists() {
    if [[ -f "$1" ]]; then pass; else fail "expected file: $1"; fi
}

assert_not_exists() {
    if [[ ! -e "$1" ]]; then pass; else fail "unexpected path: $1"; fi
}

finish() {
    if (( FAILS > 0 )); then
        printf 'FAILED (%d failure(s), %d pass(es))\n' "$FAILS" "$PASSES"
        exit 1
    fi
    printf 'OK (%d pass(es))\n' "$PASSES"
    exit 0
}

epoch_now() { date +%s; }
ts() { date -d "@$1" '+%Y-%m-%d %H:%M:%S'; }
ts_qstat() { date -d "@$1" '+%a %b %d %H:%M:%S %Y'; }

fresh_home() {
    local name="$1"
    mkdir -p "$SANDBOX/$name"
    printf '%s' "$SANDBOX/$name"
}

make_project() {
    local pdir="$1"
    local name="$2"
    mkdir -p "$pdir/state" "$pdir/logs/pbs" "$pdir/results"
    cat > "$pdir/project.resolved.conf" <<EOF
export SYSTEM_NAME=$name
export MD_TIME_NS=300
export MD_TIME_PS=300000.0
export RUN_ANALYSIS=yes
export RUN_MMGBSA=yes
export FORCE_STAGES=''
export PBS_WALLTIME_PREP=24:00:00
export PBS_WALLTIME_MIN=06:00:00
export PBS_WALLTIME_MD=96:00:00
export PBS_WALLTIME_ANALYSIS=12:00:00
export PBS_WALLTIME_MMGBSA=48:00:00
EOF
}

write_jobs_env() {
    local pdir="$1"
    local run_id="$2"
    local submitted="$3"
    local prep="${4:-991}"
    local min="${5:-994}"
    local md="${6:-995}"
    local ana="${7:-996}"
    local mmg="${8:-997}"
    cat > "$pdir/state/jobs.env" <<EOF
RUN_ID=$run_id
PREP_JOB=$prep
MIN_JOB=$min
MD_JOB=$md
ANALYSIS_JOB=$ana
MMGBSA_JOB=$mmg
SUBMITTED_AT=$submitted
EOF
}

write_done() {
    local pdir="$1"
    local stage="$2"
    local jobid="$3"
    local run_id="$4"
    local start="$5"
    local end="$6"
    cat > "$pdir/state/${stage}.done" <<EOF
STAGE=$stage
STATUS=done
JOBID=$jobid
RUN_ID=$run_id
START=$start
END=$end
EOF
}

write_qstat_fixture() {
    local dir="$1"
    local id="$2"
    local state="$3"
    shift 3
    {
        printf 'Job Id: %s.cluster\n' "$id"
        printf '    job_state = %s\n' "$state"
        local line
        for line in "$@"; do
            printf '    %s\n' "$line"
        done
    } > "$dir/$id"
}

run_status() {
    local work="$1"
    shift
    env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX/home" USER=testuser \
        LC_ALL=C TZ=UTC \
        SCH_WORK_ROOT="$work" QSTAT="$SANDBOX/bin/qstat" \
        QSTAT_FIXTURE_DIR="$SANDBOX/qstat" QSTAT_LOG="$QSTAT_LOG" \
        PBSNODES="$SANDBOX/bin/pbsnodes" SCHRODINGER="$SANDBOX/no-schrodinger" \
        STATUS_NOW="${STATUS_NOW:-$(date +%s)}" \
        bash "$REPO_ROOT/scripts/status.sh" "$@"
}

run_status_no_qstat() {
    local work="$1"
    shift
    env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX/home" USER=testuser \
        LC_ALL=C TZ=UTC \
        SCH_WORK_ROOT="$work" QSTAT="$SANDBOX/missing-qstat" \
        QSTAT_FIXTURE_DIR="$SANDBOX/qstat" PBSNODES="$SANDBOX/bin/pbsnodes" \
        SCHRODINGER="$SANDBOX/no-schrodinger" \
        STATUS_NOW="${STATUS_NOW:-$(date +%s)}" \
        bash "$REPO_ROOT/scripts/status.sh" "$@"
}

run_init() {
    local cwd="$1"
    shift
    local home="${INIT_HOME:-$SANDBOX/home}"
    ( cd "$cwd" && env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$home" \
        USER=testuser LC_ALL=C TZ=UTC \
        SCH_WORK_ROOT="${INIT_SCH_WORK_ROOT:-}" \
        PIPELINE_WORK_ROOT="${INIT_PIPELINE_WORK_ROOT:-}" \
        bash "$REPO_ROOT/scripts/init_user.sh" "$@" 2>&1 )
}
