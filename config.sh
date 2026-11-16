#!/bin/bash
# =============================================================================
# Global defaults for the Desmond protein-ligand MD pipeline.
#
# Schrodinger is installed at /opt/schrodinger2021-2 on this host.
# Override SCHRODINGER in the shell if your installation is elsewhere:
#   export SCHRODINGER=/opt/schrodinger2021-2
#
# Values here can be overridden by:
#   1. environment variables (because of ${VAR:-default})
#   2. systems/<name>.conf
# SCH_WORK_ROOT defaults to this directory when it is owned/writable by you;
# for a shared read-only install it defaults to $HOME/desmond_md_work.
# PIPELINE_WORK_ROOT is kept as a deprecated alias.
# WORK_ROOT is intentionally NOT read from the environment: it commonly
# collides with unrelated software. Old project.resolved.conf files that set
# WORK_ROOT are migrated by load_project_env() in scripts/lib/common.sh.
# Command-line flags select stages (--from/--force/--dry-run) but do not
# override scientific parameters.
# =============================================================================

# ---------------- Work root (multi-user) ----------------
if [[ -n "${SCH_WORK_ROOT:-}" && -n "${PIPELINE_WORK_ROOT:-}" \
      && "$SCH_WORK_ROOT" != "$PIPELINE_WORK_ROOT" ]]; then
    echo "WARNING: SCH_WORK_ROOT and PIPELINE_WORK_ROOT differ; using SCH_WORK_ROOT" >&2
fi
if [[ -z "${SCH_WORK_ROOT:-}" && -n "${PIPELINE_WORK_ROOT:-}" ]]; then
    SCH_WORK_ROOT="$PIPELINE_WORK_ROOT"
    echo "WARNING: PIPELINE_WORK_ROOT is deprecated; use SCH_WORK_ROOT" >&2
fi
if [[ -n "${WORK_ROOT:-}" && -z "${SCH_WORK_ROOT:-}" ]]; then
    echo "WARNING: WORK_ROOT is ignored for new submissions; use SCH_WORK_ROOT" >&2
fi
if [[ -z "${SCH_WORK_ROOT:-}" ]]; then
    if [[ -n "${PIPELINE_ROOT:-}" && -O "${PIPELINE_ROOT}" && -w "${PIPELINE_ROOT}" ]]; then
        SCH_WORK_ROOT="$PIPELINE_ROOT"
    else
        SCH_WORK_ROOT="${HOME}/desmond_md_work"
    fi
fi
if [[ "$SCH_WORK_ROOT" != /* ]]; then
    SCH_WORK_ROOT="${HOME}/${SCH_WORK_ROOT}"
fi
SCH_WORK_ROOT="${SCH_WORK_ROOT%/}"
export SCH_WORK_ROOT

# Optional shared GPU lock directory (used only by the nvidia-smi fallback).
GPU_LOCK_DIR="${GPU_LOCK_DIR:-${SCH_WORK_ROOT}/.gpu_locks}"
if [[ "$GPU_LOCK_DIR" != /* ]]; then
    GPU_LOCK_DIR="${SCH_WORK_ROOT}/${GPU_LOCK_DIR}"
fi
GPU_LOCK_DIR="${GPU_LOCK_DIR%/}"
export GPU_LOCK_DIR

# ---------------- Machine / scheduler ----------------
SCHRODINGER="${SCHRODINGER:-/opt/schrodinger2021-2}"
SCHRODINGER_LICENSE_FILE="${SCHRODINGER_LICENSE_FILE:-}"
LM_LICENSE_FILE="${LM_LICENSE_FILE:-}"
# Optional custom hosts file. Leave empty to use $SCHRODINGER/schrodinger.hosts.
SCHRODINGER_HOSTS="${SCHRODINGER_HOSTS:-}"

QSUB="${QSUB:-qsub}"
QSTAT="${QSTAT:-qstat}"
QDEL="${QDEL:-qdel}"
PBSNODES="${PBSNODES:-pbsnodes}"

PBS_QUEUE="${PBS_QUEUE:-batch}"

PBS_PPN_PREP="${PBS_PPN_PREP:-4}"
PBS_PPN_ANALYSIS="${PBS_PPN_ANALYSIS:-1}"
PBS_PPN_MMGBSA="${PBS_PPN_MMGBSA:-8}"

PBS_WALLTIME_PREP="${PBS_WALLTIME_PREP:-24:00:00}"
PBS_WALLTIME_MIN="${PBS_WALLTIME_MIN:-06:00:00}"
PBS_WALLTIME_MD="${PBS_WALLTIME_MD:-96:00:00}"
PBS_WALLTIME_ANALYSIS="${PBS_WALLTIME_ANALYSIS:-12:00:00}"
PBS_WALLTIME_MMGBSA="${PBS_WALLTIME_MMGBSA:-48:00:00}"

# GPGPU license tokens requested by one one-GPU job.
# Use :1 for counted license packs; the local uncounted license accepts any value.
GPU_LICENSE="${GPU_LICENSE:-DESMOND_GPGPU:1}"

# 0 = disabled (recommended): make PBS_WALLTIME_MD longer than the expected MD.
# auto = PBS_WALLTIME_MD minus 30 minutes, passed as multisim -max-walltime.
# NOTE: the graceful-stop + multisim -RESTART path is EXPERIMENTAL. On
# Schrodinger 2021-2 it fails for an interrupted production stage with
# "desmond_md_job_<P>-in.cfg is not accessible". Do not rely on it in production.
MD_MAX_WALLTIME_SEC="${MD_MAX_WALLTIME_SEC:-0}"

# ---------------- PrepWizard ----------------
PREPWIZARD_PH="${PREPWIZARD_PH:-7.0}"
# Build disulfides from free cysteines. Set to "no" to disable.
PREPWIZARD_DISULFIDES="${PREPWIZARD_DISULFIDES:-yes}"
PREPWIZARD_FILLSIDECHAINS="${PREPWIZARD_FILLSIDECHAINS:-yes}"
PREPWIZARD_FILLLOOPS="${PREPWIZARD_FILLLOOPS:-yes}"
PREPWIZARD_NOIMPREF="${PREPWIZARD_NOIMPREF:-yes}"
PREPWIZARD_MINIMIZE_ADJ_H="${PREPWIZARD_MINIMIZE_ADJ_H:-yes}"
PREPWIZARD_LABEL_PKAS="${PREPWIZARD_LABEL_PKAS:-yes}"

# ---------------- Desmond system build ----------------
FORCEFIELD="${FORCEFIELD:-S-OPLS}"
SOLVENT="${SOLVENT:-SPC}"
BUFFER_SIZE="${BUFFER_SIZE:-10.0}"
SALT_CONC="${SALT_CONC:-0.15}"

# ---------------- Desmond MD ----------------
MD_TIME_NS="${MD_TIME_NS:-300}"
MD_TEMPERATURE="${MD_TEMPERATURE:-300.0}"
MD_TRAJ_INTERVAL_PS="${MD_TRAJ_INTERVAL_PS:-1000.0}"
MD_CUTOFF="${MD_CUTOFF:-9.0}"
# Empty = generate once at submission and freeze in project.resolved.conf.
MD_SEED="${MD_SEED:-}"

# ---------------- MM-GBSA ----------------
MMGBSA_LAST_NS="${MMGBSA_LAST_NS:-100}"
MMGBSA_STEP_SIZE="${MMGBSA_STEP_SIZE:-2}"
MMGBSA_START_FRAME="${MMGBSA_START_FRAME:-}"
MMGBSA_END_FRAME="${MMGBSA_END_FRAME:-}"

# ---------------- Stage switches ----------------
RUN_ANALYSIS="${RUN_ANALYSIS:-yes}"
RUN_MMGBSA="${RUN_MMGBSA:-yes}"
