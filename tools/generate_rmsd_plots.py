#!/usr/bin/env python3
"""
generate_rmsd_plots.py — Parse Schrödinger .eaf event analysis files,
produce XLSX data tables and publication-quality RMSD PNG plots.

Matches the style conventions of rmsd_desmond.py (navy blue, DejaVu Sans,
600 dpi, desptined grid, hidden top/right spines).

Input:  One or more .eaf files with embedded Result = [...] arrays
Output: Per RMSD entry: one .xlsx file + one .png plot

Usage:
    python generate_rmsd_plots.py <eaf_file> [<eaf_file> ...]
    python generate_rmsd_plots.py --dir <directory>
    python generate_rmsd_plots.py --traj-interval 1.0 <eaf_file>
"""

import argparse
import glob
import os
import re
import sys

# ============================================================
# Optional imports — fail gracefully if not in Schrödinger Python
# ============================================================
try:
    import pandas as pd
except ImportError:
    pd = None

try:
    import matplotlib
    matplotlib.use("Agg")  # non-interactive backend
    import matplotlib.pyplot as plt
    from matplotlib import rcParams
except ImportError:
    plt = None

# ============================================================
# Plot styling (matches rmsd_desmond.py)
# ============================================================
LINE_COLOR = "#1f4aa8"       # Navy blue (SCI-safe)
TIME_RANGE = (0, 300)        # Default x-axis range (ns)
RMSD_RANGE_PROTEIN = (0, 8)  # Default y-axis range for protein (Å)
LINE_WIDTH = 2.5
FIGURE_SIZE = (8, 5)
DPI = 600


def _setup_rcparams():
    """Apply publication-quality matplotlib style."""
    if plt is None:
        return
    rcParams.update({
        "font.family": "sans-serif",
        "font.sans-serif": ["DejaVu Sans"],
        "font.size": 16,
        "axes.linewidth": 1.2,
        "xtick.major.width": 1.2,
        "ytick.major.width": 1.2,
        "xtick.direction": "in",
        "ytick.direction": "in",
    })


# ============================================================
# EAF Parser
# ============================================================

def _extract_quoted_value(line):
    """Extract a quoted or unquoted value after '=' from an EAF line."""
    match = re.search(r'=\s*(?:"([^"]*)"|(\S+))', line)
    if match:
        return match.group(1) if match.group(1) is not None else match.group(2)
    return None


def parse_eaf(filepath):
    """Parse a Schrödinger .eaf file and extract RMSD entries.

    Each entry is a dict with keys:
        selection_type: str  — "Backbone", "Side chains", "C-Alpha", "Ligand", etc.
        asl: str             — atom selection language expression
        fit_by: str or None  — FitBy ASL (optional)
        values: list[float]  — RMSD values per frame (Å)

    The EAF format places SelectionType and FitBy AFTER the Result array,
    so we finalize entries only when a new block starts or at end of file.
    """
    entries = []
    current = None
    in_result = False
    result_parts = []

    def _finalize_entry():
        """Push the current entry (if any) to entries list."""
        if current is not None:
            entries.append(dict(current))

    with open(filepath, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            # Detect block start — finalize previous entry first
            if "{RMSD = {" in line or "{RMSD={" in line:
                _finalize_entry()
                current = {
                    "selection_type": None,
                    "asl": None,
                    "fit_by": None,
                    "values": [],
                }
                in_result = False
                result_parts = []
                continue

            if current is None:
                continue

            # If collecting a multi-line Result array
            if in_result:
                if "]" in line:
                    # End of Result array
                    result_parts.append(line.split("]", 1)[0])
                    text = "".join(result_parts)
                    try:
                        current["values"] = [float(x) for x in text.split()]
                    except ValueError:
                        pass  # malformed result
                    in_result = False
                    result_parts = []
                else:
                    result_parts.append(line)
                continue

            # Detect Result array start (may span multiple lines)
            if "Result = [" in line or "Result=[" in line:
                in_result = True
                if "Result = [" in line:
                    after_bracket = line.split("Result = [", 1)[1]
                else:
                    after_bracket = line.split("Result=[", 1)[1]
                if "]" in after_bracket:
                    # Single-line Result array
                    text = after_bracket.split("]", 1)[0]
                    try:
                        current["values"] = [float(x) for x in text.split()]
                    except ValueError:
                        pass
                    in_result = False
                else:
                    result_parts = [after_bracket]
                continue

            # Collect metadata fields (before OR after Result)
            if "SelectionType" in line:
                val = _extract_quoted_value(line)
                if val:
                    current["selection_type"] = val
            elif "ASL =" in line or "ASL=" in line:
                val = _extract_quoted_value(line)
                if val:
                    current["asl"] = val
            elif "FitBy" in line:
                val = _extract_quoted_value(line)
                if val:
                    current["fit_by"] = val

        # Finalize last entry at EOF
        _finalize_entry()

    return entries


# ============================================================
# Time Axis
# ============================================================

def build_time_axis(n_frames, traj_interval_ps=1.0):
    """Generate time axis in ns from frame count and trajectory interval.

    Args:
        n_frames: number of trajectory frames
        traj_interval_ps: interval between frames in picoseconds

    Returns:
        list of floats (time in ns)
    """
    dt_ns = traj_interval_ps / 1000.0
    return [i * dt_ns for i in range(n_frames)]


# ============================================================
# XLSX Writer
# ============================================================

def _sanitize_filename(name):
    """Replace spaces and special chars for safe filenames."""
    return re.sub(r"[^\w\-.]", "_", name)


def write_xlsx(output_dir, prefix, selection_type, times, values):
    """Write RMSD data to an XLSX file. Returns path or None on failure."""
    if pd is None:
        return None
    os.makedirs(output_dir, exist_ok=True)
    sel_safe = _sanitize_filename(selection_type)
    xlsx_path = os.path.join(output_dir, f"{prefix}_{sel_safe}.xlsx")
    df = pd.DataFrame({"Time (ns)": times, "RMSD": values})
    df.to_excel(xlsx_path, index=False)
    return xlsx_path


# ============================================================
# Plot Generator
# ============================================================

def _auto_rmsd_range(values, selection_type):
    """Determine sensible y-axis range based on selection type."""
    if values is None or len(values) == 0:
        return (0, 8)
    max_val = max(values)
    sel_lower = selection_type.lower() if selection_type else ""
    if "ligand" in sel_lower:
        upper = max(10.0, max_val * 1.15)
        return (0, round(upper))
    else:
        if max_val > 7.5:
            upper = max(10.0, max_val * 1.1)
            return (0, round(upper))
        return (0, 8)


def generate_plot(xlsx_path, output_dir, prefix, selection_type, times, values):
    """Generate a publication-quality RMSD PNG plot.

    Style matches rmsd_desmond.py: navy blue, DejaVu Sans, 600 dpi,
    desptined grid, hidden top/right spines.
    """
    if plt is None or times is None or values is None:
        return None
    if len(times) == 0 or len(values) == 0:
        return None

    _setup_rcparams()
    os.makedirs(output_dir, exist_ok=True)

    sel_safe = _sanitize_filename(selection_type)
    if str(selection_type).strip().lower() == "ligand":
        # The Desmond API LigandRMSD PNG is authoritative; do not overwrite it.
        png_path = os.path.join(output_dir, f"{prefix}_Ligand_EAF_RMSD.png")
    else:
        png_path = os.path.join(output_dir, f"{prefix}_{sel_safe}_RMSD.png")

    rmsd_range = _auto_rmsd_range(values, selection_type)
    time_range = (0, max(times) if times else TIME_RANGE[1])

    fig, ax = plt.subplots(figsize=FIGURE_SIZE)

    ax.plot(times, values, linewidth=LINE_WIDTH, color=LINE_COLOR, alpha=0.95)

    ax.set_xlim(*time_range)
    ax.set_ylim(*rmsd_range)
    ax.set_xlabel("Time (ns)", fontsize=15)
    ax.set_ylabel("RMSD (Å)", fontsize=15)

    ax.grid(True, linestyle="--", linewidth=0.6, alpha=0.4)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    title = f"{selection_type} RMSD"
    ax.set_title(title, fontsize=14, fontweight="normal", pad=10)

    plt.tight_layout()
    plt.savefig(png_path, dpi=DPI, bbox_inches="tight")
    plt.close()
    return png_path


# ============================================================
# Main
# ============================================================

def process_eaf(filepath, output_dir=".", traj_interval_ps=1.0):
    """Process one EAF file: extract entries, write XLSX, generate PNG.

    Skips entries that are ASL template blocks (no numeric Result arrays).
    Returns (xlsx_count, png_count).
    """
    basename = os.path.splitext(os.path.basename(filepath))[0]
    entries = parse_eaf(filepath)

    if not entries:
        print(f"  [SKIP] {filepath}: no RMSD Result arrays found")
        return 0, 0

    xlsx_count = 0
    png_count = 0

    for i, entry in enumerate(entries):
        sel_type = entry["selection_type"] or f"entry_{i}"
        values = entry["values"]

        if not values:
            continue

        n_frames = len(values)
        times = build_time_axis(n_frames, traj_interval_ps)

        # Write XLSX
        xlsx_path = write_xlsx(output_dir, basename, sel_type, times, values)
        if xlsx_path:
            xlsx_count += 1
            print(f"  [XLSX] {xlsx_path}  ({n_frames} frames)")

        # Generate PNG
        png_path = generate_plot(xlsx_path, output_dir, basename, sel_type, times, values)
        if png_path:
            png_count += 1
            print(f"  [PNG]  {png_path}")

    return xlsx_count, png_count


def main():
    parser = argparse.ArgumentParser(
        description="Parse Schrödinger .eaf files and generate RMSD XLSX + PNG plots"
    )
    parser.add_argument("eaf_files", nargs="*", help="EAF files to process")
    parser.add_argument("--dir", "-d", help="Process all .eaf files in a directory")
    parser.add_argument(
        "--traj-interval", type=float, default=1.0,
        help="Trajectory frame interval in ps (default: 1.0)"
    )
    parser.add_argument(
        "--output-dir", "-o", default=".",
        help="Output directory for XLSX and PNG files (default: current directory)"
    )
    args = parser.parse_args()

    if pd is None:
        print("WARNING: pandas not available — XLSX output disabled", file=sys.stderr)
    if plt is None:
        print("WARNING: matplotlib not available — PNG output disabled", file=sys.stderr)

    eaf_files = list(args.eaf_files)
    if args.dir:
        eaf_files.extend(sorted(glob.glob(os.path.join(args.dir, "*.eaf"))))

    if not eaf_files:
        print("No .eaf files specified. Use --dir <dir> or pass files as arguments.")
        return 1

    total_xlsx = 0
    total_png = 0

    for eaf_file in eaf_files:
        if not os.path.isfile(eaf_file):
            print(f"  [SKIP] {eaf_file}: not found")
            continue
        print(f"Processing: {eaf_file}")
        nx, npng = process_eaf(eaf_file, args.output_dir, args.traj_interval)
        total_xlsx += nx
        total_png += npng

    print(f"\nDone: {total_xlsx} XLSX file(s), {total_png} PNG plot(s) generated.")
    return 0 if (total_png > 0 or total_xlsx > 0) else 1


if __name__ == "__main__":
    sys.exit(main())
