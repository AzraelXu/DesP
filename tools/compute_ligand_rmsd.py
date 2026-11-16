#!/usr/bin/env python3
"""
compute_ligand_rmsd.py — Compute ligand RMSD directly from a Desmond MD
trajectory using the Desmond Python API, bypassing analyze_simulation.py's
auto-detection bug where the (protein) ASL keyword absorbs peptide ligands.

Uses LigandRMSD for conformational-symmetry-aware RMSD.  Aligns each frame
to the specified fit selection (typically protein backbone), then computes
ligand heavy-atom RMSD against the first frame.

Output: CSV data table + publication-quality PNG plot (matching the style
of generate_rmsd_plots.py).

Usage:
    $SCHRODINGER/run python3 compute_ligand_rmsd.py \\
        --cms <cms_file> \\
        --ligand-asl "chain B" \\
        --fit-asl "chain A and backbone and not (atom.ele H)" \\
        --output-dir analysis/ \\
        --prefix 1_04 \\
        --traj-interval 1000.0
"""

import argparse
import csv
import os
import sys

# ============================================================
# Schrödinger Desmond API (only available inside $SCHRODINGER/run)
# ============================================================
try:
    from schrodinger.application.desmond.packages import analysis
    from schrodinger.application.desmond.packages import topo
    from schrodinger.application.desmond.packages import traj_util
except ImportError as exc:
    print(f"FATAL: Cannot import Desmond API: {exc}", file=sys.stderr)
    print("This script must be run via: $SCHRODINGER/run python3 ...", file=sys.stderr)
    sys.exit(1)

# ============================================================
# Optional imports — fail gracefully
# ============================================================
try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import rcParams
except ImportError:
    plt = None

# ============================================================
# Plot styling (matches generate_rmsd_plots.py)
# ============================================================
LINE_COLOR = "#1f4aa8"
LINE_WIDTH = 2.5
FIGURE_SIZE = (8, 5)
DPI = 600


def _setup_rcparams():
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
# Main logic
# ============================================================

def main():
    parser = argparse.ArgumentParser(
        description="Compute ligand RMSD from Desmond trajectory (Desmond Python API)"
    )
    parser.add_argument("--cms", required=True, help="Path to the Desmond .cms file")
    parser.add_argument(
        "--ligand-asl", required=True,
        help="ASL expression for ligand atoms (e.g. 'chain B')"
    )
    parser.add_argument(
        "--fit-asl", required=True,
        help="ASL expression for alignment reference (e.g. 'chain A and backbone and not (atom.ele H)')"
    )
    parser.add_argument(
        "--output-dir", default=".",
        help="Output directory for CSV and PNG (default: current dir)"
    )
    parser.add_argument(
        "--prefix", default="rmsd",
        help="Output filename prefix (default: rmsd)"
    )
    parser.add_argument(
        "--traj-interval", type=float, default=1000.0,
        help="Trajectory frame interval in ps (default: 1000.0)"
    )
    args = parser.parse_args()

    # --- Validate inputs ---
    if not os.path.isfile(args.cms):
        print(f"FATAL: CMS file not found: {args.cms}", file=sys.stderr)
        return 1

    # --- Load CMS and trajectory ---
    print(f"Loading CMS + trajectory from: {args.cms}")
    try:
        msys_model, cms_model, trj = traj_util.read_cms_and_traj(args.cms)
    except Exception as exc:
        print(f"FATAL: Failed to read CMS/trajectory: {exc}", file=sys.stderr)
        return 1

    if trj is None or len(trj) < 2:
        n = len(trj) if trj else 0
        print(f"FATAL: Need at least 2 trajectory frames, got {n}", file=sys.stderr)
        return 1

    n_frames = len(trj)
    print(f"  Trajectory loaded: {n_frames} frames")

    # --- Select atoms ---
    print(f"  Ligand ASL: {args.ligand_asl}")
    print(f"  Fit ASL:    {args.fit_asl}")

    try:
        lig_aids = cms_model.select_atom(args.ligand_asl)
        fit_aids = cms_model.select_atom(args.fit_asl)
    except Exception as exc:
        print(f"FATAL: ASL selection failed: {exc}", file=sys.stderr)
        return 1

    if len(lig_aids) == 0:
        print(f"FATAL: Ligand ASL '{args.ligand_asl}' selected 0 atoms",
              file=sys.stderr)
        return 1
    if len(fit_aids) == 0:
        print(f"FATAL: Fit ASL '{args.fit_asl}' selected 0 atoms",
              file=sys.stderr)
        return 1

    print(f"  Ligand atoms: {len(lig_aids)}")
    print(f"  Fit atoms:    {len(fit_aids)}")

    # --- Convert AIDs to GIDs for frame.position() ---
    try:
        lig_gids = topo.aids2gids(cms_model, lig_aids, include_pseudoatoms=False)
        fit_gids = topo.aids2gids(cms_model, fit_aids, include_pseudoatoms=False)
    except Exception as exc:
        print(f"FATAL: aids2gids failed: {exc}", file=sys.stderr)
        return 1

    # --- Extract reference positions from frame 0 ---
    try:
        ref_pos = trj[0].pos(lig_gids)
        fit_ref_pos = trj[0].pos(fit_gids)
    except Exception as exc:
        print(f"FATAL: Failed to extract reference positions: {exc}", file=sys.stderr)
        return 1

    # --- Glue topology (prevents PBC unwrapping artifacts) ---
    try:
        topo.make_glued_topology(msys_model, cms_model)
        print("  Glued topology applied")
    except Exception:
        print("  WARNING: make_glued_topology failed, continuing without it")

    # --- Create LigandRMSD analyzer ---
    print("  Creating LigandRMSD analyzer (with conformational symmetry)...")
    try:
        lrmsd = analysis.LigandRMSD(
            msys_model, cms_model,
            lig_aids, ref_pos,
            fit_aids=fit_aids, fit_ref_pos=fit_ref_pos,
        )
    except Exception as exc:
        print(f"FATAL: Failed to create LigandRMSD: {exc}", file=sys.stderr)
        print("  Falling back to plain RMSD (no symmetry)...")
        try:
            lrmsd = analysis.RMSD(
                msys_model, cms_model,
                lig_aids, ref_pos,
                fit_aids=fit_aids, fit_ref_pos=fit_ref_pos,
            )
        except Exception as exc2:
            print(f"FATAL: Failed to create RMSD fallback: {exc2}", file=sys.stderr)
            return 1

    # --- Run analysis over all frames ---
    print(f"  Computing RMSD over {n_frames} frames...")
    try:
        rmsd_values = analysis.analyze(trj, lrmsd)
    except Exception as exc:
        print(f"FATAL: Analysis failed: {exc}", file=sys.stderr)
        return 1

    if rmsd_values is None or len(rmsd_values) == 0:
        print("FATAL: Analysis returned no results", file=sys.stderr)
        return 1

    print(f"  Computed {len(rmsd_values)} RMSD values")

    # --- Build time axis ---
    dt_ns = args.traj_interval / 1000.0
    times = [i * dt_ns for i in range(len(rmsd_values))]

    # --- Write CSV ---
    os.makedirs(args.output_dir, exist_ok=True)
    csv_path = os.path.join(args.output_dir, f"{args.prefix}-out_Ligand_RMSD.csv")
    try:
        with open(csv_path, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["Time (ns)", "RMSD (A)"])
            for t, v in zip(times, rmsd_values):
                writer.writerow([f"{t:.3f}", f"{v:.4f}"])
        print(f"  [CSV] {csv_path}")
    except Exception as exc:
        print(f"  WARNING: Failed to write CSV: {exc}")

    # --- Generate PNG ---
    _generate_plot(args.output_dir, args.prefix, times, rmsd_values)

    return 0


def _generate_plot(output_dir, prefix, times, values):
    """Generate publication-quality PNG plot."""
    if plt is None:
        print("  WARNING: matplotlib not available — skipping PNG")
        return

    if len(times) == 0 or len(values) == 0:
        return

    _setup_rcparams()
    os.makedirs(output_dir, exist_ok=True)

    png_path = os.path.join(output_dir, f"{prefix}-out_Ligand_RMSD.png")

    # Auto-scale y-axis
    max_val = max(values) if values else 10.0
    if max_val > 7.5:
        upper = max(10.0, max_val * 1.1)
    else:
        upper = max(10.0, max_val * 1.15)
    rmsd_range = (0, round(upper))
    time_range = (0, max(times)) if times else (0, 300)

    fig, ax = plt.subplots(figsize=FIGURE_SIZE)

    ax.plot(times, values, linewidth=LINE_WIDTH, color=LINE_COLOR, alpha=0.95)

    ax.set_xlim(*time_range)
    ax.set_ylim(*rmsd_range)
    ax.set_xlabel("Time (ns)", fontsize=15)
    ax.set_ylabel("RMSD (Å)", fontsize=15)

    ax.grid(True, linestyle="--", linewidth=0.6, alpha=0.4)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    ax.set_title("Ligand RMSD", fontsize=14, fontweight="normal", pad=10)

    plt.tight_layout()
    plt.savefig(png_path, dpi=DPI, bbox_inches="tight")
    plt.close()
    print(f"  [PNG]  {png_path}")


if __name__ == "__main__":
    sys.exit(main())
