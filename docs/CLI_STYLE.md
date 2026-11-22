# CLI Output Style Guide

This document is the single reference for terminal output in the Desmond
pipeline. Business scripts must call the shared helpers; do not write ANSI
escapes directly.

Shared modules:

| Language | File | Usage |
|---|---|---|
| Bash | `scripts/lib/ui.sh` | `source "${PIPELINE_ROOT}/scripts/lib/ui.sh"` |
| Python | `scripts/sch_ui.py` | `import sch_ui` (`scripts/*.py` import it directly; other Python entry points add `scripts/` to `sys.path`) |

Both implementations use the same colors, labels, stream routing, and
automatic downgrade rules. They are standard-library only (no colorama/rich):
the cluster has no network install path and Schrödinger bundles an older
Python.

## Color table

| Purpose | SGR | Notes |
|---|---|---|
| FATAL label | `1;97;41` | bold bright white on red |
| FATAL/ERROR body | `1;31` | red bold, whole line |
| WARNING | `1;33` | yellow bold; only the label is colored |
| OK / PASS / SUCCESS | `1;32` | green bold; only the label is colored |
| INFO / key values / commands / paths | `36` | cyan |
| DEBUG / footnotes / rules | `90` | gray |
| Section headers | `1` | bold, default foreground |
| Reset | `0` | emitted after every colored span |

Rules:

- FATAL and ERROR color the **whole line** red bold. The FATAL label itself is
  white on red.
- WARNING, OK/PASS, INFO, DEBUG, SKIP, FAIL, DRY-RUN color only the leading
  label (and, for Next steps, the command token). The body stays default.
- Plain output, data values, tables, and file contents are never colored.
- Colors are chosen to read on both dark and light terminal backgrounds; avoid
  bright blue, dark yellow, and bright cyan.

## Modes and precedence

```
--color=auto|always|never   (command line, highest)
SCH_COLOR=auto|always|never (environment default)
auto                        (fallback)
```

`--color` accepts both `--color=always` and `--color always`. `--` stops
option parsing. A missing or invalid value prints
`Invalid --color value: ... (use auto, always, or never)` to stderr and exits
with status 2.

In `auto` mode colors are decided **per output stream**:

- stdout helpers check fd 1 is a TTY;
- stderr helpers check fd 2 is a TTY;
- colors are off when the target stream is not a TTY, or `NO_COLOR` is
  non-empty, or `CI` is non-empty, or `TERM=dumb`.

`always` overrides these auto conditions; `never` disables colors globally.
This means `cmd > out.log` keeps warnings colored on the terminal, while
`cmd 2> err.log` writes no ANSI into `err.log`.

### Bash argument pre-scan

```bash
source "${PIPELINE_ROOT}/scripts/lib/ui.sh"
ui_parse_color_args "$@" || exit $?
set -- "${UI_ARGS[@]+"${UI_ARGS[@]}"}"
```

`ui_parse_color_args` fills the global `UI_ARGS` array, removes `--color`, sets
and exports `SCH_COLOR`, and returns 2 on a bad value. The
`"${UI_ARGS[@]+"${UI_ARGS[@]}"}"` form is required for Bash < 4.4 under
`set -u`.

### Python argument pre-scan

```python
import sch_ui
args = sch_ui.extract_color_arg(sys.argv[1:])
```

`extract_color_arg` sets the mode, exports `SCH_COLOR`, and exits with status 2
on a bad value. It must run before `argparse`.

Aliases in `~/.bashrc` are direct script paths, so `--color` passes through
without wrapper changes. Parent commands export `SCH_COLOR`, so children
(`desmond-batch` -> `desmond-submit`, etc.) use the same mode.

The eight `desmond-*` entry points and the two structure generators
(`generate_systems.py`, `inspect_structure.py`) expose `--color`. Internal PBS
tools (`tools/*.py`) and stage scripts write to log files; they rely on auto
downgrade plus the PBS-level `SCH_COLOR=never` and intentionally stay plain.

## API

Bash and Python expose the same names:

```
ok  info  warn  error  fatal  debug  header  rule  next_steps
```

In addition, both have a text-preserving low-level emitter:

- Bash: `ui_emit LEVEL TEXT`
- Python: `sch_ui.emit(LEVEL, TEXT)`

`ui_emit_out` (Bash) / `emit_out` (Python) is the same emitter but always
writes to stdout. Use it for report lines that keep their original stream, such
as a dry-run plan's `[ERROR]` item.

`ui_emit` does not add a prefix. It recognizes existing labels:
`[WARN]`, `WARNING :`, `WARNING:`, `WARN:`, `[OK]`, `[PASS]`, `OK:`,
`SUCCESS:`, `[FAIL]`, `FAIL:`, `[INFO]`, `INFO:`, `[DEBUG]`, `DEBUG:`,
`[SKIP]`, `SKIP:`, `[DRY-RUN]`, `FATAL:`, `ERROR:`. If no label matches, the
text is printed unchanged. Use it when a script has a legacy prefix that must
stay byte-identical.

High-level helpers add canonical prefixes: `warn` prints `WARNING: ...`,
`error` prints `ERROR: ...`, `fatal` prints `FATAL: ...`, and `ok` prints
`[OK] ...`. `fatal` prints but does **not** exit; callers keep their existing
`exit 1` / `return 1` behavior.

Other helpers:

- `header TEXT`: bold section title.
- `rule [TEXT]`: gray rule; default 60 `=`.
- `debug TEXT`: gray secondary text.
- `ui_kv LABEL VALUE [WIDTH]` / `sch_ui.kv(LABEL, VALUE, WIDTH, INDENT)`:
  preserves the legacy `printf '%-Ns: %s'` layout; label bold, value cyan.
  Use width 10 for the Work root summary and width 8 for status fields.
  Python's `indent` argument prepends spaces without changing the alignment
  (used by generate_systems.py's two-space summary).
- `ui_strip TEXT` / `sch_ui.strip(TEXT)`: remove ANSI (tests/debugging).

Every Python output function calls `flush=True` and flushes stdout before
writing to stderr, preserving order under `cmd 2>&1`.

## Output streams

| Level | Stream |
|---|---|
| FATAL / ERROR / WARNING | stderr |
| OK / INFO / DEBUG / HEADER / RULE / Next steps | stdout |
| `[FAIL]` check results | stdout (check_env counter) |
| Report lines with `[ERROR]`/`WARNING` labels | unchanged stream (use `emit_out`) |

Report lines that merely contain a level word (for example a dry-run plan's
`[ERROR]` item, or status's `WARNING : ETA exceeds ...`) keep their existing
stream and field order. Only actual warning/error emissions move to stderr.

`common.sh`'s `log()` colors only the terminal copy. The line written to
`projects/*/logs/pipeline.log` is always plain text, because `desmond-status`
parses it with `^\[LEVEL\] timestamp`.

## Next steps

Bash `next_steps STATUS [--footer-line LINE]... STEP...` and Python
`sch_ui.next_steps(status, steps, footer=None)` render:

```
Next steps:
  1) Review generated configs in /work/systems/.
  2) desmond-batch /work/systems/
  3) desmond-status
  4) desmond-results
     (example.conf is a template; directory batch submission skips it
      by default. Pass it explicitly if you really need to run it.)
```

Rules:

1. Numbering is generated from the actual list; never hard-code `1)`, `2)`.
2. Zero steps means no output at all, including the header and footer.
3. `STATUS` is a semantic label only. The renderer never adds, removes, or
   filters steps; the caller decides whether `desmond-check`/`desmond-smoke`
   belong in the success or failure list.
4. Footer lines are gray; the first line is indented 5 spaces, continuations
   6 spaces.
5. The command token (first word) is cyan when it looks like a pipeline
   command: `desmond-*`, `scripts/*.sh`, or `*/scripts/*.sh`.
6. Main-flow success block: Review configs -> batch -> status -> results.
   Failure block: fix/edit -> check -> smoke -> submit -> status -> results.
7. Keep the `example.conf` footnote in the success block.

## Never color these

Even with `--color=always`:

- `systems/*.conf` and any generated config content.
- The `~/.bashrc` managed block.
- `.desmond_work_root`, `projects/*/state/*.done`, `jobs.env`, `run.env`,
  `status_reported.env`, `.gpu_locks`.
- `pipeline.log`, PBS stdout/log files, JSON reports, `results/*.md`.
- Any heredoc, template render, or log write.
- Any text another script greps/awks/parses.

Implementation safeguards:

- File writes never go through the UI helpers.
- `stage_log_start` calls `ui_set_color never` after redirecting stdout/stderr
  to the stage log.
- Captured child processes (`validate_cms`, `check_asls`,
  `inspect_structure.py`, `run_inspector`) run with `SCH_COLOR=never`.
- `submit_*` run `qsub` with `SCH_COLOR=never`, and PBS templates export
  `SCH_COLOR=never` after their own redirect, so `qsub -V` cannot leak
  `always` into compute jobs.

## Adding a script

1. Source `lib/ui.sh` or import `sch_ui`.
2. Run the `--color` pre-scan before the existing parser.
3. Replace local `echo`/`printf`/`print` output for labels with the helpers.
4. Keep all `printf > file`, heredocs, and template rendering untouched.
5. If the script writes a log parsed elsewhere, write the plain string and
   color only the terminal copy.
6. Add the script to the relevant batch and run
   `TMPDIR=/home/sch/tmp/user1 bash tests/run_tests.sh`.

## Verification commands

```bash
# No ANSI in a captured log
cmd > out.log 2>&1
LC_ALL=C grep -q $'\033\[' out.log && echo "ANSI leaked" || echo "plain"

# Colors preserved through a pager
cmd --color=always | cat -v | grep -q '\^\[' && echo "colored"

# Automatic downgrade
NO_COLOR=1 cmd | cat -v
CI=true cmd | cat -v
TERM=dumb cmd | cat -v
```

## Scratch directory (desmond-status ETA)

`config.sh` defines `SCH_SCRATCH_DIR`, defaulting to
`/home/sch/tmp/${USER}`. `desmond-status` searches it (plus
`SCHRODINGER_TMPDIR`, `TMPDIR`, `$HOME/tmp/$USER`, and `$HOME/tmp`) for the
live MD engine log. The directory must be shared and writable from both the
login node and compute nodes; otherwise the login-node status cannot read the
engine log written by the compute node. Existing `$HOME/tmp` layouts keep
working.
