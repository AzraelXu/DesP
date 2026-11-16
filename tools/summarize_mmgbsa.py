#!/usr/bin/env python3
"""Summarize a Prime MM-GBSA CSV produced by thermal_mmgbsa.py.

The binding-energy column is located by header name, not by a fixed column
index. The preferred header is r_psp_MMGBSA_dG_Bind; the (NS) variant is
ignored.

Outputs summary.json and summary.md in --output-dir.
"""

import argparse
import csv
import json
import math
import os
import sys

PREFERRED = "r_psp_MMGBSA_dG_Bind"


def choose_column(headers, requested):
    if requested:
        if requested not in headers:
            raise SystemExit("FATAL: requested column not found: {}".format(requested))
        return requested
    if PREFERRED in headers:
        return PREFERRED
    for h in headers:
        if "MMGBSA_dG_Bind" in h and "(NS)" not in h:
            return h
    for h in headers:
        if "MMGBSA" in h and "Bind" in h and "(NS)" not in h:
            return h
    raise SystemExit("FATAL: no MM-GBSA binding-energy column found in {}".format(headers))


def main():
    parser = argparse.ArgumentParser(description="Summarize a thermal_mmgbsa CSV.")
    parser.add_argument("csv_file")
    parser.add_argument("--output-dir", default=".")
    parser.add_argument("--project", default="")
    parser.add_argument("--column", default="")
    args = parser.parse_args()

    if not os.path.isfile(args.csv_file):
        print("FATAL: CSV not found: {}".format(args.csv_file), file=sys.stderr)
        return 1

    with open(args.csv_file, newline="") as fh:
        reader = csv.DictReader(fh)
        headers = reader.fieldnames or []
        column = choose_column(headers, args.column)
        values = []
        for row in reader:
            raw = (row.get(column) or "").strip()
            if not raw or raw.lower() in ("nan", "n/a", "na", "none"):
                continue
            try:
                value = float(raw)
            except ValueError:
                continue
            if math.isnan(value) or math.isinf(value):
                continue
            values.append(value)

    if not values:
        print("FATAL: no numeric values in column {}".format(column), file=sys.stderr)
        return 1

    n = len(values)
    mean = sum(values) / n
    if n > 1:
        variance = sum((v - mean) ** 2 for v in values) / (n - 1)
        std = math.sqrt(variance)
        sem = std / math.sqrt(n)
    else:
        std = 0.0
        sem = 0.0

    summary = {
        "project": args.project,
        "csv": os.path.abspath(args.csv_file),
        "column": column,
        "n": n,
        "mean": mean,
        "std": std,
        "sem": sem,
        "min": min(values),
        "max": max(values),
    }

    os.makedirs(args.output_dir, exist_ok=True)
    json_path = os.path.join(args.output_dir, "summary.json")
    with open(json_path, "w") as fh:
        json.dump(summary, fh, indent=2, sort_keys=True)
        fh.write("\n")

    md_path = os.path.join(args.output_dir, "summary.md")
    with open(md_path, "w") as fh:
        fh.write("# MM-GBSA summary: {}\n\n".format(args.project or os.path.basename(args.csv_file)))
        fh.write("| Property | Value |\n")
        fh.write("|----------|-------|\n")
        fh.write("| Column | `{}` |\n".format(column))
        fh.write("| Frames | {} |\n".format(n))
        fh.write("| Mean dG_bind | **{:.2f} kcal/mol** |\n".format(mean))
        fh.write("| Std dev | {:.2f} kcal/mol |\n".format(std))
        fh.write("| SEM | {:.2f} kcal/mol |\n".format(sem))
        fh.write("| Min | {:.2f} kcal/mol |\n".format(min(values)))
        fh.write("| Max | {:.2f} kcal/mol |\n".format(max(values)))
        fh.write("| Source | `{}` |\n".format(os.path.abspath(args.csv_file)))

    print("MM-GBSA: {} frames, mean {:.2f} +/- {:.2f} kcal/mol".format(n, mean, sem))
    print("  [JSON] {}".format(json_path))
    print("  [MD]   {}".format(md_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
