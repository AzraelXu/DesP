#!/bin/bash
# GPU selection for one-GPU PBS jobs.
# Requires common.sh to be sourced first.

# Parse one GPU index from a Torque PBS_GPUFILE line.
# Accepted examples:
#   node03-gpu/0
#   node03-gpu/0,1
#   node03:0
#   0
_parse_gpu_line() {
    local token="$1"
    if [[ "$token" =~ gpu/?([0-9]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$token" =~ (^|[^0-9])([0-9]+)[^0-9]*$ ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

_parse_pbs_gpufile() {
    local f="$1"
    local line id
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if id="$(_parse_gpu_line "$line")"; then
            printf '%s' "$id"
            return 0
        fi
    done < "$f"
    return 1
}

_first_gpu_id() {
    printf '%s' "$1" | cut -d, -f1 | tr -d ' '
}

select_gpu() {
    require_command nvidia-smi

    GPU_ID=""
    GPU_SOURCE=""
    GPU_LOCK_FD=""

    local cvd="${CUDA_VISIBLE_DEVICES:-}"
    local scvd="${SCHRODINGER_CUDA_VISIBLE_DEVICES:-}"

    if [[ -n "$cvd" && -n "$scvd" && "$cvd" != "$scvd" ]]; then
        die "CUDA_VISIBLE_DEVICES='$cvd' conflicts with SCHRODINGER_CUDA_VISIBLE_DEVICES='$scvd'"
    fi

    if [[ -n "$scvd" ]]; then
        GPU_ID="$(_first_gpu_id "$scvd")"
        GPU_SOURCE="SCHRODINGER_CVD"
    elif [[ -n "$cvd" ]]; then
        GPU_ID="$(_first_gpu_id "$cvd")"
        GPU_SOURCE="CVD"
    elif [[ -n "${PBS_GPUFILE:-}" && -r "${PBS_GPUFILE}" ]]; then
        local raw
        raw="$(tr '\n' ';' < "$PBS_GPUFILE")"
        GPU_ID="$(_parse_pbs_gpufile "$PBS_GPUFILE")" \
            || die "PBS_GPUFILE exists but no GPU index could be parsed: ${raw}"
        GPU_SOURCE="PBS_GPUFILE"
        log INFO "PBS_GPUFILE raw: ${raw}"
    else
        require_command flock
        local candidates
        candidates="$(nvidia-smi --query-gpu=index,memory.used,utilization.gpu \
            --format=csv,noheader,nounits 2>/dev/null \
            | awk -F', *' 'NF >= 3 && $1 ~ /^[0-9]+$/ {printf "%s %s %s\n", $2, $3, $1}' \
            | sort -n -k1,1 -k2,2 \
            | awk '{print $3}')"
        [[ -n "$candidates" ]] || die "could not enumerate GPUs with nvidia-smi"

        local lockdir="${GPU_LOCK_DIR:-${SCH_WORK_ROOT:-$PIPELINE_ROOT}/.gpu_locks}"
        mkdir -p "$lockdir"
        local host
        host="$(hostname -s)"
        local id fd
        for id in $candidates; do
            exec {fd}>"${lockdir}/${host}_gpu${id}.lock"
            if flock -n "$fd"; then
                GPU_ID="$id"
                GPU_LOCK_FD="$fd"
                GPU_SOURCE="least-used+lock"
                break
            fi
            exec {fd}>&-
        done
        [[ -n "$GPU_ID" ]] || die "all GPUs on $(hostname -s) are locked by other pipeline jobs"
    fi

    nvidia-smi -i "$GPU_ID" --query-gpu=index,name,memory.total \
        --format=csv,noheader >/dev/null 2>&1 \
        || die "GPU ${GPU_ID} does not exist on $(hostname -s)"

    export CUDA_VISIBLE_DEVICES="$GPU_ID"
    export SCHRODINGER_CUDA_VISIBLE_DEVICES="$GPU_ID"

    local gpu_line gpu_count
    gpu_line="$(nvidia-smi -i "$GPU_ID" \
        --query-gpu=index,name,memory.total,driver_version \
        --format=csv,noheader 2>/dev/null | head -1)"
    gpu_count="$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)"

    log INFO "GPU selected: id=${GPU_ID} source=${GPU_SOURCE} device=[${gpu_line}] host=$(hostname -s) gpu_count=${gpu_count}"
}
