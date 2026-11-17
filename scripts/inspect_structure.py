#!/usr/bin/env python3
"""Inspect a protein-ligand structure and validate ASL selections.

Run with the Schrodinger Python interpreter:

    $SCHRODINGER/run python3 scripts/inspect_structure.py \
        --structure complex.pdb \
        --receptor-asl "chain A" \
        --ligand-asl "chain B" \
        --align-asl "chain A and backbone and not (atom.ele H)" \
        --check

The report lists chains, hetero groups, waters, ions, and the number of atoms
selected by each ASL. With --check, the script exits non-zero if any provided
ASL selects zero atoms.
"""

import argparse
import json
import sys
from collections import defaultdict

try:
    from schrodinger import structure
    from schrodinger.structutils import analyze
except ImportError as exc:
    print("FATAL: cannot import Schrodinger API: {}".format(exc), file=sys.stderr)
    print("Run this script with: $SCHRODINGER/run python3 ...", file=sys.stderr)
    sys.exit(1)

AA_RESIDUES = {
    "ALA", "ARG", "ASN", "ASP", "CYS", "CYX", "GLN", "GLU", "GLY",
    "HIS", "HIE", "HID", "HIP", "ILE", "LEU", "LYS", "MET", "PHE",
    "PRO", "SER", "THR", "TRP", "TYR", "VAL",
}
CAP_RESIDUES = {"ACE", "NME", "NMA", "NH2"}
NUCLEIC_RESIDUES = {
    "A", "C", "G", "U", "T", "DA", "DC", "DG", "DT", "DU",
    "RA", "RC", "RG", "RU",
}
POLYMER_RESIDUES = AA_RESIDUES | CAP_RESIDUES | NUCLEIC_RESIDUES

WATER_NAMES = {"HOH", "WAT", "SPC", "TIP", "TIP3", "TIP4", "T3P", "T4P", "H2O"}
ION_NAMES = {
    "NA", "CL", "K", "MG", "CA", "ZN", "MN", "FE", "CU", "CO", "NI",
    "CD", "HG", "BR", "IOD", "F", "LI", "CS", "RB", "SR", "BA",
    "SO4", "PO4", "NO3", "ACT",
}


def residue_name(atom):
    return str(atom.pdbres).strip()


def evaluate_asl(st, asl):
    try:
        return list(analyze.evaluate_asl(st, asl))
    except Exception as exc:
        raise RuntimeError("ASL '{}' failed: {}".format(asl, exc))


def describe_structure(st, receptor_asl, ligand_asl, align_asl):
    chain_info = {}
    het_groups = defaultdict(int)
    water_atoms = defaultdict(int)
    ion_atoms = defaultdict(int)

    for atom in st.atom:
        chain = str(atom.chain).strip() or "<blank>"
        resname = residue_name(atom)
        key = (chain, resname, int(atom.resnum))
        info = chain_info.setdefault(
            chain,
            {"atoms": 0, "residues": set(), "polymer_residues": set(), "resnames": set()},
        )
        info["atoms"] += 1
        info["residues"].add((int(atom.resnum), resname))
        info["resnames"].add(resname)
        if resname in POLYMER_RESIDUES:
            info["polymer_residues"].add((int(atom.resnum), resname))

        if resname in WATER_NAMES:
            water_atoms[resname] += 1
        elif resname in ION_NAMES:
            ion_atoms[resname] += 1
        elif resname not in POLYMER_RESIDUES:
            het_groups[key] += 1

    asl_results = {}
    for label, asl in (
        ("receptor", receptor_asl),
        ("ligand", ligand_asl),
        ("align", align_asl),
    ):
        if not asl:
            continue
        try:
            ids = evaluate_asl(st, asl)
            result = {"asl": asl, "atoms": len(ids)}
            try:
                result["chains"] = sorted({
                    str(st.atom[i].chain).strip() or "<blank>" for i in ids
                })
            except (IndexError, KeyError, TypeError, ValueError) as exc:
                print("WARNING: cannot list chains for ASL {!r}: {}".format(asl, exc),
                      file=sys.stderr)
            asl_results[label] = result
        except RuntimeError as exc:
            asl_results[label] = {"asl": asl, "atoms": None, "error": str(exc)}

    return chain_info, het_groups, water_atoms, ion_atoms, asl_results


def print_report(path, st, chain_info, het_groups, water_atoms, ion_atoms, asl_results):
    print("Structure: {}".format(path))
    print("Title: {}".format(st.title))
    print("Atoms: {}".format(st.atom_total))
    print("")

    print("Chains:")
    print("  {:<8} {:>8} {:>9} {:>10}  {}".format(
        "chain", "atoms", "residues", "polymer", "resnames"))
    for chain in sorted(chain_info):
        info = chain_info[chain]
        resnames = ",".join(sorted(info["resnames"])[:10])
        print("  {:<8} {:>8d} {:>9d} {:>10d}  {}".format(
            chain, info["atoms"], len(info["residues"]),
            len(info["polymer_residues"]), resnames))
    print("")

    print("Non-polymer hetero groups:")
    if het_groups:
        for (chain, resname, resnum), natoms in sorted(het_groups.items()):
            print("  chain={:<6} resname={:<6} resnum={:<6} atoms={}".format(
                chain, resname, resnum, natoms))
    else:
        print("  (none)")
    print("")

    print("Waters:")
    if water_atoms:
        for name, natoms in sorted(water_atoms.items()):
            print("  resname={:<6} atoms={}".format(name, natoms))
    else:
        print("  (none)")
    print("")

    print("Ions:")
    if ion_atoms:
        for name, natoms in sorted(ion_atoms.items()):
            print("  resname={:<6} atoms={}".format(name, natoms))
    else:
        print("  (none)")
    print("")

    print("ASL selections:")
    for label in ("receptor", "ligand", "align"):
        if label not in asl_results:
            continue
        result = asl_results[label]
        if result.get("atoms") is None:
            print("  {:<8} ASL={!r} ERROR: {}".format(
                label, result["asl"], result.get("error", "unknown")))
        else:
            print("  {:<8} atoms={:<6} ASL={!r}".format(
                label, result["atoms"], result["asl"]))
    print("")

    # Suggestions only; never applied automatically.
    if chain_info:
        receptor_chain = max(
            chain_info,
            key=lambda c: (len(chain_info[c]["polymer_residues"]), chain_info[c]["atoms"]),
        )
        print("Suggested receptor: RECEPTOR_ASL=\"chain {}\"".format(receptor_chain))

    lig_chains = defaultdict(int)
    for (chain, _resname, _resnum), natoms in het_groups.items():
        lig_chains[chain] += natoms
    if lig_chains:
        best_chain = max(lig_chains, key=lig_chains.get)
        print("Suggested ligand:   LIGAND_ASL=\"chain {}\" (hetero groups on that chain)".format(best_chain))
    else:
        other_chains = [c for c in chain_info if chain_info[c]["polymer_residues"]]
        # Exclude the largest polymer chain (likely the receptor).
        if len(other_chains) > 1:
            other_chains.sort(key=lambda c: len(chain_info[c]["polymer_residues"]), reverse=True)
            print("Suggested ligand:   LIGAND_ASL=\"chain {}\" (second polymer chain; verify manually)".format(other_chains[1]))
    print("")


def main():
    parser = argparse.ArgumentParser(description="Inspect a structure and validate Desmond/ASL selections.")
    parser.add_argument("--structure", required=True, help="PDB, MAE, MAEGZ, or CMS file")
    parser.add_argument("--receptor-asl", default="", help="Receptor ASL")
    parser.add_argument("--ligand-asl", default="", help="Ligand ASL")
    parser.add_argument("--align-asl", default="", help="Alignment ASL")
    parser.add_argument("--check", action="store_true",
                        help="Exit non-zero if a provided ASL selects zero atoms or fails")
    parser.add_argument("--json-out", default="", help="Write a JSON report to this path")
    args = parser.parse_args()

    reader = structure.StructureReader(args.structure)
    try:
        st = next(reader)
    except StopIteration:
        print("FATAL: no structures found in {}".format(args.structure), file=sys.stderr)
        return 1
    n_cts = 1 + sum(1 for _ in reader)

    chain_info, het_groups, water_atoms, ion_atoms, asl_results = describe_structure(
        st, args.receptor_asl, args.ligand_asl, args.align_asl
    )

    if n_cts != 1:
        print("NOTE: file contains {} CTs; details below are for the first CT only.".format(n_cts))
        print("")

    print_report(args.structure, st, chain_info, het_groups, water_atoms, ion_atoms, asl_results)

    report = {
        "structure": args.structure,
        "title": st.title,
        "atoms": st.atom_total,
        "cts": n_cts,
        "chains": {
            chain: {
                "atoms": info["atoms"],
                "residues": len(info["residues"]),
                "polymer_residues": len(info["polymer_residues"]),
                "resnames": sorted(info["resnames"]),
            }
            for chain, info in chain_info.items()
        },
        "hetero_groups": [
            {"chain": c, "resname": r, "resnum": n, "atoms": a}
            for (c, r, n), a in sorted(het_groups.items())
        ],
        "waters": dict(water_atoms),
        "ions": dict(ion_atoms),
        "asl": asl_results,
    }

    if args.json_out:
        with open(args.json_out, "w") as fh:
            json.dump(report, fh, indent=2, sort_keys=True)
            fh.write("\n")

    if args.check:
        required = [("receptor", args.receptor_asl), ("ligand", args.ligand_asl),
                    ("align", args.align_asl)]
        failed = []
        for label, asl in required:
            if not asl:
                continue
            result = asl_results.get(label, {})
            if result.get("atoms") is None:
                failed.append("{} ASL error: {}".format(label, result.get("error")))
            elif result.get("atoms", 0) == 0:
                failed.append("{} ASL selected 0 atoms: {!r}".format(label, asl))
        if failed:
            for msg in failed:
                print("ERROR: {}".format(msg), file=sys.stderr)
            return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
