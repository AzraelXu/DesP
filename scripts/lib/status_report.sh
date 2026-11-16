#!/bin/bash
# Status output helpers: durations, diagnostics, and per-project report.
# Sourced by scripts/status.sh; expects the globals declared there.

fmt_duration() {
    local s="${1:-0}"
    [[ "$s" =~ ^[0-9]+$ ]] || s=0
    (( s < 0 )) && s=0
    local d=$((s / 86400))
    local h=$(((s % 86400) / 3600))
    local m=$(((s % 3600) / 60))
    local sec=$((s % 60))
    if (( d > 0 )); then
        printf '%dd %02dh' "$d" "$h"
    elif (( h > 0 )); then
        printf '%dh %02dm' "$h" "$m"
    else
        printf '%dm %02ds' "$m" "$sec"
    fi
}

blocking_upstream() {
    local stage="$1"
    local up
    for up in $(stage_upstreams "$stage"); do
        case "${STAGE_STATE[$up]:-}" in
            failed|held|blocked)
                printf '%s' "$up"
                return 0
                ;;
        esac
    done
    printf 'upstream'
}

stage_state_description() {
    local stage="$1"
    local state="$2"
    local id="$3"
    local qexit="${STAGE_QEXIT[$stage]:-}"
    local pbs=""
    [[ -n "$id" ]] && pbs=" (PBS ${id})"
    case "$state" in
        running) printf 'running%s' "$pbs" ;;
        queued) printf 'queued%s' "$pbs" ;;
        waiting) printf 'waiting for dependency%s' "$pbs" ;;
        held) printf 'held%s' "$pbs" ;;
        suspended) printf 'suspended%s' "$pbs" ;;
        failed)
            if [[ "$qexit" == "42" ]]; then
                printf 'FAILED%s, exit_status=42 (checkpoint retained; use --restart-md)' "$pbs"
            elif [[ -n "$qexit" ]]; then
                printf 'FAILED%s, exit_status=%s' "$pbs" "$qexit"
            else
                printf 'FAILED%s' "$pbs"
            fi
            ;;
        ended) printf 'ended without completion%s' "$pbs" ;;
        blocked) printf 'blocked by %s' "$(blocking_upstream "$stage")" ;;
        pending) printf 'pending' ;;
        unknown) printf 'unknown (PBS unavailable or job purged)' ;;
        notsubmitted) printf 'not submitted' ;;
        *) printf '%s' "$state" ;;
    esac
}


collect_level() {
    local log="$1"
    local level="$2"
    local cutoff="$3"
    local line lvl ts ep
    while IFS= read -r line; do
        [[ "$line" =~ ^\[([A-Z]+)\]\ ([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}) ]] || continue
        lvl="${BASH_REMATCH[1]}"
        ts="${BASH_REMATCH[2]}"
        [[ "$lvl" == "$level" ]] || continue
        if [[ -n "$cutoff" ]]; then
            ep="$(date -d "$ts" +%s 2>/dev/null || true)"
            [[ -n "$ep" && "$ep" -lt "$cutoff" ]] && continue
        fi
        printf '%s\n' "$line"
    done < "$log"
}

run_cutoff_epoch() {
    local pdir="$1"
    local e="" f t best="" m mbest=""
    if [[ -n "$J_SUBMITTED_AT" ]]; then
        e="$(parse_time_epoch "$J_SUBMITTED_AT" || true)"
        if [[ -n "$e" ]]; then
            printf '%s' $((e - 120))
            return 0
        fi
    fi
    for f in "$pdir"/state/*.done; do
        [[ -f "$f" ]] || continue
        t="$(sed -n 's/^START=//p' "$f" | head -1)"
        [[ -n "$t" ]] || continue
        e="$(parse_time_epoch "$t" || true)"
        [[ -n "$e" ]] || continue
        if [[ -z "$best" ]] || (( e < best )); then
            best="$e"
        fi
    done
    if [[ -n "$best" ]]; then
        printf '%s' $((best - 120))
        return 0
    fi
    for f in "$pdir"/logs/pbs/*.out; do
        [[ -f "$f" ]] || continue
        m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
        if [[ -z "$mbest" ]] || (( m < mbest )); then
            mbest="$m"
        fi
    done
    if [[ -n "$mbest" ]]; then
        printf '%s' "$mbest"
        return 0
    fi
    return 1
}

print_last_lines() {
    local pattern="$1"
    shift
    local n=$#
    (( n == 0 )) && return 0
    local start=$((n - 3))
    (( start < 0 )) && start=0
    local -a arr=("$@")
    local i
    for ((i = start; i < n; i++)); do
        printf '  %s\n' "${arr[$i]}"
    done
    return 0
}

print_messages() {
    local label="$1"
    local pattern="$2"
    shift 2
    local n=$#
    if (( n == 0 )); then
        printf '%-8s: none\n' "$label"
        return 0
    fi
    printf '%-8s: %d in this run\n' "$label" "$n"
    print_last_lines "$pattern" "$@"
    if (( n > 3 )); then
        printf "  ... and %d more (grep '^\\[%s\\]' logs/pipeline.log)\n" "$((n - 3))" "$pattern"
    fi
}

print_diagnostics() {
    local pdir="$1"
    local log="$pdir/logs/pipeline.log"
    if [[ ! -f "$log" ]]; then
        echo "Warnings: none (no log yet)"
        echo "Errors  : none (no log yet)"
        return 0
    fi
    local cutoff=""
    cutoff="$(run_cutoff_epoch "$pdir" || true)"
    local -a warns=()
    local -a fatals=()
    local -a errors=()
    mapfile -t warns < <(collect_level "$log" WARN "$cutoff")
    mapfile -t fatals < <(collect_level "$log" FATAL "$cutoff")
    mapfile -t errors < <(collect_level "$log" ERROR "$cutoff")
    if [[ -z "$cutoff" ]]; then
        echo "Warnings: showing latest messages (no run timestamp)"
    fi
    print_messages "Warnings" "WARN" "${warns[@]}"
    local nerr=$(( ${#fatals[@]} + ${#errors[@]} ))
    if (( nerr == 0 )); then
        echo "Errors  : none"
    else
        echo "Errors  : ${nerr} in this run"
        print_last_lines "FATAL" "${fatals[@]}"
        print_last_lines "ERROR" "${errors[@]}"
        local shown=0
        if (( ${#fatals[@]} > 3 )); then shown=$((shown + 3)); else shown=$((shown + ${#fatals[@]})); fi
        if (( ${#errors[@]} > 3 )); then shown=$((shown + 3)); else shown=$((shown + ${#errors[@]})); fi
        if (( nerr > shown )); then
            printf "  ... and %d more (grep -E '^\\\\[(FATAL|ERROR)\\\\]' logs/pipeline.log)\n" "$((nerr - shown))"
        fi
    fi
}

print_failure_context() {
    local pdir="$1"
    local stage="$2"
    local id=""
    local pbsout=""
    local slog=""
    echo
    echo "Last output for ${stage}:"
    if [[ -n "$J_RUN_ID" ]]; then
        pbsout="$pdir/logs/pbs/${STAGE_PBS[$stage]}.${J_RUN_ID}.out"
        if [[ -f "$pbsout" ]]; then
            echo "  ${pbsout#$pdir/}:"
            tail -n 15 "$pbsout" | sed 's/^/    /'
        else
            echo "  (PBS stdout not found: ${pbsout#$pdir/})"
        fi
    else
        echo "  (run id unknown; see logs/pbs/)"
    fi
    id="$(stage_job_id "$stage")"
    slog="$(latest_stage_log "$pdir" "${STAGE_PREFIX[$stage]}" "$id" || true)"
    if [[ -n "$slog" && -f "$slog" ]]; then
        echo "  ${slog#$pdir/} (tail):"
        tail -n 15 "$slog" | sed 's/^/    /'
    fi
    if [[ -n "${STAGE_QCOMMENT[$stage]:-}" ]]; then
        echo "  PBS comment: ${STAGE_QCOMMENT[$stage]}"
    fi
}

print_project() {
    local pdir="$1"
    load_frozen "$pdir"
    load_jobs "$pdir"
    compute_states "$pdir"

    local name="${F_SYSTEM_NAME:-$(basename "$pdir")}"
    echo "Project : ${name}"
    echo "Dir     : ${pdir}"
    if [[ -n "$J_RUN_ID" ]]; then
        if [[ "$J_HAS_JOBS" == "yes" && -n "$J_SUBMITTED_AT" ]]; then
            echo "Run     : ${J_RUN_ID} (submitted ${J_SUBMITTED_AT})"
        elif [[ "$J_HAS_JOBS" == "yes" ]]; then
            echo "Run     : ${J_RUN_ID}"
        else
            echo "Run     : ${J_RUN_ID} (not submitted)"
        fi
    else
        echo "Run     : not submitted"
    fi

    local stage st current
    if [[ "$PROJECT_RESULT" == "complete" ]]; then
        local total_dur=""
        total_dur="$(project_total_duration "$pdir" || true)"
        if [[ -n "$total_dur" ]]; then
            echo "Step    : complete (${STAGE_TOTAL}/${STAGE_TOTAL}), total ${total_dur}"
        else
            echo "Step    : complete (${STAGE_TOTAL}/${STAGE_TOTAL})"
        fi
        local mean=""
        mean="$(grep 'Mean dG_bind' "$pdir/results/mmgbsa_summary.md" 2>/dev/null | head -1 || true)"
        [[ -n "$mean" ]] && echo "Results : results/mmgbsa_summary.md: ${mean}"
    else
        for current in "${CURRENT_STAGES[@]}"; do
            st="${STAGE_STATE[$current]:-}"
            if [[ "$PROJECT_RESULT" == "notsubmitted" ]]; then
                st="notsubmitted"
            fi
            local idx="${STAGE_INDEX[$current]:-?}"
            local id=""
            id="$(stage_job_id "$current")"
            local desc=""
            desc="$(stage_state_description "$current" "$st" "$id")"
            if [[ "$st" == "running" || "$st" == "suspended" ]]; then
                local elapsed=""
                elapsed="$(stage_elapsed "$current" || true)"
                [[ -n "$elapsed" ]] && desc="${desc}, elapsed ${elapsed}"
            elif [[ "$st" == "queued" || "$st" == "waiting" || "$st" == "held" ]]; then
                local waited=""
                waited="$(queue_wait "$pdir" || true)"
                [[ -n "$waited" ]] && desc="${desc}, waiting ${waited}"
            fi
            echo "Step    : ${current} (${idx}/${STAGE_TOTAL}) -- ${desc}"
        done
    fi

    if [[ "$PROJECT_RESULT" != "complete" ]]; then
        local -a blocked_list=()
        for stage in "${STATUS_STAGES[@]}"; do
            [[ "${STAGE_STATE[$stage]:-}" == "blocked" ]] && blocked_list+=("$stage")
        done
        if (( ${#blocked_list[@]} > 0 )); then
            echo "Blocked : ${blocked_list[*]}"
        fi
    fi

    # ETA/progress. Prefer a running stage; otherwise show why no ETA.
    local eta_printed=no
    for current in "${CURRENT_STAGES[@]}"; do
        st="${STAGE_STATE[$current]:-}"
        [[ "$st" == "running" ]] || continue
        local id=""
        id="$(stage_job_id "$current")"
        local left=""
        left="$(walltime_left "$current" || true)"
        local left_txt=""
        [[ -n "$left" ]] && left_txt="; PBS walltime left $(fmt_duration "$left")"
        if [[ "$current" == "md" ]]; then
            local start=""
            start="$(stage_start_epoch "md" "${STAGE_SLOG[md]:-}" || true)"
            if md_progress "$pdir" "$name" "${start:-0}"; then
                echo "Progress: ${MD_CHEM} / ${F_MD_TIME_PS} ps (${MD_PCT}%), avg rate ${MD_RATE} ns/day (${MD_RATE_SRC})"
                if [[ -n "$MD_ETA" ]]; then
                    echo "ETA     : ~$(fmt_duration "$MD_ETA")${left_txt}"
                    if [[ -n "$left" ]] && (( MD_ETA > left )); then
                        echo "WARNING : ETA exceeds PBS walltime left by $(fmt_duration $((MD_ETA - left))); job will be stopped at the limit (checkpoint kept)."
                    fi
                else
                    echo "ETA     : unknown (engine log has no ns/day rate)${left_txt}"
                fi
            else
                echo "ETA     : unknown (engine log not in project dir yet)${left_txt}"
            fi
        else
            echo "ETA     : unknown for this stage (no progress metric)${left_txt}"
            if [[ "$current" == "analysis" ]]; then
                local phase=""
                phase="$(analysis_phase "$pdir" "$id" || true)"
                [[ -n "$phase" ]] && echo "Phase   : ${phase}"
            fi
        fi
        eta_printed=yes
        break
    done
    if [[ "$eta_printed" == "no" ]]; then
        for current in "${CURRENT_STAGES[@]}"; do
            st="${STAGE_STATE[$current]:-}"
            case "$st" in
                queued|waiting|held|suspended)
                    local left=""
                    left="$(walltime_left "$current" || true)"
                    local left_txt=""
                    [[ -n "$left" ]] && left_txt=" (PBS walltime left $(fmt_duration "$left"))"
                    local est="${STAGE_QEST[$current]:-}"
                    if [[ "$st" == "queued" && -n "$est" && "$est" != "null" ]]; then
                        echo "ETA     : unknown while queued (estimated start ${est})${left_txt}"
                    else
                        echo "ETA     : unknown while ${st}${left_txt}"
                    fi
                    break
                    ;;
            esac
        done
    fi

    print_diagnostics "$pdir"

    local bad=""
    for stage in "${STATUS_STAGES[@]}"; do
        case "${STAGE_STATE[$stage]:-}" in
            failed|ended)
                bad="$stage"
                break
                ;;
        esac
    done
    [[ -n "$bad" ]] && print_failure_context "$pdir" "$bad"
    return 0
}

