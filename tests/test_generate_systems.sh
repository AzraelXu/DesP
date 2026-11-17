#!/bin/bash
# generate_systems.sh: discovery, ligand consistency, naming, idempotency.
set -uo pipefail
source "$(dirname "$0")/lib/testlib.sh"
new_sandbox

FAKE_PYTHON="$(command -v python3 || true)"
if [[ -z "$FAKE_PYTHON" ]]; then
    echo "SKIP: python3 not found" >&2
    exit 0
fi
FAKE_SCHRODINGER="$SANDBOX/fake-schrodinger"
mkdir -p "$FAKE_SCHRODINGER"
cp "$REPO_ROOT/tests/fixtures/fake_schrodinger/run" "$FAKE_SCHRODINGER/run"
chmod +x "$FAKE_SCHRODINGER/run"
REPORT_HELPER="$REPO_ROOT/tests/fixtures/make_structure_report.py"

WORK=""
INPUT=""
REPORTS=""

setup_case() {
    local name="$1"
    WORK="$SANDBOX/case-${name}"
    INPUT="$WORK/input"
    REPORTS="$WORK/reports"
    mkdir -p "$INPUT" "$WORK/systems" "$REPORTS"
}

structure() {
    printf 'placeholder\n' > "$INPUT/$1"
}

report() {
    "$FAKE_PYTHON" "$REPORT_HELPER" "$REPORTS/$1.json" "$2"
}

check_fail() {
    : > "$REPORTS/$1.check_fail"
}

run_generate() {
    env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX/home" USER=testuser \
        LC_ALL=C TZ=UTC \
        SCH_WORK_ROOT="$WORK" SCHRODINGER="$FAKE_SCHRODINGER" \
        FAKE_INSPECT_DIR="$REPORTS" FAKE_PYTHON="$FAKE_PYTHON" \
        FAKE_INSPECT_LOG="$WORK/inspect.log" \
        bash "$REPO_ROOT/scripts/generate_systems.sh" "$@"
}

conf() {
    cat "$WORK/systems/$1"
}

# ---------------------------------------------------------------------------
# Discovery, default naming, INPUT_STRUCTURE, ASLs, dry-run.
# ---------------------------------------------------------------------------
setup_case basic
structure pdc1.mae
structure pdc1_dock.pdb
report pdc1.mae "ligand=B;resname=UNK;atoms=10;receptor=A"
report pdc1_dock.pdb "ligand=B;resname=UNL;atoms=12;receptor=A"
out="$(run_generate --input-dir "$INPUT" --dry-run 2>&1)"
rc=$?
assert_eq 0 "$rc" "basic dry-run exit"
assert_contains "$out" "pdc1.mae -> pdc1" "basic dry-run name"
assert_contains "$out" "would create" "basic dry-run action"
assert_not_exists "$WORK/systems/pdc1.conf"
out="$(run_generate --input-dir "$INPUT" 2>&1)"
rc=$?
assert_eq 0 "$rc" "basic generate exit"
assert_file_exists "$WORK/systems/pdc1.conf"
assert_file_exists "$WORK/systems/pdc1_dock.conf"
assert_contains "$(conf pdc1.conf)" 'SYSTEM_NAME="pdc1"' "basic system name"
assert_contains "$(conf pdc1.conf)" "INPUT_STRUCTURE=" "basic input key"
assert_not_contains "$(conf pdc1.conf)" "PREPARED_STRUCTURE" "basic no prepared key"
assert_contains "$(conf pdc1.conf)" 'RECEPTOR_ASL="chain A"' "basic receptor ASL"
assert_contains "$(conf pdc1.conf)" 'LIGAND_ASL="chain B"' "basic ligand ASL"
bash -n "$WORK/systems/pdc1.conf" && pass || fail "basic config bash syntax"

setup_case prepared
structure pdc1.mae
report pdc1.mae "ligand=B;receptor=A"
out="$(run_generate --input-dir "$INPUT" --structure-field prepared 2>&1)"
assert_eq 0 "$?" "prepared MAE exit"
assert_contains "$(conf pdc1.conf)" "PREPARED_STRUCTURE=" "prepared MAE key"
assert_not_contains "$(conf pdc1.conf)" "INPUT_STRUCTURE=" "prepared MAE no input key"

setup_case prepared-pdb
structure pdc1.pdb
report pdc1.pdb "ligand=B;receptor=A"
out="$(run_generate --input-dir "$INPUT" --structure-field prepared 2>&1)"
assert_eq 1 "$?" "prepared PDB exit"
assert_contains "$out" "requires .mae or .maegz" "prepared PDB message"
assert_not_exists "$WORK/systems/pdc1.conf"

# ---------------------------------------------------------------------------
# Multi-chain receptor: no outer parentheses.
# ---------------------------------------------------------------------------
setup_case multichain
structure pdc1.mae
report pdc1.mae "ligand=B;receptor=A,C"
out="$(run_generate --input-dir "$INPUT" 2>&1)"
assert_eq 0 "$?" "multichain exit"
assert_contains "$(conf pdc1.conf)" 'RECEPTOR_ASL="chain A or chain C"' "multichain ASL"

# ---------------------------------------------------------------------------
# Inconsistent ligand chains abort the whole batch.
# ---------------------------------------------------------------------------
setup_case mismatch
structure pdc1.mae
structure pdc2.mae
report pdc1.mae "ligand=B;receptor=A"
report pdc2.mae "ligand=C;receptor=A"
out="$(run_generate --input-dir "$INPUT" 2>&1)"
rc=$?
assert_eq 1 "$rc" "mismatch exit"
assert_contains "$out" "not consistent" "mismatch message"
assert_contains "$out" "pdc1.mae: B" "mismatch first chain"
assert_contains "$out" "pdc2.mae: C" "mismatch second chain"
assert_not_exists "$WORK/systems/pdc1.conf"
assert_not_exists "$WORK/systems/pdc2.conf"

# ---------------------------------------------------------------------------
# Ambiguous auto-detection.
# ---------------------------------------------------------------------------
setup_case multicandidate
structure pdc1.mae
report pdc1.mae "ligand=B;receptor=A;groups=B:UNK:10,C:UNL:5"
out="$(run_generate --input-dir "$INPUT" 2>&1)"
assert_eq 1 "$?" "multiple candidates exit"
assert_contains "$out" "multiple candidate ligand chains" "multiple candidates message"

setup_case multigroup
structure pdc1.mae
report pdc1.mae "ligand=B;receptor=A;groups=B:UNK:10,B:UNL:5"
out="$(run_generate --input-dir "$INPUT" 2>&1)"
assert_eq 1 "$?" "multiple groups exit"
assert_contains "$out" "multiple ligand residues on chain B" "multiple groups message"

# ---------------------------------------------------------------------------
# --ligand-resname emits a residue-qualified ASL.
# ---------------------------------------------------------------------------
setup_case resname
structure pdc1.mae
report pdc1.mae "ligand=B;receptor=A;groups=B:UNK:10,B:UNL:5;asl_atoms=10"
out="$(run_generate --input-dir "$INPUT" --ligand-resname UNK 2>&1)"
assert_eq 0 "$?" "resname exit"
assert_contains "$(conf pdc1.conf)" 'LIGAND_ASL="chain B and res.ptype UNK"' \
    "resname ASL is residue-qualified"
assert_contains "$(cat "$WORK/inspect.log")" "|chain B and res.ptype UNK|" \
    "resname ASL forwarded to inspector"

setup_case resname-count
structure pdc1.mae
report pdc1.mae "ligand=B;receptor=A;groups=B:UNK:10,B:UNL:5;asl_atoms=99"
out="$(run_generate --input-dir "$INPUT" --ligand-resname UNK 2>&1)"
assert_eq 1 "$?" "resname count mismatch exit"
assert_contains "$out" "selected 99 atoms" "resname count mismatch message"
assert_not_exists "$WORK/systems/pdc1.conf"

setup_case resname-chain
structure pdc1.mae
report pdc1.mae "ligand=B;receptor=A;groups=B:UNK:10,C:UNK:5;asl_atoms=10"
out="$(run_generate --input-dir "$INPUT" --ligand-resname UNK --ligand-chain B 2>&1)"
assert_eq 0 "$?" "resname+chain exit"
assert_contains "$(conf pdc1.conf)" 'LIGAND_ASL="chain B and res.ptype UNK"' \
    "resname+chain ASL"

setup_case ligand-unused
structure pdc1.mae
report pdc1.mae "ligand=B;resname=UNK;atoms=10;receptor=A"
out="$(run_generate --input-dir "$INPUT" --ligand-name-source resname 2>&1)"
assert_eq 0 "$?" "unused ligand source exit"
assert_file_exists "$WORK/systems/pdc1.conf"

setup_case blank-receptor
structure pdc1.mae
report pdc1.mae 'ligand=B;receptor=<blank>;groups=B:UNK:10'
out="$(run_generate --input-dir "$INPUT" --ligand-chain B 2>&1)"
assert_eq 0 "$?" "blank receptor exit"
assert_contains "$(conf pdc1.conf)" 'RECEPTOR_ASL="protein"' "blank receptor ASL"

setup_case blank-asl
structure pdc1.mae
report pdc1.mae 'ligand=<blank>;receptor=<blank>;groups=<blank>:UNK:10;asl_chains=<blank>;asl_atoms=10'
out="$(run_generate --input-dir "$INPUT" --ligand-asl "res.ptype UNK" 2>&1)"
assert_eq 0 "$?" "blank chain ASL exit"
assert_contains "$(conf pdc1.conf)" \
    'RECEPTOR_ASL="(protein) and not (res.ptype UNK)"' "blank chain receptor ASL"
assert_contains "$(conf pdc1.conf)" 'LIGAND_ASL="res.ptype UNK"' "blank chain ligand ASL"

setup_case manifest-input
structure pdc1.mae
report pdc1.mae "ligand=B;receptor=A"
printf 'input/pdc1.mae\n' > "$WORK/list.txt"
out="$(run_generate --input-dir "$INPUT" --manifest "$WORK/list.txt" 2>&1)"
assert_eq 2 "$?" "manifest+input-dir exit"
assert_contains "$out" "mutually exclusive" "manifest+input-dir message"

# ---------------------------------------------------------------------------
# Explicit chain can disambiguate a cofactor; peptide ligands need a chain.
# ---------------------------------------------------------------------------
setup_case cofactor
structure pdc1.mae
report pdc1.mae "ligand=B;receptor=A;groups=A:NAG:5,B:UNK:10"
out="$(run_generate --input-dir "$INPUT" --ligand-chain B 2>&1)"
assert_eq 0 "$?" "cofactor explicit chain exit"
assert_contains "$(conf pdc1.conf)" 'RECEPTOR_ASL="chain A"' "cofactor receptor ASL"
assert_contains "$(conf pdc1.conf)" 'LIGAND_ASL="chain B"' "cofactor ligand ASL"

setup_case peptide
structure pdc1.mae
report pdc1.mae "ligand=B;receptor=A,B;hetero=none"
out="$(run_generate --input-dir "$INPUT" 2>&1)"
assert_eq 1 "$?" "peptide auto exit"
assert_contains "$out" "no non-polymer ligand group detected" "peptide auto message"
out="$(run_generate --input-dir "$INPUT" --ligand-chain B 2>&1)"
assert_eq 0 "$?" "peptide explicit chain exit"
assert_contains "$out" "polymer/peptide ligand" "peptide warning"
assert_contains "$(conf pdc1.conf)" "and not (chain B)" "peptide receptor subtracts ligand"

# ---------------------------------------------------------------------------
# --ligand-asl supports ligand and protein sharing a chain.
# ---------------------------------------------------------------------------
setup_case shared
structure pdc1.mae
report pdc1.mae "ligand=A;receptor=A;groups=A:LIG:10;asl_chains=A;asl_atoms=10"
out="$(run_generate --input-dir "$INPUT" --ligand-asl "res.ptype LIG" 2>&1)"
assert_eq 0 "$?" "shared-chain ASL exit"
assert_contains "$(conf pdc1.conf)" 'RECEPTOR_ASL="(chain A) and not (res.ptype LIG)"' \
    "shared-chain receptor subtracts ASL"
assert_contains "$(conf pdc1.conf)" 'LIGAND_ASL="res.ptype LIG"' "shared-chain ligand ASL"
assert_contains "$(cat "$WORK/inspect.log")" "|res.ptype LIG|" \
    "shared-chain ASL forwarded to inspector"

setup_case aslmulti
structure pdc1.mae
report pdc1.mae "ligand=B;receptor=A;groups=B:UNK:10,C:UNL:5;asl_chains=B,C;asl_atoms=15"
out="$(run_generate --input-dir "$INPUT" --ligand-asl "chain B or chain C" 2>&1)"
assert_eq 0 "$?" "multi-chain ASL exit"
assert_contains "$(conf pdc1.conf)" 'RECEPTOR_ASL="chain A"' "multi-chain ASL receptor"

out="$(run_generate --input-dir "$INPUT" --ligand-asl "chain B or chain C" \
    --ligand-chain B 2>&1)"
assert_eq 1 "$?" "ASL chain guard exit"
assert_contains "$out" "but --ligand-chain is B" "ASL chain guard message"

# ---------------------------------------------------------------------------
# Invalid structures: blank chain, multiple CTs, missing reports, ASL check.
# ---------------------------------------------------------------------------
setup_case blank
structure pdc1.mae
report "pdc1.mae" 'ligand=<blank>;receptor=A;groups=<blank>:UNK:10;asl_chains=<blank>'
out="$(run_generate --input-dir "$INPUT" 2>&1)"
assert_eq 1 "$?" "blank chain exit"
assert_contains "$out" "blank chain IDs" "blank chain message"

setup_case cts
structure pdc1.mae
report pdc1.mae "ligand=B;receptor=A;cts=2"
out="$(run_generate --input-dir "$INPUT" 2>&1)"
assert_eq 1 "$?" "multi-CT exit"
assert_contains "$out" "contains 2 CTs" "multi-CT message"
assert_not_exists "$WORK/systems/pdc1.conf"

setup_case missing-chain
structure pdc1.mae
structure pdc2.mae
report pdc1.mae "ligand=B;receptor=A"
report pdc2.mae "ligand=C;receptor=A"
out="$(run_generate --input-dir "$INPUT" --ligand-chain B 2>&1)"
assert_eq 1 "$?" "missing explicit chain exit"
assert_file_exists "$WORK/systems/pdc1.conf"
assert_not_exists "$WORK/systems/pdc2.conf"
assert_contains "$out" "chain B not found" "missing explicit chain message"

setup_case missing-report
structure pdc1.mae
structure pdc2.mae
report pdc1.mae "ligand=B;receptor=A"
out="$(run_generate --input-dir "$INPUT" 2>&1)"
assert_eq 1 "$?" "missing report exit"
assert_file_exists "$WORK/systems/pdc1.conf"
assert_not_exists "$WORK/systems/pdc2.conf"
assert_contains "$out" "report not found" "missing report message"

setup_case checkfail
structure pdc1.mae
report pdc1.mae "ligand=B;receptor=A"
check_fail pdc1.mae
out="$(run_generate --input-dir "$INPUT" 2>&1)"
assert_eq 1 "$?" "ASL check failure exit"
assert_contains "$out" "ASL check failed" "ASL check failure message"
assert_not_exists "$WORK/systems/pdc1.conf"

# ---------------------------------------------------------------------------
# Normalization, templates, ligand-name sources.
# ---------------------------------------------------------------------------
setup_case normalize
structure "pdc 1@x.mae"
report "pdc 1@x.mae" "ligand=B;receptor=A"
out="$(run_generate --input-dir "$INPUT" 2>&1)"
assert_eq 0 "$?" "normalization exit"
assert_file_exists "$WORK/systems/pdc_1_x.conf"
assert_contains "$(conf pdc_1_x.conf)" 'SYSTEM_NAME="pdc_1_x"' "normalized system name"

setup_case template
structure PSMA_pdc1.mae
report PSMA_pdc1.mae "ligand=B;resname=UNK;atoms=10;receptor=A"
out="$(run_generate --input-dir "$INPUT" --target PSMA \
    --name-template '{target}_{ligand}_{index:02d}' 2>&1)"
assert_eq 0 "$?" "template exit"
assert_file_exists "$WORK/systems/PSMA_pdc1_01.conf"
assert_contains "$out" "PSMA_pdc1_01" "template name in log"

setup_case target-missing
structure pdc1.mae
report pdc1.mae "ligand=B;receptor=A"
out="$(run_generate --input-dir "$INPUT" --name-template '{target}_{stem}' 2>&1)"
assert_eq 2 "$?" "missing target exit"
assert_contains "$out" "uses {target} but --target was not provided" "missing target message"
assert_not_exists "$WORK/systems/pdc1.conf"

# ---------------------------------------------------------------------------
# Name collisions: error by default, suffix avoids existing base names.
# ---------------------------------------------------------------------------
setup_case collision
mkdir -p "$INPUT/a" "$INPUT/b" "$INPUT/c"
printf 'placeholder\n' > "$INPUT/a/pdc 1.mae"
printf 'placeholder\n' > "$INPUT/b/pdc@1.mae"
printf 'placeholder\n' > "$INPUT/c/pdc_1_2.mae"
report "pdc 1.mae" "ligand=B;receptor=A"
report "pdc@1.mae" "ligand=B;receptor=A"
report "pdc_1_2.mae" "ligand=B;receptor=A"
out="$(run_generate --input-dir "$INPUT" --recursive 2>&1)"
assert_eq 1 "$?" "collision error exit"
assert_contains "$out" "system name collision" "collision error message"
assert_not_exists "$WORK/systems/pdc_1.conf"
out="$(run_generate --input-dir "$INPUT" --recursive --name-conflict suffix 2>&1)"
assert_eq 0 "$?" "collision suffix exit"
assert_file_exists "$WORK/systems/pdc_1.conf"
assert_file_exists "$WORK/systems/pdc_1_2.conf"
assert_file_exists "$WORK/systems/pdc_1_3.conf"
assert_contains "$(conf pdc_1.conf)" 'SYSTEM_NAME="pdc_1"' "collision base name"
assert_contains "$(conf pdc_1_2.conf)" 'SYSTEM_NAME="pdc_1_2"' "collision original suffix name"
assert_contains "$(conf pdc_1_3.conf)" 'SYSTEM_NAME="pdc_1_3"' "collision suffixed name"

# ---------------------------------------------------------------------------
# Idempotency and existing-config policies.
# ---------------------------------------------------------------------------
setup_case idempotent
structure pdc1.mae
report pdc1.mae "ligand=B;receptor=A"
out="$(run_generate --input-dir "$INPUT" 2>&1)"
assert_eq 0 "$?" "idempotent first exit"
sum_before="$(sha256sum "$WORK/systems/pdc1.conf")"
out="$(run_generate --input-dir "$INPUT" 2>&1)"
assert_eq 0 "$?" "idempotent second exit"
assert_contains "$out" "[SKIP]" "idempotent skip"
assert_eq "$sum_before" "$(sha256sum "$WORK/systems/pdc1.conf")" "idempotent checksum"
printf '\n# manual edit\n' >> "$WORK/systems/pdc1.conf"
cp "$WORK/systems/pdc1.conf" "$SANDBOX/edited.conf"
out="$(run_generate --input-dir "$INPUT" 2>&1)"
assert_eq 0 "$?" "differing config exit"
assert_contains "$out" "exists and differs" "differing config warning"
if cmp -s "$SANDBOX/edited.conf" "$WORK/systems/pdc1.conf"; then
    pass
else
    fail "differing config was overwritten without --overwrite"
fi
out="$(run_generate --input-dir "$INPUT" --overwrite 2>&1)"
assert_eq 0 "$?" "overwrite exit"
assert_contains "$out" "overwriting" "overwrite warning"
assert_eq "$sum_before" "$(sha256sum "$WORK/systems/pdc1.conf")" "overwrite restored content"

setup_case existing-error
structure pdc1.mae
report pdc1.mae "ligand=B;receptor=A"
mkdir -p "$WORK/systems"
printf 'SYSTEM_NAME="manual"\n' > "$WORK/systems/pdc1.conf"
out="$(run_generate --input-dir "$INPUT" --on-existing error 2>&1)"
assert_eq 1 "$?" "on-existing error exit"
assert_contains "$out" "config exists and differs" "on-existing error message"
assert_contains "$(conf pdc1.conf)" 'SYSTEM_NAME="manual"' "on-existing error kept file"

# ---------------------------------------------------------------------------
# Dry-run reports the real per-file action.
# ---------------------------------------------------------------------------
setup_case dryrun
structure pdc1.mae
structure pdc2.mae
report pdc1.mae "ligand=B;receptor=A"
report pdc2.mae "ligand=B;receptor=A"
out="$(run_generate --input-dir "$INPUT" 2>&1)"
assert_eq 0 "$?" "dryrun setup exit"
printf '\n# manual edit\n' >> "$WORK/systems/pdc2.conf"
out="$(run_generate --input-dir "$INPUT" --dry-run 2>&1)"
assert_eq 0 "$?" "dryrun exit"
assert_contains "$out" "would skip, unchanged" "dryrun unchanged"
assert_contains "$out" "would keep, exists and differs" "dryrun differs"
out="$(run_generate --input-dir "$INPUT" --dry-run --overwrite 2>&1)"
assert_eq 0 "$?" "dryrun overwrite exit"
assert_contains "$out" "would overwrite" "dryrun overwrite"
grep -Fq '# manual edit' "$WORK/systems/pdc2.conf" && pass || fail "dryrun wrote to disk"

# ---------------------------------------------------------------------------
# Empty input and missing Schrodinger.
# ---------------------------------------------------------------------------
setup_case empty
out="$(run_generate --input-dir "$INPUT" 2>&1)"
assert_eq 0 "$?" "empty input exit"
assert_contains "$out" "No .pdb/.mae/.maegz files found" "empty input message"
assert_contains "$out" "discovered : 0" "empty input summary"

setup_case noschrod
structure pdc1.mae
report pdc1.mae "ligand=B;receptor=A"
out="$(env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX/home" USER=testuser \
    LC_ALL=C TZ=UTC SCH_WORK_ROOT="$WORK" SCHRODINGER="$SANDBOX/no-schrodinger" \
    bash "$REPO_ROOT/scripts/generate_systems.sh" --input-dir "$INPUT" 2>&1)"
assert_eq 1 "$?" "missing Schrodinger exit"
assert_contains "$out" "Schrodinger not found" "missing Schrodinger message"

# ---------------------------------------------------------------------------
# Manifest: order controls {index}; missing entries fail individually.
# ---------------------------------------------------------------------------
setup_case manifest
structure pdc1.mae
structure pdc2.mae
report pdc1.mae "ligand=B;receptor=A"
report pdc2.mae "ligand=B;receptor=A"
cat > "$WORK/list.txt" <<'EOF'
# reverse order
input/pdc2.mae
input/pdc1.mae
EOF
out="$(run_generate --manifest "$WORK/list.txt" --name-template 'sys{index:02d}' 2>&1)"
assert_eq 0 "$?" "manifest exit"
assert_file_exists "$WORK/systems/sys01.conf"
assert_file_exists "$WORK/systems/sys02.conf"
assert_contains "$(conf sys01.conf)" "input/pdc2.mae" "manifest order index 1"
assert_contains "$(conf sys02.conf)" "input/pdc1.mae" "manifest order index 2"
printf 'input/missing.mae\n' >> "$WORK/list.txt"
out="$(run_generate --manifest "$WORK/list.txt" --name-template 'sys{index:02d}' 2>&1)"
assert_eq 1 "$?" "manifest missing entry exit"
assert_file_exists "$WORK/systems/sys01.conf"
assert_contains "$out" "file not found" "manifest missing entry message"

# ---------------------------------------------------------------------------
# Recursive scanning prunes nested work roots and output dirs.
# ---------------------------------------------------------------------------
setup_case prune
structure root.mae
report root.mae "ligand=B;receptor=A"
mkdir -p "$INPUT/test" "$INPUT/systems" "$INPUT/.hidden"
printf 'placeholder\n' > "$INPUT/test/hidden.mae"
printf 'placeholder\n' > "$INPUT/systems/skip.mae"
printf 'placeholder\n' > "$INPUT/.hidden/skip2.mae"
report hidden.mae "ligand=B;receptor=A"
report skip.mae "ligand=B;receptor=A"
report skip2.mae "ligand=B;receptor=A"
: > "$INPUT/test/.desmond_work_root"
out="$(run_generate --input-dir "$INPUT" --recursive 2>&1)"
assert_eq 0 "$?" "recursive prune exit"
assert_contains "$out" "discovered : 1" "recursive prune count"
assert_file_exists "$WORK/systems/root.conf"
assert_not_exists "$WORK/systems/hidden.conf"
assert_not_exists "$WORK/systems/skip.conf"
assert_not_exists "$WORK/systems/skip2.conf"

# ---------------------------------------------------------------------------
# Equivalence: load_system_conf accepts the generated config unchanged.
# ---------------------------------------------------------------------------
setup_case equivalence
structure pdc1.mae
report pdc1.mae "ligand=B;receptor=A"
out="$(run_generate --input-dir "$INPUT" 2>&1)"
assert_eq 0 "$?" "equivalence generate exit"
out="$(env SCH_WORK_ROOT="$WORK" PIPELINE_ROOT="$REPO_ROOT" \
    bash -c 'source "$1/scripts/lib/common.sh"; load_system_conf "$2"; \
             printf "%s|%s|%s|%s\n" "$SYSTEM_NAME" "$RECEPTOR_ASL" "$LIGAND_ASL" "$INPUT_STRUCTURE"' \
    _ "$REPO_ROOT" "$WORK/systems/pdc1.conf" 2>&1)"
rc=$?
assert_eq 0 "$rc" "load_system_conf exit"
assert_eq "pdc1|chain A|chain B|$INPUT/pdc1.mae" "$out" "load_system_conf values"

finish
