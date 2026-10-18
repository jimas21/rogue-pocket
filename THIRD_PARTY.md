# Third-party code

## mGBA

- What: the Game Boy Advance emulator core, linked into the app as a static library (libmgba).
- By: Jeffrey Pfau and the mGBA contributors. https://mgba.io, https://github.com/mgba-emu/mgba
- License: Mozilla Public License 2.0 (https://www.mozilla.org/MPL/2.0/). It is file-level copyleft: the source
  of the mGBA files, and of any changes made to them, must stay available to people who receive the app.
- Which source: the exact commit is pinned in `ci/build_mgba.sh` (`MGBA_REF`) and fetched from the upstream
  repository at build time. Nothing from mGBA is copied into this repository.
- Our changes to mGBA's files: two lines of its top-level `CMakeLists.txt` get an `NOT IOS` guard so it can be
  cross-built for iOS (the macOS deployment-target override and the forced `-flto`). `ci/mgba_patch.py` applies
  them to the build tree and is the complete record. No mGBA source file is otherwise modified.
- The Swift and C code in `RoguePocket/` is separate work that calls mGBA through its public C API; it is not
  part of mGBA.

This note is a good-faith summary, not legal advice. The upstream license text is saved next to the built library
at `Vendor/mgba-dist/LICENSE-mGBA.txt` during every build.

No game ROM, BIOS, save file or other copyrighted game data is part of this repository or the app. The app loads
a ROM that the user supplies on the device.
