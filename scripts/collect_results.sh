#!/bin/bash
# Collect per-project RMSD plots and MM-GBSA summaries into a top-level
# results/ directory with Markdown indexes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PIPELINE_ROOT
source "${PIPELINE_ROOT}/scripts/lib/common.sh"
source "${PIPELINE_ROOT}/config.sh"
setup_schrodinger_env

mkdir -p "${SCH_WORK_ROOT}/results"

"${SCHRODINGER}/run" python3 - "${SCH_WORK_ROOT}" <<'PY'
import glob
import json
import os
import sys

root = sys.argv[1]
results_dir = os.path.join(root, "results")
projects = sorted(glob.glob(os.path.join(root, "projects", "*")))

rows = []
ligand_plots = []

for pdir in projects:
    if not os.path.isdir(pdir):
        continue
    name = os.path.basename(pdir)
    summary = os.path.join(pdir, "results", "mmgbsa_summary.json")
    if os.path.isfile(summary):
        try:
            with open(summary) as fh:
                data = json.load(fh)
            rows.append({
                "name": name,
                "mean": data.get("mean"),
                "sem": data.get("sem"),
                "n": data.get("n"),
                "csv": data.get("csv"),
            })
        except Exception as exc:
            print("WARN: cannot read {}: {}".format(summary, exc), file=sys.stderr)

    for png in sorted(glob.glob(os.path.join(pdir, "results", "*Ligand_RMSD*.png"))):
        ligand_plots.append((name, png))

def source_ref(csv_path, results_dir, root):
    """Return a portable link target; use basename for paths outside the pipeline."""
    if not csv_path:
        return ""
    abs_csv = os.path.abspath(csv_path)
    root_abs = os.path.abspath(root)
    try:
        inside = os.path.commonpath([root_abs, abs_csv]) == root_abs
    except ValueError:
        inside = False
    if inside:
        return os.path.relpath(abs_csv, results_dir)
    return os.path.basename(csv_path)


rows.sort(key=lambda r: (r["mean"] if r["mean"] is not None else float("inf")))

mm_path = os.path.join(results_dir, "mmgbsa_summary.md")
with open(mm_path, "w") as fh:
    fh.write("# MM-GBSA summary\n\n")
    if rows:
        fh.write("| Rank | System | Mean dG (kcal/mol) | SEM | Frames | Source |\n")
        fh.write("|------|--------|--------------------|-----|--------|--------|\n")
        for i, r in enumerate(rows, 1):
            mean = "{:.2f}".format(r["mean"]) if r["mean"] is not None else "?"
            sem = "{:.2f}".format(r["sem"]) if r["sem"] is not None else "?"
            rel = source_ref(r["csv"], results_dir, root)
            fh.write("| {} | {} | **{}** | {} | {} | `{}` |\n".format(
                i, r["name"], mean, sem, r["n"] if r["n"] is not None else "?", rel))
    else:
        fh.write("No MM-GBSA summaries found.\n")

lig_path = os.path.join(results_dir, "ligand_rmsd_index.md")
with open(lig_path, "w") as fh:
    fh.write("# Ligand RMSD plots\n\n")
    if ligand_plots:
        fh.write("| System | Plot |\n")
        fh.write("|--------|------|\n")
        for name, png in ligand_plots:
            rel = os.path.relpath(png, results_dir)
            fh.write("| {} | [{}]({}) |\n".format(name, os.path.basename(png), rel))
    else:
        fh.write("No ligand RMSD plots found.\n")

print("Wrote {}".format(mm_path))
print("Wrote {}".format(lig_path))
print("MM-GBSA systems: {}  ligand plots: {}".format(len(rows), len(ligand_plots)))
PY

echo
echo "Indexes:"
echo "  ${SCH_WORK_ROOT}/results/mmgbsa_summary.md"
echo "  ${SCH_WORK_ROOT}/results/ligand_rmsd_index.md"
