# Third-party code

## mGBA

Game Boy Advance emulator by Jeffrey Pfau and contributors — https://mgba.io, https://github.com/mgba-emu/mgba

Licensed under the [Mozilla Public License 2.0](https://www.mozilla.org/MPL/2.0/). Built from the commit pinned in
`ci/build_mgba.sh` and linked as a static library. The only change to mGBA's files is in `ci/mgba_patch.py`: two
lines of its `CMakeLists.txt` are skipped for iOS builds.
