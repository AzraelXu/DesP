#!/usr/bin/env python3
"""Generate per-system Bash configs for the Desmond pipeline.

The script scans a directory (or an explicit manifest) for protein-ligand
complexes, verifies that the ligand occupies a consistent chain across all
complexes, and writes $SCH_WORK_ROOT/systems/<name>.conf files that are
equivalent to hand-written configs.

Run it through scripts/generate_systems.sh, which sets SCHRODINGER and
SCH_WORK_ROOT:

    scripts/generate_systems.sh --dry-run
    scripts/generate_systems.sh --ligand-chain B
    scripts/generate_systems.sh --name-template '{target}_{ligand}_{index}'

The structure inspection is delegated to scripts/inspect_structure.py and
therefore requires the Schrodinger Python interpreter.
"""

import argparse
import os
import re
import sys
import tempfile

import sch_ui
from system_generation import (
    CHAIN_RE,
    GENERATED_MARKER,
    LIGAND_NAME_SOURCES,
    PLACEHOLDER_FIELDS,
    RESNAME_RE,
    GenerationError,
    bash_quote,
    bash_syntax_check,
    build_receptor_asl,
    detect_ligand,
    discover_structures,
    existing_action,
    fatal,
    render_config,
    resolve_names,
    resolve_schrodinger,
    resolve_systems_dir,
    run_inspector,
    system_name_for,
    template_fields,
    validate_asls,
    warn,
    write_config,
)

SUMMARY_WIDTH = 66


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Generate per-system .conf files from protein-ligand complexes."
    )
    parser.add_argument("--input-dir", default="",
                        help="Directory to scan (default: current directory).")
    parser.add_argument("--recursive", action="store_true",
                        help="Scan subdirectories; skips hidden/nested work-root dirs.")
    parser.add_argument("--manifest", default="",
                        help="Explicit list of structure files (one path per line).")
    parser.add_argument("--ligand-chain", default="",
                        help="Ligand chain ID; default: auto-detect.")
    parser.add_argument("--ligand-resname", default="",
                        help="Comma-separated residue name(s) used to select the ligand.")
    parser.add_argument("--ligand-asl", default="",
                        help="Explicit ligand ASL; selected chains are excluded from the receptor.")
    parser.add_argument("--ligand-regex", default="",
                        help="Regex for the filename ligand-name source.")
    parser.add_argument("--structure-field", choices=("input", "prepared"), default="input",
                        help="Write INPUT_STRUCTURE (default) or PREPARED_STRUCTURE.")
    parser.add_argument("--name-template", default="{stem}",
                        help="System-name template; fields: {stem} {target} {ligand} {index}.")
    parser.add_argument("--target", default="",
                        help="Value for {target}; also stripped as a filename prefix.")
    parser.add_argument("--ligand-name-source", default="filename,resname,index",
                        help="Priority list for {ligand} (filename,resname,index).")
    parser.add_argument("--name-conflict", choices=("error", "suffix"), default="error",
                        help="Action when two inputs normalize to the same system name.")
    existing = parser.add_mutually_exclusive_group()
    existing.add_argument("--on-existing", choices=("skip", "overwrite", "error"), default="skip",
                          help="Action when the system config already exists.")
    existing.add_argument("--overwrite", action="store_true",
                          help="Shortcut for --on-existing overwrite.")
    existing.add_argument("--skip", action="store_true",
                          help="Shortcut for --on-existing skip (default).")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print the plan without writing any config files.")
    parser.add_argument("--color", choices=("auto", "always", "never"), default=None,
                        help="Color output (default: auto).")
    parser.add_argument("--check-args", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.color is not None:
        sch_ui.set_color(args.color)

    if args.manifest and args.input_dir:
        parser.error("--manifest and --input-dir are mutually exclusive")
    if args.manifest:
        if not os.path.isfile(args.manifest):
            parser.error("--manifest file not found: {}".format(args.manifest))
    else:
        if not args.input_dir:
            try:
                args.input_dir = os.getcwd()
            except OSError as exc:
                parser.error("cannot determine current directory: {}".format(exc))
        if not os.path.isdir(args.input_dir):
            parser.error("--input-dir is not a directory: {}".format(args.input_dir))

    if args.ligand_resname and args.ligand_asl:
        parser.error("--ligand-resname and --ligand-asl are mutually exclusive")

    if args.ligand_chain:
        args.ligand_chain = args.ligand_chain.strip()
        if not CHAIN_RE.match(args.ligand_chain):
            parser.error("invalid --ligand-chain: {!r}".format(args.ligand_chain))

    args.ligand_resnames = []
    if args.ligand_resname:
        args.ligand_resnames = [n.strip() for n in args.ligand_resname.split(",") if n.strip()]
        if not args.ligand_resnames:
            parser.error("--ligand-resname is empty")
        for name in args.ligand_resnames:
            if not RESNAME_RE.match(name):
                parser.error("invalid residue name {!r}; use --ligand-asl for unusual names".format(name))

    args.ligand_re = None
    if args.ligand_regex:
        try:
            args.ligand_re = re.compile(args.ligand_regex)
        except re.error as exc:
            parser.error("invalid --ligand-regex: {}".format(exc))
        if "ligand" not in args.ligand_re.groupindex and args.ligand_re.groups < 1:
            parser.error("--ligand-regex needs a named group 'ligand' or at least one capture group")

    sources = [s.strip() for s in args.ligand_name_source.split(",") if s.strip()]
    if not sources:
        parser.error("--ligand-name-source is empty")
    for source in sources:
        if source not in LIGAND_NAME_SOURCES:
            parser.error("invalid --ligand-name-source entry: {!r}".format(source))
    if len(set(sources)) != len(sources):
        parser.error("--ligand-name-source contains duplicate entries")
    args.ligand_name_sources = sources

    try:
        fields = template_fields(args.name_template)
    except ValueError as exc:
        parser.error("invalid --name-template: {}".format(exc))
    unknown = fields - set(PLACEHOLDER_FIELDS)
    if unknown:
        parser.error("unknown --name-template placeholder(s): {}; supported: {}".format(
            ", ".join(sorted(unknown)), ", ".join(PLACEHOLDER_FIELDS)))
    if "target" in fields and not args.target:
        parser.error("--name-template uses {target} but --target was not provided")
    args.name_template_fields = fields

    if args.overwrite:
        args.on_existing_policy = "overwrite"
    elif args.skip:
        args.on_existing_policy = "skip"
    else:
        args.on_existing_policy = args.on_existing
    return args


def print_summary(input_label, systems_dir, discovered, counts, failures, dry_run=False):
    sch_ui.rule("=" * SUMMARY_WIDTH)
    sch_ui.header("Batch system generation summary{}".format(" (dry run)" if dry_run else ""))
    sch_ui.kv("input", input_label, 11, indent=2)
    sch_ui.kv("systems", systems_dir, 11, indent=2)
    sch_ui.kv("discovered", discovered, 11, indent=2)
    sch_ui.kv("created", counts["created"], 11, indent=2)
    sch_ui.kv("overwritten", counts["overwritten"], 11, indent=2)
    sch_ui.kv("skipped", counts["skipped"], 11, indent=2)
    sch_ui.kv("failed", len(failures), 11, indent=2)
    if failures:
        sch_ui.header("Failed systems:")
        for entry, reason in failures:
            print("  {}: {}".format(entry["display"], reason))
    sch_ui.rule("=" * SUMMARY_WIDTH)


def print_plan_line(item, path, action, reason, args):
    entry = item["entry"]
    system_name = item["system_name"]
    if action == "create":
        sch_ui.emit("DRY-RUN", "[DRY-RUN] {} -> {} (would create {})".format(
            entry["display"], system_name, path))
    elif action == "skip_unchanged":
        sch_ui.emit("DRY-RUN", "[DRY-RUN] {} -> {} (would skip, unchanged: {})".format(
            entry["display"], system_name, path))
    elif action == "skip_differs":
        sch_ui.emit("DRY-RUN", "[DRY-RUN] {} -> {} (would keep, exists and differs: {})".format(
            entry["display"], system_name, path))
    elif action == "overwrite":
        sch_ui.emit("DRY-RUN", "[DRY-RUN] {} -> {} (would overwrite {})".format(
            entry["display"], system_name, path))
    else:
        sch_ui.emit_out("ERROR", "[ERROR]   {} -> {} (would fail: {})".format(
            entry["display"], system_name, reason))
    if action != "fail":
        print("          {}={}  RECEPTOR_ASL={}  LIGAND_ASL={}".format(
            "PREPARED_STRUCTURE" if args.structure_field == "prepared"
            else "INPUT_STRUCTURE",
            bash_quote(entry["path"]),
            bash_quote(item["receptor_asl"]),
            bash_quote(item["ligand"]["ligand_asl"])))


def main(argv=None):
    if argv is None:
        argv = sys.argv[1:]
    else:
        argv = list(argv)
    argv = sch_ui.extract_color_arg(argv)
    args = parse_args(argv)
    if args.check_args:
        return 0
    try:
        run_exe = resolve_schrodinger()
        systems_dir = resolve_systems_dir()
    except GenerationError as exc:
        fatal(str(exc))
        return 1

    try:
        entries = discover_structures(args)
    except GenerationError as exc:
        fatal(str(exc))
        return 1

    input_label = os.path.abspath(args.manifest) if args.manifest else os.path.abspath(
        args.input_dir)
    counts = {"created": 0, "overwritten": 0, "skipped": 0}
    failures = []

    if not entries:
        print("No .pdb/.mae/.maegz files found in {}".format(input_label))
        print_summary(input_label, systems_dir, 0, counts, failures, args.dry_run)
        return 0

    inspector = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "inspect_structure.py")

    with tempfile.TemporaryDirectory(prefix="desmond_generate_") as tmpdir:
        detected = []
        for entry in entries:
            if entry["error"]:
                failures.append((entry, entry["error"]))
                continue
            try:
                report = run_inspector(
                    run_exe, inspector, entry["path"], tmpdir,
                    ligand_asl=args.ligand_asl or None)
                cts = int(report.get("cts", 1))
                if cts > 1:
                    raise GenerationError(
                        "{}: file contains {} CTs; split it into one complex per file".format(
                            entry["display"], cts))
                ligand_info = detect_ligand(report, args, entry["display"])
                for message in ligand_info.get("warnings", []):
                    warn("{}: {}".format(entry["display"], message))
                detected.append({
                    "entry": entry,
                    "report": report,
                    "ligand": ligand_info,
                })
            except GenerationError as exc:
                failures.append((entry, str(exc)))

        if not detected:
            print_summary(input_label, systems_dir, len(entries), counts, failures,
                          args.dry_run)
            return 1

        signatures = {}
        for item in detected:
            signature = frozenset(item["ligand"]["chains"])
            signatures.setdefault(signature, []).append(item)
        if len(signatures) > 1:
            sch_ui.emit("FATAL",
                        "FATAL: ligand chain is not consistent across input structures:")
            for item in detected:
                print("  {}: {}".format(
                    item["entry"]["display"],
                    ",".join(sorted(item["ligand"]["chains"])) or "(none)"),
                      file=sys.stderr)
            print("Unify the ligand chain IDs in the input structures, or pass "
                  "--ligand-chain to select a common chain.", file=sys.stderr)
            for entry, reason in failures:
                sch_ui.emit_out("ERROR", "[ERROR] {}: {}".format(entry["display"], reason))
            return 1

        receptor_signatures = set()
        for item in detected:
            chains = item["report"].get("chains") or {}
            ligand_chains = set(item["ligand"]["chains"])
            polymer = {
                chain for chain, info in chains.items()
                if int(info.get("polymer_residues", 0)) > 0
            }
            receptor_signatures.add(frozenset(polymer - (ligand_chains - polymer)))
        if len(receptor_signatures) > 1:
            warn("receptor chains differ across input structures; verify RECEPTOR_ASL")

        successes = []
        for item in detected:
            entry = item["entry"]
            report = item["report"]
            ligand_info = item["ligand"]
            try:
                receptor_asl = build_receptor_asl(report, ligand_info, entry["display"])
                validate_asls(run_exe, inspector, entry, receptor_asl, ligand_info, tmpdir)
                system_name = system_name_for(entry, ligand_info, args)
                item.update({
                    "system_name": system_name,
                    "receptor_asl": receptor_asl,
                })
                successes.append(item)
            except GenerationError as exc:
                failures.append((entry, str(exc)))

        try:
            resolve_names(successes, args)
        except GenerationError as exc:
            for entry, reason in failures:
                sch_ui.emit_out("ERROR", "[ERROR] {}: {}".format(entry["display"], reason))
            fatal(str(exc))
            return 1

        rendered = []
        for item in successes:
            try:
                item["content"] = render_config(
                    item["entry"], item["system_name"], args,
                    item["receptor_asl"], item["ligand"])
                bash_syntax_check(item["content"], item["entry"]["display"])
                rendered.append(item)
            except GenerationError as exc:
                failures.append((item["entry"], str(exc)))
        successes = rendered

        for item in successes:
            entry = item["entry"]
            system_name = item["system_name"]
            path = os.path.join(systems_dir, system_name + ".conf")
            action, reason = existing_action(path, item["content"],
                                             args.on_existing_policy)
            if args.dry_run:
                print_plan_line(item, path, action, reason, args)
                if action == "fail":
                    failures.append((entry, reason))
                else:
                    counts["skipped" if action.startswith("skip") else
                           ("overwritten" if action == "overwrite" else "created")] += 1
                continue

            try:
                if action == "create":
                    write_config(path, item["content"])
                    counts["created"] += 1
                    sch_ui.emit("OK", "[OK]      {} -> {}".format(entry["display"], system_name))
                    sch_ui.kv("config", path, 6, indent=10)
                    print("          {}={}  RECEPTOR_ASL={}  LIGAND_ASL={}".format(
                        "PREPARED_STRUCTURE" if args.structure_field == "prepared"
                        else "INPUT_STRUCTURE",
                        bash_quote(entry["path"]),
                        bash_quote(item["receptor_asl"]),
                        bash_quote(item["ligand"]["ligand_asl"])))
                elif action == "overwrite":
                    with open(path, "r", encoding="utf-8", errors="replace") as handle:
                        existing = handle.read()
                    if GENERATED_MARKER not in existing:
                        warn("overwriting {} (no generated marker; manual edits will be lost)".format(
                            path))
                    else:
                        warn("overwriting {} (manual edits will be lost)".format(path))
                    write_config(path, item["content"])
                    counts["overwritten"] += 1
                    sch_ui.emit("OK", "[OK]      {} -> {} (overwritten)".format(
                        entry["display"], system_name))
                    sch_ui.kv("config", path, 6, indent=10)
                elif action == "skip_unchanged":
                    counts["skipped"] += 1
                    sch_ui.emit("SKIP", "[SKIP]    {} -> {} (config exists, unchanged)".format(
                        entry["display"], system_name))
                    sch_ui.kv("config", path, 6, indent=10)
                elif action == "skip_differs":
                    counts["skipped"] += 1
                    sch_ui.emit("WARN", "[WARN]    {} -> {} (config exists and differs; kept, "
                                "use --overwrite)".format(entry["display"], system_name))
                    sch_ui.kv("config", path, 6, indent=10)
                else:
                    failures.append((entry, reason))
                    sch_ui.emit("ERROR", "[ERROR]   {}: {}".format(entry["display"], reason))
                    sch_ui.kv("config", path, 6, indent=10)
            except OSError as exc:
                failures.append((entry, "write failed: {}".format(exc)))
                sch_ui.emit("ERROR", "[ERROR]   {}: write failed: {}".format(
                    entry["display"], exc))
                sch_ui.kv("config", path, 6, indent=10)

    print_summary(input_label, systems_dir, len(entries), counts, failures, args.dry_run)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
