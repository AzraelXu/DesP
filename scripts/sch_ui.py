#!/usr/bin/env python3
"""Shared terminal output helpers for the Desmond pipeline.

Color mode precedence: --color=auto|always|never > $SCH_COLOR > auto.
In auto mode colors are enabled per output stream only when that stream is a
TTY and NO_COLOR/CI are unset and TERM is not "dumb".

Business code must call these helpers instead of writing ANSI escapes.
This module uses the standard library only.
"""

import os
import re
import sys

RESET = "\033[0m"
BOLD = "\033[1m"
RED = "\033[1;31m"
FATAL_LABEL = "\033[1;97;41m"
YELLOW = "\033[1;33m"
GREEN = "\033[1;32m"
CYAN = "\033[36m"
GRAY = "\033[90m"

VALID_MODES = ("auto", "always", "never")
_MODE = "auto"

RE_WARN = re.compile(r"^(\[WARN\]|WARNING\s*:|WARN\s*:)(.*)$")
RE_OK = re.compile(r"^(\[OK\]|\[PASS\]|OK\s*:|SUCCESS\s*:)(.*)$")
RE_FAIL = re.compile(r"^(\[FAIL\]|FAIL\s*:)(.*)$")
RE_INFO = re.compile(r"^(\[INFO\]|INFO\s*:)(.*)$")
RE_DEBUG = re.compile(r"^(\[DEBUG\]|DEBUG\s*:)(.*)$")
RE_SKIP = re.compile(r"^(\[SKIP\]|SKIP\s*:)(.*)$")
RE_DRY = re.compile(r"^(\[DRY-RUN\])(.*)$")
RE_FATAL = re.compile(r"^(\[FATAL\]|FATAL\s*:)(.*)$")
RE_ANSI = re.compile(r"\033\[[0-9;]*m")


def init(mode=None):
    """Initialise the color mode from ``mode`` or $SCH_COLOR.

    Invalid environment values fall back to ``auto``; explicit invalid values
    are rejected by :func:`set_color`.
    """
    global _MODE
    if mode is None:
        mode = os.environ.get("SCH_COLOR", "auto")
    if mode not in VALID_MODES:
        mode = "auto"
    _MODE = mode
    os.environ["SCH_COLOR"] = mode
    return mode


def set_color(mode):
    """Force a mode and make it visible to child processes."""
    if mode not in VALID_MODES:
        return False
    init(mode)
    return True


def color_mode():
    return _MODE


def color_enabled(stream):
    """Return True when colours should be used for ``stream``."""
    if _MODE == "always":
        return True
    if _MODE == "never":
        return False
    isatty = getattr(stream, "isatty", None)
    if not callable(isatty) or not isatty():
        return False
    if os.environ.get("NO_COLOR", ""):
        return False
    if os.environ.get("CI", ""):
        return False
    if os.environ.get("TERM", "") == "dumb":
        return False
    return True


def strip(text):
    """Remove ANSI SGR sequences (used by tests and callers that re-parse)."""
    return RE_ANSI.sub("", text)


def _write(stream, color, text):
    # stderr is line-buffered while stdout is block-buffered when redirected;
    # flush stdout first so "cmd 2>&1" preserves ordering.
    try:
        sys.stdout.flush()
    except Exception:
        pass
    if color and color_enabled(stream):
        print("{}{}{}".format(color, text, RESET), file=stream, flush=True)
    else:
        print(text, file=stream, flush=True)


def _emit_label(stream, color, pattern, text):
    try:
        sys.stdout.flush()
    except Exception:
        pass
    if not color_enabled(stream):
        print(text, file=stream, flush=True)
        return
    match = pattern.match(text)
    if match:
        print(
            "{}{}{}{}".format(color, match.group(1), RESET, match.group(2)),
            file=stream,
            flush=True,
        )
    else:
        print(text, file=stream, flush=True)


def _emit_fatal(text):
    try:
        sys.stdout.flush()
    except Exception:
        pass
    if not color_enabled(sys.stderr):
        print(text, file=sys.stderr, flush=True)
        return
    match = RE_FATAL.match(text)
    if match:
        print(
            "{}{}{}{}{}{}".format(
                FATAL_LABEL, match.group(1), RESET, RED, match.group(2), RESET
            ),
            file=sys.stderr,
            flush=True,
        )
    else:
        print("{}{}{}".format(RED, text, RESET), file=sys.stderr, flush=True)


def _emit_dispatch(level, text, stream):
    if level == "FATAL":
        if stream is sys.stderr:
            _emit_fatal(text)
        else:
            _write(sys.stdout, RED, text)
    elif level == "ERROR":
        _write(stream, RED, text)
    elif level in ("WARN", "WARNING"):
        _emit_label(stream, YELLOW, RE_WARN, text)
    elif level in ("OK", "PASS", "SUCCESS"):
        _emit_label(stream, GREEN, RE_OK, text)
    elif level == "FAIL":
        _emit_label(stream, RED, RE_FAIL, text)
    elif level == "SKIP":
        _emit_label(stream, GRAY, RE_SKIP, text)
    elif level in ("DRY-RUN", "DRYRUN"):
        _emit_label(stream, CYAN, RE_DRY, text)
    elif level == "INFO":
        _emit_label(stream, CYAN, RE_INFO, text)
    elif level == "DEBUG":
        _emit_label(stream, GRAY, RE_DEBUG, text)
    else:
        print(text, file=stream, flush=True)


def emit(level, text):
    """Text-preserving emitter: colour existing labels without adding new ones.

    FATAL/ERROR/WARN go to stderr; the other levels go to stdout.
    """
    level = (level or "INFO").upper()
    stream = sys.stderr if level in ("FATAL", "ERROR", "WARN", "WARNING") else sys.stdout
    _emit_dispatch(level, text, stream)


def emit_out(level, text):
    """Same as :func:`emit`, but always writes to stdout.

    Use for report lines that keep their original stream (for example a
    dry-run plan's ``[ERROR]`` item).
    """
    _emit_dispatch((level or "INFO").upper(), text, sys.stdout)


def ok(message):
    emit("OK", "[OK] {}".format(message))


def info(message):
    _write(sys.stdout, CYAN, message)


def warn(message):
    emit("WARN", "WARNING: {}".format(message))


def error(message):
    emit("ERROR", "ERROR: {}".format(message))


def fatal(message):
    emit("FATAL", "FATAL: {}".format(message))


def debug(message):
    _write(sys.stdout, GRAY, message)


def header(message):
    _write(sys.stdout, BOLD, message)


def rule(text="=" * 60):
    _write(sys.stdout, GRAY, text)


def kv(label, value, width=10, indent=0):
    """Key/value line preserving the legacy "%-Ns: value" layout."""
    padded = "{:<{w}}".format(label, w=width)
    prefix = " " * indent
    try:
        sys.stdout.flush()
    except Exception:
        pass
    if color_enabled(sys.stdout):
        print(
            "{}{}{}{}: {}{}{}".format(prefix, BOLD, padded, RESET, CYAN, value, RESET),
            flush=True,
        )
    else:
        print("{}{}: {}".format(prefix, padded, value), flush=True)


def _step_text(step):
    if not color_enabled(sys.stdout):
        return step
    match = re.match(r"^(\S+)(.*)$", step)
    if match:
        first = match.group(1)
        if (
            first.startswith("desmond-")
            or first.startswith("scripts/")
            or ("/scripts/" in first and first.endswith(".sh"))
        ):
            return "{}{}{}{}".format(CYAN, first, RESET, match.group(2))
    return step


def next_steps(status, steps, footer=None):
    """Render a numbered "Next steps" block.

    ``status`` is a semantic label only; the renderer never adds or removes
    steps. With zero steps nothing is printed (not even the header).
    """
    _ = status
    steps = list(steps or [])
    footer = list(footer or [])
    if not steps:
        return
    header("Next steps:")
    for index, step in enumerate(steps, 1):
        try:
            sys.stdout.flush()
        except Exception:
            pass
        sys.stdout.write("  {}) ".format(index))
        sys.stdout.write(_step_text(step))
        sys.stdout.write("\n")
        sys.stdout.flush()
    for index, line in enumerate(footer):
        prefix = "     " if index == 0 else "      "
        _write(sys.stdout, GRAY, prefix + line)


def extract_color_arg(argv):
    """Strip --color from ``argv``; return the remaining arguments.

    Supports both "--color=always" and "--color always"; "--" stops parsing.
    Raises SystemExit(2) for a missing or invalid value.
    """
    remaining = []
    mode = None
    stop = False
    index = 0
    while index < len(argv):
        arg = argv[index]
        if stop:
            remaining.append(arg)
            index += 1
            continue
        if arg == "--":
            stop = True
            remaining.append(arg)
            index += 1
        elif arg.startswith("--color="):
            mode = arg.split("=", 1)[1]
            if mode not in VALID_MODES:
                _invalid_mode(mode)
            index += 1
        elif arg == "--color":
            if index + 1 >= len(argv):
                _invalid_mode("(missing)")
            mode = argv[index + 1]
            if mode not in VALID_MODES:
                _invalid_mode(mode)
            index += 2
        else:
            remaining.append(arg)
            index += 1
    if mode is not None:
        set_color(mode)
    else:
        init()
    return remaining


def _invalid_mode(value):
    print(
        "Invalid --color value: {} (use auto, always, or never)".format(value),
        file=sys.stderr,
        flush=True,
    )
    raise SystemExit(2)


init()
