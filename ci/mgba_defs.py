#!/usr/bin/env python3
"""Makes mGBA's generated flags.h describe the library that was ACTUALLY compiled.

usage: mgba_defs.py <cmake-build-dir> <dist-include-dir>

Why: `struct mCore` (include/mgba/core/core.h) changes layout with ENABLE_VFS, ENABLE_DIRECTORIES,
ENABLE_DEBUGGERS and MINIMAL_CORE. The app compiles rp_core.c against these headers, so it must see the same
definitions the library saw. mGBA's flags.h is generated from CMake *variables* only, and some of the
definitions (ENABLE_DIRECTORIES, USE_*, ENABLE_VFS_FD, ...) are added straight to COMPILE_DEFINITIONS and
never reach flags.h. So this script reads the real -D list for src/core/core.c out of compile_commands.json
(configure with -DCMAKE_EXPORT_COMPILE_COMMANDS=ON) and appends it to <dist-include-dir>/mgba/flags.h as
`#ifndef X / #define X` pairs. rp_core.c also has #error guards for the important ones.

Then it checks the result and exits non-zero, with a clear message, if the library is not the shape the app
expects (GBA core present, VFS+directories on, debuggers off, 32-bit colour).
"""
import json
import re
import sys
from pathlib import Path

# Only definitions that can affect a header's contents are copied; compiler plumbing is not.
KEEP = re.compile(r"^(ENABLE_|USE_|M_CORE_|MINIMAL_CORE$|COLOR_|DISABLE_|FIXED_ROM_BUFFER$|HAVE_)")
REQUIRED = ["M_CORE_GBA", "ENABLE_VFS", "ENABLE_DIRECTORIES"]
FORBIDDEN = ["ENABLE_DEBUGGERS", "MINIMAL_CORE", "COLOR_16_BIT"]
MARK = "Added by ci/mgba_defs.py"


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    build = Path(sys.argv[1])
    flags_h = Path(sys.argv[2]) / "mgba" / "flags.h"
    db_path = build / "compile_commands.json"
    for p in (db_path, flags_h):
        if not p.is_file():
            print(f"::error::mgba_defs: {p} not found.", file=sys.stderr)
            return 1

    entries = json.loads(db_path.read_text(encoding="utf-8"))
    entry = next((e for e in entries if e["file"].replace("\\", "/").endswith("src/core/core.c")), None)
    if entry is None:
        print("::error::mgba_defs: src/core/core.c is not in compile_commands.json; did the library build?", file=sys.stderr)
        return 1
    command = entry.get("command") or " ".join(entry["arguments"])

    defs = []
    for name, value in re.findall(r"(?:^|\s)-D([A-Za-z_][A-Za-z0-9_]*)(?:=(\S+))?", command):
        if KEEP.match(name) and (name, value) not in defs:
            defs.append((name, value))

    text = flags_h.read_text(encoding="utf-8")
    if MARK in text:
        print("mgba_defs: flags.h already extended")
    else:
        block = [f"// ---- {MARK}: the definitions libmgba was really compiled with.", ""]
        for name, value in defs:
            block += [f"#ifndef {name}", f"#define {name}{(' ' + value) if value else ''}", "#endif", ""]
        end = text.rstrip().rfind("#endif")
        if end < 0:
            print("::error::mgba_defs: flags.h has no closing #endif; its format changed.", file=sys.stderr)
            return 1
        text = text[:end] + "\n".join(block) + "\n" + text[end:]
        flags_h.write_text(text, encoding="utf-8", newline="\n")

    final = {m.group(1) for m in re.finditer(r"^\s*#\s*define\s+([A-Za-z_][A-Za-z0-9_]*)", text, re.M)}
    final |= {n for n, _ in defs}
    problems = [f"missing {n}" for n in REQUIRED if n not in final]
    problems += [f"unexpected {n}" for n in FORBIDDEN if n in final]
    print("mgba_defs: libmgba compile definitions that matter to headers:")
    for name, value in defs:
        print(f"    {name}{('=' + value) if value else ''}")
    if problems:
        print(
            "::error::mgba_defs: libmgba was not built in the shape the app expects ("
            + ", ".join(problems)
            + "). Check the cmake flags in ci/build_mgba.sh.",
            file=sys.stderr,
        )
        return 1
    print("mgba_defs: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
