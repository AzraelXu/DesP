#!/bin/bash
# status.sh: project-centric stage/ETA/warning output, no qstat/pbsnodes dump.
set -uo pipefail
source "$(dirname "$0")/lib/testlib.sh"
new_sandbox

now="$(epoch_now)"
submitted="$(ts $((now - 8000)))"

reset_status_state() {
    rm -f "$SANDBOX/qstat/"*
    : > "$QSTAT_LOG"
    STATUS_NOW="$now"
}

# ---------------------------------------------------------------------------
# Queued PREP: current step, queue wait, estimated start, walltime headroom.
# ---------------------------------------------------------------------------
reset_status_state
workq="$SANDBOX/workq"
q="$workq/projects/q"
make_project "$q" q
write_jobs_env "$q" run1 "$submitted" 991 "" "" "" ""
write_qstat_fixture "$SANDBOX/qstat" 991 Q \
    "Resource_List.walltime = 24:00:00" \
    "estimated.start_time = Mon Nov 16 21:00:00 2026"

out="$(run_status "$workq" q)"
assert_contains "$out" "Step    : prepwizard (1/6) -- queued (PBS 991)" "queued PREP"
assert_contains "$out" "estimated start" "estimated start"
assert_contains "$out" "PBS walltime left" "queued walltime"

# ---------------------------------------------------------------------------
# Running MD: real ETA from chemical time + ns/day; analysis/MM-GBSA waiting.
# ---------------------------------------------------------------------------
reset_status_state
work="$SANDBOX/work"
p="$work/projects/p"
make_project "$p" p
write_jobs_env "$p" run1 "$submitted"
write_done "$p" prepwizard 991 run1 "$submitted" "$(ts $((now - 7000)))"
write_done "$p" setup 991 run1 "$submitted" "$(ts $((now - 7000)))"
write_done "$p" min 994 run1 "$submitted" "$(ts $((now - 7000)))"
mkdir -p "$p/desmond_md_job_p"
for i in 1 2 3 4 5; do
    printf 'Chemical time: %s ps, Step: %s, ns/day: 250.1\n' \
        "$((i * 86))" "$((i * 100))" >> "$p/desmond_md_job_p/desmond_md_job_p.log"
done
write_qstat_fixture "$SANDBOX/qstat" 995 R \
    "resources_used.walltime = 02:14:00" \
    "Resource_List.walltime = 96:00:00" \
    "start_time = $(ts_qstat $((now - 8040)))"
write_qstat_fixture "$SANDBOX/qstat" 996 H \
    "Hold_Types = s" "Resource_List.walltime = 12:00:00"
write_qstat_fixture "$SANDBOX/qstat" 997 H \
    "Hold_Types = s" "Resource_List.walltime = 48:00:00"
printf '[WARN] %s test warning\n' "$(ts $((now - 3000)))" > "$p/logs/pipeline.log"

out="$(run_status "$work" p)"
assert_contains "$out" "Step    : md (4/6) -- running (PBS 995), elapsed 2h 14m" "MD running"
assert_contains "$out" "Step    : analysis (5/6) -- waiting for dependency (PBS 996)" "analysis waiting"
assert_contains "$out" "Step    : mmgbsa (6/6) -- waiting for dependency (PBS 997)" "mmgbsa waiting"
assert_contains "$out" "Progress: 430 / 300000.0 ps (0.1%), avg rate 250.1 ns/day (avg10)" "MD progress"
assert_contains "$out" "ETA     : ~" "MD ETA present"
assert_contains "$out" "Warnings: 1 in this run" "warning count"
assert_contains "$out" "Errors  : none" "no errors"
assert_contains "$out" "test warning" "warning text"
assert_not_contains "$out" "Nodes and GPUs" "no node table"
assert_not_contains "$out" "pbsnodes" "no pbsnodes"
qlog="$(cat "$QSTAT_LOG")"
assert_not_contains "$qlog" " -u " "no qstat -u"
assert_not_contains "$qlog" " -x " "no qstat -x"
assert_contains "$qlog" "-f -1 995" "qstat -f -1 for MD"
assert_not_contains "$qlog" "-f -1 991" "no qstat for current-run PREP marker"
assert_not_contains "$qlog" "-f -1 994" "no qstat for current-run MIN marker"

# ---------------------------------------------------------------------------
# Running MD whose engine log is only in shared scratch ($HOME/tmp/$USER).
# ---------------------------------------------------------------------------
reset_status_state
works="$SANDBOX/work-scratch"
ps="$works/projects/pscratch"
make_project "$ps" pscratch
write_jobs_env "$ps" run1 "$submitted"
write_done "$ps" prepwizard 991 run1 "$submitted" "$(ts $((now - 7000)))"
write_done "$ps" setup 991 run1 "$submitted" "$(ts $((now - 7000)))"
write_done "$ps" min 994 run1 "$submitted" "$(ts $((now - 7000)))"
scratch="$SANDBOX/home/tmp/testuser/desmond_md_job_pscratch.1"
mkdir -p "$scratch"
for i in 1 2 3 4 5; do
    printf 'Chemical time: %s ps, Step: %s, ns/day: 250.1\n' \
        "$((i * 86))" "$((i * 100))" >> "$scratch/desmond_md_job_pscratch.log"
done
# A similarly prefixed system must not be selected.
mkdir -p "$SANDBOX/home/tmp/testuser/desmond_md_job_pscratch_2"
printf 'Chemical time: 9999.0 ps, Step: 1, ns/day: 999.9\n' \
    > "$SANDBOX/home/tmp/testuser/desmond_md_job_pscratch_2/desmond_md_job_pscratch_2.log"
write_qstat_fixture "$SANDBOX/qstat" 995 R \
    "resources_used.walltime = 02:14:00" \
    "Resource_List.walltime = 96:00:00" \
    "start_time = $(ts_qstat $((now - 8040)))"
write_qstat_fixture "$SANDBOX/qstat" 996 H \
    "Hold_Types = s" "Resource_List.walltime = 12:00:00"
write_qstat_fixture "$SANDBOX/qstat" 997 H \
    "Hold_Types = s" "Resource_List.walltime = 48:00:00"

out="$(run_status "$works" pscratch)"
assert_contains "$out" "Step    : md (4/6) -- running (PBS 995)" "scratch MD running"
assert_contains "$out" "Progress: 430 / 300000.0 ps (0.1%), avg rate 250.1 ns/day (avg10)" \
    "scratch MD progress"
assert_contains "$out" "Log     : $scratch/desmond_md_job_pscratch.log" "scratch log path"
assert_contains "$out" "ETA     : ~" "scratch MD ETA"
assert_not_contains "$out" "pscratch_2" "prefixed system not used"

# ---------------------------------------------------------------------------
# Failed min: FAILED line, blocked downstream, PBS/stage-log tail.
# ---------------------------------------------------------------------------
reset_status_state
work2="$SANDBOX/work2"
f="$work2/projects/f"
make_project "$f" f
write_jobs_env "$f" run1 "$submitted"
write_done "$f" prepwizard 991 run1 "$submitted" "$(ts $((now - 7000)))"
write_done "$f" setup 991 run1 "$submitted" "$(ts $((now - 7000)))"
printf '[INFO] %s ===== stage 30_min start =====\n[INFO] %s running Desmond minimization\n' \
    "$(ts $((now - 3000)))" "$(ts $((now - 2900)))" \
    > "$f/logs/30_min_994_$(date -d "@$((now - 3000))" '+%Y%m%d%H%M%S').log"
printf 'some output\nerror: force field problem\n' > "$f/logs/pbs/min.run1.out"
printf '[FATAL] %s minimization failed\n' "$(ts $((now - 2000)))" > "$f/logs/pipeline.log"
write_qstat_fixture "$SANDBOX/qstat" 994 C \
    "exit_status = 1" "comment = Job run at Mon Nov 16 18:30:00 and finished"

out="$(run_status "$work2" f)"
assert_contains "$out" "Step    : min (3/6) -- FAILED (PBS 994), exit_status=1" "failed min"
assert_contains "$out" "Blocked : md analysis mmgbsa" "blocked downstream"
assert_contains "$out" "Errors  : 1 in this run" "FATAL count"
assert_contains "$out" "minimization failed" "FATAL text"
assert_contains "$out" "error: force field problem" "PBS tail"
assert_contains "$out" "===== stage 30_min start =====" "stage log tail"

# ---------------------------------------------------------------------------
# Complete project: only the current run's warnings are shown.
# ---------------------------------------------------------------------------
reset_status_state
work3="$SANDBOX/work3"
c="$work3/projects/c"
make_project "$c" c
write_jobs_env "$c" run1 "$submitted"
for s in prepwizard setup min md analysis mmgbsa; do
    write_done "$c" "$s" 991 run1 "$submitted" "$(ts $((now - 1000)))"
done
printf '[WARN] %s old warning from a previous run\n[WARN] %s current warning\n' \
    "$(ts $((now - 20000)))" "$(ts $((now - 3000)))" > "$c/logs/pipeline.log"
printf '# MM-GBSA\nMean dG_bind = -42.1 kcal/mol\n' > "$c/results/mmgbsa_summary.md"

out="$(run_status "$work3" c)"
assert_contains "$out" "Step    : complete (6/6)" "complete project"
assert_contains "$out" "Mean dG_bind = -42.1 kcal/mol" "results line"
assert_contains "$out" "current warning" "current warning shown"
assert_not_contains "$out" "old warning from a previous run" "old warning filtered"
assert_eq 0 "$(wc -l < "$QSTAT_LOG" 2>/dev/null || echo 0)" "no qstat for complete markers"

# ---------------------------------------------------------------------------
# Old marker + failed/purged current job must not be reported as done.
# ---------------------------------------------------------------------------
reset_status_state
work4="$SANDBOX/work4"
o="$work4/projects/o"
make_project "$o" o
write_jobs_env "$o" run1 "$submitted"
for s in prepwizard setup min; do
    write_done "$o" "$s" 991 run1 "$submitted" "$(ts $((now - 7000)))"
done
write_done "$o" md 900 run0 "2026-01-01 00:00:00" "2026-01-01 01:00:00"
printf '[INFO] %s ===== stage 40_md start =====\n[INFO] %s starting production MD\n' \
    "$(ts $((now - 3000)))" "$(ts $((now - 2900)))" \
    > "$o/logs/40_md_995_$(date -d "@$((now - 3000))" '+%Y%m%d%H%M%S').log"
printf 'multisim: fatal error\n' > "$o/logs/pbs/md.run1.out"

out="$(run_status "$work4" o)"
assert_contains "$out" "Step    : md (4/6) -- FAILED" "old marker ignored on current-run failure"
assert_not_contains "$out" "md (4/6) -- done" "old marker not reported as done"
assert_contains "$out" "multisim: fatal error" "purged-job PBS tail"

# ---------------------------------------------------------------------------
# Not submitted and disabled stages.
# ---------------------------------------------------------------------------
reset_status_state
work5="$SANDBOX/work5"
n="$work5/projects/n"
make_project "$n" n
out="$(run_status "$work5" n)"
assert_contains "$out" "Run     : not submitted" "not submitted run"
assert_contains "$out" "Step    : prepwizard (1/6) -- not submitted" "not submitted step"

reset_status_state
work6="$SANDBOX/work6"
d="$work6/projects/d"
make_project "$d" d
sed -i 's/^export RUN_ANALYSIS=.*/export RUN_ANALYSIS=no/; s/^export RUN_MMGBSA=.*/export RUN_MMGBSA=no/' \
    "$d/project.resolved.conf"
write_jobs_env "$d" run1 "$submitted"
for s in prepwizard setup min md; do
    write_done "$d" "$s" 991 run1 "$submitted" "$(ts $((now - 1000)))"
done
out="$(run_status "$work6" d)"
assert_contains "$out" "Step    : complete (4/4)" "disabled stages count"

# ---------------------------------------------------------------------------
# No qstat: file-based status still works.
# ---------------------------------------------------------------------------
reset_status_state
out="$(run_status_no_qstat "$work3" c)"
assert_contains "$out" "Note: qstat not found" "qstat missing note"
assert_contains "$out" "Step    : complete (6/6)" "complete without qstat"

# ---------------------------------------------------------------------------
# ETA exceeding the PBS walltime headroom is called out.
# ---------------------------------------------------------------------------
reset_status_state
work7="$SANDBOX/work7"
e="$work7/projects/e"
make_project "$e" e
write_jobs_env "$e" run1 "$submitted"
for s in prepwizard setup min; do
    write_done "$e" "$s" 991 run1 "$submitted" "$(ts $((now - 7000)))"
done
mkdir -p "$e/desmond_md_job_e"
printf 'Chemical time: 100.0 ps, Step: 100, ns/day: 50.0\n' \
    > "$e/desmond_md_job_e/desmond_md_job_e.log"
write_qstat_fixture "$SANDBOX/qstat" 995 R \
    "resources_used.walltime = 05:00:00" \
    "Resource_List.walltime = 06:00:00" \
    "start_time = $(ts_qstat $((now - 18000)))"
write_qstat_fixture "$SANDBOX/qstat" 996 H "Hold_Types = s"
write_qstat_fixture "$SANDBOX/qstat" 997 H "Hold_Types = s"
out="$(run_status "$work7" e)"
assert_contains "$out" "WARNING : ETA exceeds PBS walltime left" "ETA/walltime warning"

# ---------------------------------------------------------------------------
# User hold vs dependency hold.
# ---------------------------------------------------------------------------
reset_status_state
work8="$SANDBOX/work8"
h="$work8/projects/h"
make_project "$h" h
write_jobs_env "$h" run1 "$submitted"
for s in prepwizard setup min; do
    write_done "$h" "$s" 991 run1 "$submitted" "$(ts $((now - 7000)))"
done
write_qstat_fixture "$SANDBOX/qstat" 995 H "Hold_Types = u"
write_qstat_fixture "$SANDBOX/qstat" 996 H "Hold_Types = s"
write_qstat_fixture "$SANDBOX/qstat" 997 H "Hold_Types = s"
out="$(run_status "$work8" h)"
assert_contains "$out" "Step    : md (4/6) -- held (PBS 995)" "user hold"

# ---------------------------------------------------------------------------
# No-argument scan: two projects, skip a directory without a frozen config.
# ---------------------------------------------------------------------------
reset_status_state
work9="$SANDBOX/work9"
mkdir -p "$work9/projects/empty"
make_project "$work9/projects/a" a
make_project "$work9/projects/b" b
out="$(run_status "$work9")"
assert_contains "$out" "Project : a" "scan project a"
assert_contains "$out" "Project : b" "scan project b"
assert_not_contains "$out" "Project : empty" "scan skips non-project directories"

finish
