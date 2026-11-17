#!/usr/bin/env python3
"""Write a synthetic inspect_structure.py JSON report for the shell tests.

Usage:
    make_structure_report.py OUT.json "spec"

The spec is a semicolon-separated list of key=value pairs:

    ligand=B              primary ligand chain (default B)
    resname=UNK           residue name for the default group (default UNK)
    atoms=10              atom count for the default group (default 10)
    receptor=A            comma-separated polymer chains (default A)
    groups=B:UNK:10,...   explicit hetero groups (chain:resname:atoms)
    hetero=none           no hetero groups (peptide-ligand case)
    asl_chains=B          chains reported for the ligand ASL
    asl_atoms=10          atoms reported for the ligand ASL
    cts=1                 number of CTs in the file

This helper is test-only; it never touches real structures.
"""

import json
import sys


def parse_spec(text):
    options = {}
    for part in text.split(";"):
        part = part.strip()
        if not part:
            continue
        key, sep, value = part.partition("=")
        if not sep:
            raise SystemExit("invalid spec entry: {!r}".format(part))
        options[key.strip()] = value.strip()
    return options


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: make_structure_report.py OUT.json spec")
    output, spec = sys.argv[1], sys.argv[2]
    options = parse_spec(spec)

    polymer = [c for c in options.get("receptor", "A").split(",") if c]
    ligand = options.get("ligand", "B")
    resname = options.get("resname", "UNK")
    atoms = int(options.get("atoms", "10"))

    groups = []
    if options.get("hetero", "") != "none":
        explicit = options.get("groups", "")
        if explicit:
            for item in explicit.split(","):
                chain, group_resname, group_atoms = item.split(":")
                groups.append({
                    "chain": chain,
                    "resname": group_resname,
                    "resnum": 0,
                    "atoms": int(group_atoms),
                })
        else:
            groups.append({
                "chain": ligand,
                "resname": resname,
                "resnum": 0,
                "atoms": atoms,
            })

    chains = {}
    for chain in polymer:
        chains[chain] = {
            "atoms": 100,
            "residues": 10,
            "polymer_residues": 10,
            "resnames": ["ALA"],
        }
    for group in groups:
        chain = group["chain"]
        if chain not in chains:
            chains[chain] = {
                "atoms": 0,
                "residues": 0,
                "polymer_residues": 0,
                "resnames": [],
            }
            if chain not in polymer:
                chains[chain]["atoms"] += group["atoms"]
                chains[chain]["residues"] += 1
        if group["resname"] not in chains[chain]["resnames"]:
            chains[chain]["resnames"].append(group["resname"])
    if ligand not in chains and options.get("hetero", "") == "none":
        chains[ligand] = {
            "atoms": 0,
            "residues": 0,
            "polymer_residues": 0,
            "resnames": [],
        }

    ligand_groups = [g for g in groups if g["chain"] == ligand]
    if "asl_atoms" in options:
        asl_atoms = int(options["asl_atoms"])
    else:
        asl_atoms = sum(g["atoms"] for g in ligand_groups)
    asl_chains = options.get("asl_chains", ligand)
    if asl_chains:
        asl_chain_list = [c for c in asl_chains.split(",") if c]
    else:
        asl_chain_list = []
    if not asl_chain_list:
        asl_atoms = 0

    report = {
        "structure": output,
        "title": "synthetic",
        "atoms": sum(c["atoms"] for c in chains.values()),
        "cts": int(options.get("cts", "1")),
        "chains": chains,
        "hetero_groups": groups,
        "waters": {},
        "ions": {},
        "asl": {
            "ligand": {
                "asl": "chain {}".format(ligand),
                "atoms": asl_atoms,
                "chains": asl_chain_list,
            }
        },
    }
    with open(output, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
