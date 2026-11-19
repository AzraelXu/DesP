#!/bin/bash
# Status state helpers: project discovery, frozen/jobs parsing, qstat, stage state.
# Sourced by scripts/status.sh; expects the globals declared there.

canon_project_dir() {
    readlink -f "$1" 2>/dev/null || printf '%s' "$1"
}

add_project() {
    local d="$1"
    [[ -n "$d" && -d "$d" ]] || return 0
    [[ -f "$d/project.resolved.conf" ]] || return 0
    d="$(canon_project_dir "$d")"
    [[ -n "${PROJECT_SEEN[$d]:-}" ]] && return 0
    PROJECT_SEEN[$d]=1
    PROJECTS+=("$d")
}

frozen_system_name() {
    bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${SYSTEM_NAME:-}"' _ "$1" 2>/dev/null || true
}

collect_projects() {
    local arg="${1:-}"
    PROJECTS=()
    PROJECT_SEEN=()
    if [[ -n "$arg" ]]; then
        if [[ -d "$arg" ]]; then
            add_project "$arg"
        elif [[ -f "$arg" && "$(basename "$arg")" == "project.resolved.conf" ]]; then
            add_project "$(dirname "$arg")"
        else
            local p="${SCH_WORK_ROOT}/projects/${arg}"
            if [[ -d "$p" ]]; then
                add_project "$p"
            else
                local d name
                shopt -s nullglob
                for d in "${SCH_WORK_ROOT}/projects"/*; do
                    [[ -d "$d" && -f "$d/project.resolved.conf" ]] || continue
                    name="$(frozen_system_name "$d/project.resolved.conf")"
                    [[ "$name" == "$arg" ]] && add_project "$d"
                done
                shopt -u nullglob
            fi
        fi
    else
        local d
        shopt -s nullglob
        for d in "${SCH_WORK_ROOT}/projects"/*; do
            add_project "$d"
        done
        shopt -u nullglob
    fi
}

load_frozen() {
    local pdir="$1"
    local frozen="$pdir/project.resolved.conf"
    F_SYSTEM_NAME=""
    F_MD_TIME_NS=""
    F_MD_TIME_PS=""
    F_RUN_ANALYSIS=""
    F_RUN_MMGBSA=""
    F_FORCE_STAGES=""
    F_PBS_WALLTIME_PREP=""
    F_PBS_WALLTIME_MIN=""
    F_PBS_WALLTIME_MD=""
    F_PBS_WALLTIME_ANALYSIS=""
    F_PBS_WALLTIME_MMGBSA=""
    if [[ -f "$frozen" ]]; then
        eval "$(bash -c '
            set +u
            source "$1" >/dev/null 2>&1 || exit 1
            for v in SYSTEM_NAME MD_TIME_NS MD_TIME_PS RUN_ANALYSIS RUN_MMGBSA \
                     FORCE_STAGES PBS_WALLTIME_PREP PBS_WALLTIME_MIN PBS_WALLTIME_MD \
                     PBS_WALLTIME_ANALYSIS PBS_WALLTIME_MMGBSA; do
                printf "F_%s=%q\n" "$v" "${!v}"
            done
        ' _ "$frozen" 2>/dev/null)"
    fi
    if [[ -z "$F_MD_TIME_PS" ]]; then
        F_MD_TIME_PS="$(awk -v t="${F_MD_TIME_NS:-0}" 'BEGIN { printf "%.1f", t * 1000 }')"
    fi
    [[ -n "$F_RUN_ANALYSIS" ]] || F_RUN_ANALYSIS=yes
    [[ -n "$F_RUN_MMGBSA" ]] || F_RUN_MMGBSA=yes
    [[ -n "$F_SYSTEM_NAME" ]] || F_SYSTEM_NAME="$(basename "$pdir")"
}

load_jobs() {
    local pdir="$1"
    local f="$pdir/state/jobs.env"
    local key val
    J_HAS_JOBS="no"
    J_RUN_ID=""
    J_SUBMITTED_AT=""
    J_PREP=""
    J_MIN=""
    J_MD=""
    J_ANALYSIS=""
    J_MMGBSA=""
    if [[ -f "$f" ]]; then
        J_HAS_JOBS="yes"
        while IFS='=' read -r key val; do
            case "$key" in
                RUN_ID) J_RUN_ID="$val" ;;
                SUBMITTED_AT) J_SUBMITTED_AT="$val" ;;
                PREP_JOB) J_PREP="$val" ;;
                MIN_JOB) J_MIN="$val" ;;
                MD_JOB) J_MD="$val" ;;
                ANALYSIS_JOB) J_ANALYSIS="$val" ;;
                MMGBSA_JOB) J_MMGBSA="$val" ;;
            esac
        done < "$f"
    fi
    if [[ -z "$J_RUN_ID" || -z "$J_SUBMITTED_AT" ]]; then
        f="$pdir/state/run.env"
        if [[ -f "$f" ]]; then
            while IFS='=' read -r key val; do
                case "$key" in
                    RUN_ID) [[ -n "$J_RUN_ID" ]] || J_RUN_ID="$val" ;;
                    SUBMITTED_AT) [[ -n "$J_SUBMITTED_AT" ]] || J_SUBMITTED_AT="$val" ;;
                esac
            done < "$f"
        fi
    fi
}

stage_job_id() {
    case "$1" in
        prepwizard|setup) printf '%s' "$J_PREP" ;;
        min) printf '%s' "$J_MIN" ;;
        md) printf '%s' "$J_MD" ;;
        analysis) printf '%s' "$J_ANALYSIS" ;;
        mmgbsa) printf '%s' "$J_MMGBSA" ;;
    esac
}

stage_upstreams() {
    case "$1" in
        prepwizard) ;;
        setup) printf 'prepwizard' ;;
        min) printf 'prepwizard setup' ;;
        md) printf 'prepwizard setup min' ;;
        analysis|mmgbsa) printf 'prepwizard setup min md' ;;
    esac
}

stage_disabled() {
    case "$1" in
        analysis) [[ "${F_RUN_ANALYSIS:-yes}" == "no" ]] ;;
        mmgbsa) [[ "${F_RUN_MMGBSA:-yes}" == "no" ]] ;;
        *) return 1 ;;
    esac
}

qstat_parse_field() {
    local out="$1"
    local field="$2"
    printf '%s\n' "$out" | sed -n "s/^[[:space:]]*${field}[[:space:]]*=[[:space:]]*//p" | head -1
}

qstat_query() {
    local id="$1"
    CUR_STATE=""
    CUR_USED=""
    CUR_LIMIT=""
    CUR_START=""
    CUR_EXIT=""
    CUR_COMMENT=""
    CUR_HOLD=""
    CUR_EST=""
    CUR_ERR=""
    [[ -n "$id" ]] || { CUR_STATE="none"; return 0; }
    if [[ -n "${Q_QUERIED[$id]:-}" ]]; then
        CUR_STATE="${Q_CACHE_STATE[$id]:-}"
        CUR_USED="${Q_CACHE_USED[$id]:-}"
        CUR_LIMIT="${Q_CACHE_LIMIT[$id]:-}"
        CUR_START="${Q_CACHE_START[$id]:-}"
        CUR_EXIT="${Q_CACHE_EXIT[$id]:-}"
        CUR_COMMENT="${Q_CACHE_COMMENT[$id]:-}"
        CUR_HOLD="${Q_CACHE_HOLD[$id]:-}"
        CUR_EST="${Q_CACHE_EST[$id]:-}"
        CUR_ERR="${Q_CACHE_ERR[$id]:-}"
        return 0
    fi
    Q_QUERIED[$id]=1
    if ! command -v "$QSTAT" >/dev/null 2>&1; then
        CUR_STATE="noqstat"
        Q_CACHE_STATE[$id]="$CUR_STATE"
        return 0
    fi

    local out rc=0
    local -a cmd=("$QSTAT" -f -1 "$id")
    if command -v timeout >/dev/null 2>&1; then
        cmd=(timeout 10 "${cmd[@]}")
    fi
    out="$(LC_ALL=C "${cmd[@]}" 2>&1)" || rc=$?

    if printf '%s\n' "$out" | grep -q 'Unknown Job Id'; then
        CUR_STATE="unknown"
    elif (( rc != 0 )); then
        CUR_STATE="pbs-error"
        CUR_ERR="$(printf '%s\n' "$out" | head -1)"
        if [[ "$PBS_ERROR_PRINTED" == "no" ]]; then
            printf 'Note: qstat failed (%s); showing file-based status only.\n' "$CUR_ERR" >&2
            PBS_ERROR_PRINTED="yes"
        fi
    else
        CUR_STATE="$(qstat_parse_field "$out" "job_state")"
        [[ -n "$CUR_STATE" ]] || CUR_STATE="unknown"
        CUR_USED="$(qstat_parse_field "$out" "resources_used.walltime")"
        CUR_LIMIT="$(qstat_parse_field "$out" "Resource_List.walltime")"
        CUR_START="$(qstat_parse_field "$out" "start_time")"
        CUR_EXIT="$(qstat_parse_field "$out" "exit_status")"
        CUR_COMMENT="$(qstat_parse_field "$out" "comment")"
        CUR_HOLD="$(qstat_parse_field "$out" "Hold_Types")"
        CUR_EST="$(qstat_parse_field "$out" "estimated.start_time")"
    fi

    Q_CACHE_STATE[$id]="$CUR_STATE"
    Q_CACHE_USED[$id]="$CUR_USED"
    Q_CACHE_LIMIT[$id]="$CUR_LIMIT"
    Q_CACHE_START[$id]="$CUR_START"
    Q_CACHE_EXIT[$id]="$CUR_EXIT"
    Q_CACHE_COMMENT[$id]="$CUR_COMMENT"
    Q_CACHE_HOLD[$id]="$CUR_HOLD"
    Q_CACHE_EST[$id]="$CUR_EST"
    Q_CACHE_ERR[$id]="$CUR_ERR"
    return 0
}

latest_stage_log() {
    local pdir="$1"
    local prefix="$2"
    local job="$3"
    local jobbase="${job%%.*}"
    local -a files=()
    shopt -s nullglob
    if [[ -n "$jobbase" ]]; then
        files=("$pdir/logs/${prefix}_${jobbase}_"*.log)
    else
        files=("$pdir/logs/${prefix}_"*.log)
    fi
    shopt -u nullglob
    (( ${#files[@]} > 0 )) || return 1
    local newest=""
    local newest_m=0
    local f m
    for f in "${files[@]}"; do
        m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
        if (( m > newest_m )); then
            newest_m="$m"
            newest="$f"
        fi
    done
    [[ -n "$newest" ]] || return 1
    printf '%s' "$newest"
}

log_has_start() {
    [[ -f "$1" ]] && grep -q '===== stage .* start =====' "$1"
}

log_has_end() {
    [[ -f "$1" ]] && grep -q '===== stage .* end =====' "$1"
}

parse_time_epoch() {
    local t="$1"
    [[ -n "$t" ]] || return 1
    date -d "$t" +%s 2>/dev/null
}

log_name_epoch() {
    local base="${1##*/}"
    if [[ "$base" =~ _([0-9]{14})\.log$ ]]; then
        local ts="${BASH_REMATCH[1]}"
        date -d "${ts:0:8} ${ts:8:2}:${ts:10:2}:${ts:12:2}" +%s 2>/dev/null
        return $?
    fi
    return 1
}

stage_start_epoch() {
    local stage="$1"
    local slog="$2"
    local e=""
    # setup starts after prepwizard inside the same PREP job; use its own log.
    if [[ "$stage" == "setup" && -n "$slog" ]]; then
        e="$(log_name_epoch "$slog" || true)"
        [[ -n "$e" ]] && { printf '%s' "$e"; return 0; }
    fi
    e="$(parse_time_epoch "${STAGE_QSTART[$stage]:-}" || true)"
    [[ -n "$e" ]] && { printf '%s' "$e"; return 0; }
    if [[ -n "$slog" ]]; then
        e="$(log_name_epoch "$slog" || true)"
        [[ -n "$e" ]] && { printf '%s' "$e"; return 0; }
        e="$(stat -c %Y "$slog" 2>/dev/null || true)"
        [[ -n "$e" ]] && { printf '%s' "$e"; return 0; }
    fi
    return 1
}

walltime_left() {
    local stage="$1"
    local limit=0
    local used=0
    if [[ -n "${STAGE_QLIMIT[$stage]:-}" ]]; then
        limit="$(walltime_to_sec "${STAGE_QLIMIT[$stage]}")"
    fi
    if (( limit == 0 )); then
        local wt=""
        case "${STAGE_WALLVAR[$stage]:-}" in
            PBS_WALLTIME_PREP) wt="${F_PBS_WALLTIME_PREP:-}" ;;
            PBS_WALLTIME_MIN) wt="${F_PBS_WALLTIME_MIN:-}" ;;
            PBS_WALLTIME_MD) wt="${F_PBS_WALLTIME_MD:-}" ;;
            PBS_WALLTIME_ANALYSIS) wt="${F_PBS_WALLTIME_ANALYSIS:-}" ;;
            PBS_WALLTIME_MMGBSA) wt="${F_PBS_WALLTIME_MMGBSA:-}" ;;
        esac
        [[ -n "$wt" ]] && limit="$(walltime_to_sec "$wt")"
    fi
    if [[ -n "${STAGE_QUSED[$stage]:-}" ]]; then
        used="$(walltime_to_sec "${STAGE_QUSED[$stage]}")"
    fi
    if (( limit > 0 )); then
        local left=$((limit - used))
        (( left < 0 )) && left=0
        printf '%s' "$left"
    fi
}

stage_elapsed() {
    local stage="$1"
    local seconds=""
    if [[ "$stage" != "setup" && -n "${STAGE_QUSED[$stage]:-}" ]]; then
        seconds="$(walltime_to_sec "${STAGE_QUSED[$stage]}")"
    fi
    if [[ -z "$seconds" || "$seconds" -eq 0 ]]; then
        local start=""
        start="$(stage_start_epoch "$stage" "${STAGE_SLOG[$stage]:-}" || true)"
        if [[ -n "$start" ]]; then
            seconds=$((STATUS_NOW - start))
            (( seconds < 0 )) && seconds=0
        fi
    fi
    [[ -n "$seconds" ]] && fmt_duration "$seconds"
}

queue_wait() {
    local pdir="$1"
    [[ -n "$J_SUBMITTED_AT" ]] || return 1
    local e=""
    e="$(parse_time_epoch "$J_SUBMITTED_AT" || true)"
    [[ -n "$e" ]] || return 1
    local s=$((STATUS_NOW - e))
    (( s < 0 )) && s=0
    fmt_duration "$s"
}

project_total_duration() {
    local pdir="$1"
    local f t e earliest="" latest=""
    if [[ -n "$J_SUBMITTED_AT" ]]; then
        earliest="$(parse_time_epoch "$J_SUBMITTED_AT" || true)"
    fi
    if [[ -z "$earliest" ]]; then
        for f in "$pdir"/state/*.done; do
            [[ -f "$f" ]] || continue
            t="$(sed -n 's/^START=//p' "$f" | head -1)"
            [[ -n "$t" ]] || continue
            e="$(parse_time_epoch "$t" || true)"
            [[ -n "$e" ]] || continue
            if [[ -z "$earliest" ]] || (( e < earliest )); then
                earliest="$e"
            fi
        done
    fi
    for f in "$pdir"/state/*.done; do
        [[ -f "$f" ]] || continue
        t="$(sed -n 's/^END=//p' "$f" | head -1)"
        [[ -n "$t" ]] || continue
        e="$(parse_time_epoch "$t" || true)"
        [[ -n "$e" ]] || continue
        if [[ -z "$latest" ]] || (( e > latest )); then
            latest="$e"
        fi
    done
    if [[ -n "$earliest" && -n "$latest" ]] && (( latest > earliest )); then
        fmt_duration $((latest - earliest))
    fi
}

# Find the newest Desmond engine log for a running MD job. multisim runs the
# engine in a scratch directory (usually $HOME/tmp/$USER) and copies the log
# into the project only when the stage finishes; check both places.
find_md_engine_log() {
    local pdir="$1"
    local name="$2"
    local start_epoch="${3:-0}"
    local -a candidates=()
    local base="$pdir/desmond_md_job_${name}/desmond_md_job_${name}.log"
    [[ -f "$base" ]] && candidates+=("$base")
    local user="${USER:-}"
    local root
    for root in "${SCHRODINGER_TMPDIR:-}" "${TMPDIR:-}" \
                "${HOME:-}/tmp/${user}" "${HOME:-}/tmp"; do
        [[ -n "$root" && -d "$root" ]] || continue
        local d=""
        while IFS= read -r -d '' d; do
            [[ -f "$d/desmond_md_job_${name}.log" ]] \
                && candidates+=("$d/desmond_md_job_${name}.log")
        done < <(find "$root" -maxdepth 1 -type d \
            \( -name "desmond_md_job_${name}" -o -name "desmond_md_job_${name}.*" \) \
            -print0 2>/dev/null)
    done
    (( ${#candidates[@]} > 0 )) || return 1
    local best="" best_mtime=-1 best_chem="-1"
    local f m c
    for f in "${candidates[@]}"; do
        m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
        c="$(md_log_value "$f" chemical_ps 2>/dev/null || echo 0)"
        [[ -n "$c" ]] || c=0
        if (( m > best_mtime )) || { (( m == best_mtime )) && \
                awk -v a="$c" -v b="$best_chem" \
                    'BEGIN { exit !(a + 0 > b + 0) }'; }; then
            best="$f"
            best_mtime="$m"
            best_chem="$c"
        fi
    done
    [[ -n "$best" ]] || return 1
    if (( start_epoch > 0 && best_mtime + 60 < start_epoch )); then
        return 1
    fi
    printf '%s' "$best"
}

md_progress() {
    local pdir="$1"
    local name="$2"
    local start_epoch="$3"
    MD_CHEM=""
    MD_RATE=""
    MD_RATE_SRC=""
    MD_PCT=""
    MD_ETA=""
    MD_LOG=""
    local log
    log="$(find_md_engine_log "$pdir" "$name" "$start_epoch" || true)"
    [[ -n "$log" ]] || return 1
    MD_LOG="$log"
    MD_CHEM="$(md_log_value "$log" chemical_ps || true)"
    [[ -n "$MD_CHEM" ]] || return 1
    MD_RATE="$(md_log_rate_avg "$log" 10 || true)"
    if [[ -n "$MD_RATE" ]]; then
        MD_RATE_SRC="avg10"
    else
        MD_RATE="$(md_log_value "$log" ns_per_day || true)"
        [[ -n "$MD_RATE" ]] && MD_RATE_SRC="last"
    fi
    if [[ -z "$MD_RATE" && "$start_epoch" =~ ^[0-9]+$ ]] && (( start_epoch > 0 )); then
        local elapsed=$((STATUS_NOW - start_epoch))
        if (( elapsed > 60 )); then
            MD_RATE="$(awk -v c="$MD_CHEM" -v e="$elapsed" 'BEGIN { if (e > 0) printf "%.1f", (c / 1000) * 86400 / e }')"
            MD_RATE_SRC="observed"
        fi
    fi
    if [[ -n "$F_MD_TIME_PS" ]] && awk -v b="$F_MD_TIME_PS" 'BEGIN { exit !(b + 0 > 0) }'; then
        MD_PCT="$(awk -v c="$MD_CHEM" -v t="$F_MD_TIME_PS" 'BEGIN {
            p = 100 * c / t
            if (p > 100) p = 100
            if (p < 0) p = 0
            printf "%.1f", p
        }')"
    fi
    if [[ -n "$F_MD_TIME_PS" && -n "$MD_RATE" ]] \
        && awk -v r="$MD_RATE" 'BEGIN { exit !(r + 0 > 0) }'; then
        MD_ETA="$(awk -v c="$MD_CHEM" -v t="$F_MD_TIME_PS" -v r="$MD_RATE" 'BEGIN {
            rem = t - c
            if (rem < 0) rem = 0
            printf "%.0f", rem * 86400 / (r * 1000)
        }')"
    fi
    return 0
}

analysis_phase() {
    local pdir="$1"
    local job="$2"
    local log=""
    log="$(latest_stage_log "$pdir" "50_analysis" "$job" || true)"
    [[ -n "$log" ]] || return 1
    local line=""
    line="$(grep -E 'aligning trajectory|generating EAF|computing RMSD|computing ligand RMSD|generating XLSX/PNG' "$log" | tail -1 || true)"
    [[ -n "$line" ]] || return 1
    printf '%s' "$line"
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

compute_states() {
    local pdir="$1"
    local stage st
    STAGE_STATE=()
    STAGE_INDEX=()
    STAGE_QSTATE=()
    STAGE_QSTART=()
    STAGE_QUSED=()
    STAGE_QLIMIT=()
    STAGE_QEXIT=()
    STAGE_QCOMMENT=()
    STAGE_QHOLD=()
    STAGE_QEST=()
    STAGE_SLOG=()
    STAGE_TOTAL=0

    local idx=0
    for stage in "${STATUS_STAGES[@]}"; do
        if stage_disabled "$stage"; then
            STAGE_STATE[$stage]=skipped
            continue
        fi
        idx=$((idx + 1))
        STAGE_INDEX[$stage]=$idx
        STAGE_TOTAL=$idx
    done

    for stage in "${STATUS_STAGES[@]}"; do
        [[ "${STAGE_STATE[$stage]:-}" == "skipped" ]] && continue

        local id marker m_run m_job
        id="$(stage_job_id "$stage")"
        marker="$pdir/state/${stage}.done"
        m_run=""
        m_job=""
        if [[ -f "$marker" ]]; then
            m_run="$(sed -n 's/^RUN_ID=//p' "$marker" | head -1)"
            m_job="$(sed -n 's/^JOBID=//p' "$marker" | head -1)"
        fi

        # A marker from the current run is authoritative; no qstat needed.
        if [[ -f "$marker" && -n "$m_run" && "$m_run" == "$J_RUN_ID" ]]; then
            STAGE_STATE[$stage]=done
            continue
        fi
        # Backward compatibility for .done files written before RUN_ID existed.
        if [[ -f "$marker" && -n "$id" && -n "$m_job" \
              && "${m_job%%.*}" == "${id%%.*}" ]]; then
            STAGE_STATE[$stage]=done
            continue
        fi

        local forced=no
        case ",${F_FORCE_STAGES:-}," in
            *",$stage,"*|*",all,"*) forced=yes ;;
        esac

        local qstate="" q_used="" q_limit="" q_start="" q_exit=""
        local q_comment="" q_hold="" q_est=""
        if [[ -n "$id" ]]; then
            qstat_query "$id"
            qstate="$CUR_STATE"
            q_used="$CUR_USED"
            q_limit="$CUR_LIMIT"
            q_start="$CUR_START"
            q_exit="$CUR_EXIT"
            q_comment="$CUR_COMMENT"
            q_hold="$CUR_HOLD"
            q_est="$CUR_EST"
        fi

        local slog=""
        slog="$(latest_stage_log "$pdir" "${STAGE_PREFIX[$stage]}" "$id" || true)"
        local has_start=no
        local has_end=no
        if [[ -n "$slog" ]]; then
            log_has_start "$slog" && has_start=yes
            log_has_end "$slog" && has_end=yes
        fi

        # PREP job runs prepwizard then setup. If prepwizard finished but its
        # marker is missing, infer completion only from a fresh output and a
        # setup log from this PREP job.
        if [[ "$stage" == "prepwizard" && "$qstate" == "R" ]]; then
            local pw="$pdir/prepwizard/prepwizard-out.maegz"
            local setup_log=""
            setup_log="$(latest_stage_log "$pdir" "20_setup" "$id" || true)"
            if [[ -f "$pw" && -n "$setup_log" ]]; then
                local pw_m=""
                local job_start=""
                pw_m="$(stat -c %Y "$pw" 2>/dev/null || echo 0)"
                job_start="$(parse_time_epoch "$q_start" || true)"
                if [[ -n "$job_start" ]] && (( pw_m >= job_start )); then
                    STAGE_STATE[$stage]=done
                    continue
                fi
            fi
        fi

        STAGE_QSTATE[$stage]="$qstate"
        STAGE_QSTART[$stage]="$q_start"
        STAGE_QUSED[$stage]="$q_used"
        STAGE_QLIMIT[$stage]="$q_limit"
        STAGE_QEXIT[$stage]="$q_exit"
        STAGE_QCOMMENT[$stage]="$q_comment"
        STAGE_QHOLD[$stage]="$q_hold"
        STAGE_QEST[$stage]="$q_est"
        STAGE_SLOG[$stage]="$slog"

        case "$qstate" in
            Q) STAGE_STATE[$stage]=queued; continue ;;
            R|E) STAGE_STATE[$stage]=running; continue ;;
            S) STAGE_STATE[$stage]=suspended; continue ;;
            H)
                if [[ "$q_hold" == *u* ]]; then
                    STAGE_STATE[$stage]=held
                else
                    STAGE_STATE[$stage]=waiting
                fi
                continue
                ;;
        esac

        if [[ "$has_end" == "yes" ]]; then
            if [[ -f "$marker" ]]; then
                STAGE_STATE[$stage]=done
            else
                STAGE_STATE[$stage]=failed
            fi
            continue
        fi

        if [[ "$has_start" == "yes" ]]; then
            STAGE_STATE[$stage]=failed
            continue
        fi

        if [[ -f "$marker" ]]; then
            # A forced stage that ended without a current-run completion log
            # must not be reported as done just because an old marker exists.
            if [[ "$forced" == "yes" && -n "$J_RUN_ID" && -n "$m_run" \
                  && "$m_run" != "$J_RUN_ID" ]]; then
                STAGE_STATE[$stage]=ended
                continue
            fi
            case "$qstate" in
                C)
                    if [[ "$q_exit" == "42" ]]; then
                        STAGE_STATE[$stage]=failed
                    elif [[ -n "$q_exit" && "$q_exit" != "0" ]]; then
                        STAGE_STATE[$stage]=failed
                    else
                        STAGE_STATE[$stage]=done
                    fi
                    ;;
                unknown)
                    local pbsout="$pdir/logs/pbs/${STAGE_PBS[$stage]}.${J_RUN_ID}.out"
                    if [[ -n "$J_RUN_ID" && -f "$pbsout" ]]; then
                        STAGE_STATE[$stage]=ended
                    else
                        STAGE_STATE[$stage]=done
                    fi
                    ;;
                pbs-error|noqstat|none)
                    STAGE_STATE[$stage]=done
                    ;;
                *)
                    STAGE_STATE[$stage]=done
                    ;;
            esac
            continue
        fi

        case "$qstate" in
            C) STAGE_STATE[$stage]=failed ;;
            unknown) STAGE_STATE[$stage]=ended ;;
            pbs-error|noqstat) STAGE_STATE[$stage]=unknown ;;
            none) STAGE_STATE[$stage]=pending ;;
            *) STAGE_STATE[$stage]=unknown ;;
        esac
    done

    # A failed/held upstream blocks only its own downstream stages.
    # analysis and mmgbsa are siblings and do not block each other.
    for stage in "${STATUS_STAGES[@]}"; do
        [[ "${STAGE_STATE[$stage]:-}" == "skipped" ]] && continue
        local up
        for up in $(stage_upstreams "$stage"); do
            case "${STAGE_STATE[$up]:-}" in
                failed|held|blocked)
                    STAGE_STATE[$stage]=blocked
                    break
                    ;;
            esac
        done
    done

    local -a failed=()
    local -a active=()
    local -a pending=()
    local any_done=no
    for stage in "${STATUS_STAGES[@]}"; do
        st="${STAGE_STATE[$stage]:-}"
        case "$st" in
            skipped) ;;
            done) any_done=yes ;;
            failed) failed+=("$stage") ;;
            running|queued|waiting|held|suspended) active+=("$stage") ;;
            blocked|pending|unknown|ended) pending+=("$stage") ;;
        esac
    done

    local all_done=yes
    for stage in "${STATUS_STAGES[@]}"; do
        st="${STAGE_STATE[$stage]:-}"
        [[ "$st" == "skipped" || "$st" == "done" ]] || all_done=no
    done

    if [[ "$all_done" == "yes" ]]; then
        PROJECT_RESULT="complete"
        CURRENT_STAGES=()
    elif (( ${#failed[@]} > 0 )); then
        PROJECT_RESULT="failed"
        CURRENT_STAGES=("${failed[@]}")
    elif (( ${#active[@]} > 0 )); then
        PROJECT_RESULT="active"
        CURRENT_STAGES=("${active[@]}")
    elif (( ${#pending[@]} > 0 )); then
        PROJECT_RESULT="pending"
        CURRENT_STAGES=("${pending[0]}")
    else
        PROJECT_RESULT="notsubmitted"
        CURRENT_STAGES=("${STATUS_STAGES[0]}")
    fi

    if [[ "$J_HAS_JOBS" == "no" && "$any_done" == "no" ]]; then
        PROJECT_RESULT="notsubmitted"
        CURRENT_STAGES=("${STATUS_STAGES[0]}")
    fi
}

# Load one project's frozen config, jobs state, and computed stage states.
# Callers use this to decide whether a complete project was already reported
# before printing its block.
evaluate_project() {
    local pdir="$1"
    load_frozen "$pdir"
    load_jobs "$pdir"
    compute_states "$pdir"
}

