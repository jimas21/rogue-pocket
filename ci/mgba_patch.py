#!/usr/bin/env python3
"""Patches mGBA's CMakeLists.txt so it can be cross-built for iOS.

usage: mgba_patch.py <path-to-mgba-checkout>

mGBA's top-level CMakeLists.txt has two lines meant for macOS desktop builds that break an iOS build:

  1. `if(NOT CMAKE_SYSTEM_VERSION VERSION_LESS "10.0")` then forces CMAKE_OSX_DEPLOYMENT_TARGET to 10.6
     (an iOS build would target macOS 10.6 and fail).
  2. `if(APPLE OR ...)` appends -flto to the release flags (the resulting .a only links with the exact
     clang that built it).

Both get an `NOT IOS` guard. This is the same two-line change Tinbox's Scripts/mgba-ios.patch makes; it is
done here by exact-string replacement (no `git apply`, so no whitespace or line-ending fragility) and it
FAILS LOUDLY if mGBA's text has moved, rather than silently building a broken library.

mGBA is MPL-2.0 (file-level copyleft): this script is the complete record of how we modify its files, and
this repository is public. The only modified mGBA file is CMakeLists.txt, in the build tree only.

Idempotent: running it twice is fine.
"""
import re
import sys
from pathlib import Path

EDITS = [
    (
        "deployment target",
        re.compile(r'if\(NOT CMAKE_SYSTEM_VERSION VERSION_LESS "10\.0"\)'),
        'if(NOT IOS AND NOT CMAKE_SYSTEM_VERSION VERSION_LESS "10.0")',
        'if(NOT IOS AND NOT CMAKE_SYSTEM_VERSION VERSION_LESS "10.0")',
    ),
    (
        "-flto",
        re.compile(r'if\(APPLE OR CMAKE_C_COMPILER_ID STREQUAL "GNU" AND BUILD_LTO\)'),
        'if((APPLE AND NOT IOS) OR CMAKE_C_COMPILER_ID STREQUAL "GNU" AND BUILD_LTO)',
        'if((APPLE AND NOT IOS) OR CMAKE_C_COMPILER_ID STREQUAL "GNU" AND BUILD_LTO)',
    ),
]


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    path = Path(sys.argv[1]) / "CMakeLists.txt"
    if not path.is_file():
        print(f"::error::{path} not found. Is the mGBA checkout in the right place?", file=sys.stderr)
        return 1
    text = path.read_bytes().decode("utf-8")  # bytes in, bytes out: line endings are preserved
    changed = False
    for name, pattern, replacement, already in EDITS:
        if already in text:
            print(f"mgba_patch: {name}: already patched")
            continue
        text, count = pattern.subn(replacement, text)
        if count != 1:
            print(
                f"::error::mgba_patch: expected exactly one match for the '{name}' line in {path}, found {count}. "
                "mGBA's CMakeLists.txt has changed since this script was written; look at the Apple section "
                "(search for CMAKE_OSX_DEPLOYMENT_TARGET and -flto) and update ci/mgba_patch.py.",
                file=sys.stderr,
            )
            return 1
        print(f"mgba_patch: {name}: patched")
        changed = True
    if changed:
        path.write_bytes(text.encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
