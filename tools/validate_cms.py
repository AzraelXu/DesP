#!/usr/bin/env python3
"""
validate_cms.py — Pre-flight integrity check for Desmond .cms files.

Catches the failure mode where the MD output finalization appends a duplicated
copy of the file's own tail onto desmond_md_job_<proj>-out.cms.  The result no
longer parses, trj_align.py dies with an opaque
"predicted '{', have '"SPC "'" error, and the whole pipeline aborts.

IMPORTANT: StructureReader.read() returns only the FIRST CT and therefore
succeeds even on a corrupt multi-CT file.  The corruption is only visible when
iterating every CT — which is what this script does.

Usage:
    $SCHRODINGER/run python3 validate_cms.py --cms <file.cms>
    $SCHRODINGER/run python3 validate_cms.py --cms <out.cms> --reference <in.cms>

Exit status: 0 = valid, 1 = invalid or unreadable.
"""

import argparse
import sys

# ============================================================
# Schrödinger API (only available inside $SCHRODINGER/run)
# ============================================================
try:
    from schrodinger import structure
except ImportError as exc:
    print(f"FATAL: Cannot import Schrodinger API: {exc}", file=sys.stderr)
    print("This script must be run via: $SCHRODINGER/run python3 ...", file=sys.stderr)
    sys.exit(1)

REPAIR_HINT = (
    "Suspected duplicated trailing chunk: the file may have a byte-identical "
    "copy of its own tail appended. Truncate at the seam to repair "
    "(see the project memory note 'cms-duplicated-tail-corruption')."
)


def count_cts(path):
    """Return the per-CT atom counts, iterating EVERY CT.

    Iterating (rather than StructureReader.read) is essential: read() stops
    after the first CT and would miss corruption further into the file.
    """
    atoms = []
    for st in structure.StructureReader(path):
        atoms.append(st.atom_total)
    return atoms


def main():
    parser = argparse.ArgumentParser(
        description="Validate a Desmond .cms file by parsing every CT."
    )
    parser.add_argument("--cms", required=True,
                        help="Path to the .cms file to validate")
    parser.add_argument("--reference", default=None,
                        help="Optional reference .cms (typically the -in.cms) "
                             "to compare topology against")
    args = parser.parse_args()

    try:
        atoms = count_cts(args.cms)
    except Exception as exc:
        print(f"FATAL: {args.cms} does not parse "
              f"({type(exc).__name__}): {exc}", file=sys.stderr)
        print(f"       {REPAIR_HINT}", file=sys.stderr)
        return 1

    if not atoms:
        print(f"FATAL: {args.cms} contains no CTs", file=sys.stderr)
        return 1

    # Optional topology cross-check against the input system.  This also
    # catches the variant where the duplicated chunk happens to start on a CT
    # boundary: the file still parses, but gains a bogus extra CT.
    if args.reference:
        try:
            ref_atoms = count_cts(args.reference)
        except Exception as exc:
            print(f"WARNING: reference {args.reference} does not parse "
                  f"({exc}); skipping topology comparison", file=sys.stderr)
            ref_atoms = None
        if ref_atoms is not None and ref_atoms != atoms:
            print(f"FATAL: topology mismatch vs {args.reference}", file=sys.stderr)
            print(f"       {args.cms}: {len(atoms)} CTs {atoms}", file=sys.stderr)
            print(f"       {args.reference}: {len(ref_atoms)} CTs {ref_atoms}",
                  file=sys.stderr)
            print(f"       {REPAIR_HINT}", file=sys.stderr)
            return 1

    print(f"OK   {args.cms}: {len(atoms)} CTs, {sum(atoms)} atoms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
