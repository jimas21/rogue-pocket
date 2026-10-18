#!/usr/bin/env bash
# Builds libmgba (https://github.com/mgba-emu/mgba, MPL-2.0) for iOS devices (arm64) and lays it out as
#
#   Vendor/mgba-dist/lib/libmgba.a
#   Vendor/mgba-dist/include/{mgba,mgba-util}/...   (public + internal headers)
#   Vendor/mgba-dist/include/mgba/flags.h           (generated, extended with the real compile defines)
#
# project.yml points HEADER_SEARCH_PATHS / LIBRARY_SEARCH_PATHS at Vendor/mgba-dist, so run this before
# xcodegen/xcodebuild. Needs: macOS, Xcode command line tools, cmake, python3, git (all on the macos-26 runner).
#
#   MGBA_REF      commit to build (full 40-char SHA; default is the one the code was written against)
#   MGBA_REPO     where to fetch from
#   IOS_MIN       iOS deployment target for the library (keep <= project.yml's deploymentTarget)
#   MGBA_LIBONLY  set to 1 to add -DLIBMGBA_ONLY=ON (mGBA's own "embedded in another project" mode); a fallback
#                 if the explicit flag list below ever stops configuring on a newer mGBA
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$here/common.sh"
cd "$here/.."

MGBA_REPO="${MGBA_REPO:-https://github.com/mgba-emu/mgba.git}"
# mgba-emu/mgba master on 2026-10-17 (version.cmake says 0.11.0, unreleased; there is no 0.11 tag yet). Master, not
# the 0.10.5 release, because rp_core.c uses the newer audio API (mAudioBuffer; 0.10.x has blip_t channels instead).
# Also checked on a desktop build against rp_core.c: cc94070a8910ecb8c1d10c515e913a4599223a31 (master 2026-08-19,
# the commit Tinbox pins), a known-good older fallback.
MGBA_REF="${MGBA_REF:-9660a668f2093cb4aba5983f52bebf8878dc5b8b}"
IOS_MIN="${IOS_MIN:-17.0}"

VENDOR=Vendor
SRC="$VENDOR/mgba"
BUILD="$VENDOR/build"
DIST="$VENDOR/mgba-dist"

[[ "$MGBA_REF" =~ ^[0-9a-f]{40}$ ]] || die "MGBA_REF must be a full 40-character commit SHA (got '$MGBA_REF'); GitHub will not fetch an abbreviated one."

# ---- cache key: rebuild only if the ref, this script, the patch or the defs script changed -------------
stamp="$(printf '%s\n%s\n%s\n' "$MGBA_REF" "$IOS_MIN" "${MGBA_LIBONLY:-0}"; cat "$here/build_mgba.sh" "$here/mgba_patch.py" "$here/mgba_defs.py")"
stamp="$(printf '%s' "$stamp" | shasum -a 256 | cut -d' ' -f1)"
if [ -f "$DIST/lib/libmgba.a" ] && [ -f "$DIST/include/mgba/flags.h" ] && [ "$(cat "$DIST/STAMP" 2>/dev/null || true)" = "$stamp" ]; then
  echo "libmgba already built for this ref and recipe (stamp ${stamp:0:12}); skipping."
  exit 0
fi

command -v git >/dev/null || die "git not found"
command -v python3 >/dev/null || die "python3 not found"
command -v xcrun >/dev/null || die "xcrun not found (this must run on macOS with Xcode)"
if ! command -v cmake >/dev/null; then
  echo "cmake not found; installing with Homebrew."
  brew install cmake
fi
echo "cmake: $(cmake --version | head -n 1)"
GEN=()
if command -v ninja >/dev/null; then GEN=(-G Ninja); fi

# ---- fetch the pinned commit -------------------------------------------------------------------------------
rm -rf "$BUILD" "$DIST"
if [ -d "$SRC/.git" ] && [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)" != "$MGBA_REF" ]; then
  echo "Existing checkout is not $MGBA_REF; refetching."
  rm -rf "$SRC"
fi
if [ ! -d "$SRC/.git" ]; then
  echo "Fetching mGBA $MGBA_REF"
  mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" remote add origin "$MGBA_REPO"
  git -C "$SRC" fetch -q --depth 1 origin "$MGBA_REF" \
    || die "Could not fetch $MGBA_REF from $MGBA_REPO. Is the SHA right, and is GitHub reachable?"
  git -C "$SRC" checkout -q FETCH_HEAD
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$MGBA_REF" ] || die "Checked-out mGBA is not $MGBA_REF."
echo "mGBA revision: $(git -C "$SRC" rev-parse HEAD)"

python3 "$here/mgba_patch.py" "$SRC"

# ---- configure ---------------------------------------------------------------------------------------------
# GBA core only, static, no frontends, no optional dependencies (no zlib/png/zip/lua/sqlite/ffmpeg/...), no
# debugger (ENABLE_DEBUGGERS changes struct mCore's layout, so it is off here AND forbidden by mgba_defs.py).
# DISABLE_DEPS=ON additionally forces zlib/PNG off, so nothing from Homebrew can leak into an iOS binary.
# .zip ROMs are therefore not supported; the ROM is loaded as a plain .gba.
CMAKE_FLAGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_OSX_SYSROOT=iphoneos
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN"
  -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
  -DBUILD_STATIC=ON -DBUILD_SHARED=OFF
  -DDISABLE_DEPS=ON
  -DM_CORE_GBA=ON -DM_CORE_GB=OFF
  -DBUILD_QT=OFF -DBUILD_SDL=OFF -DBUILD_LIBRETRO=OFF -DBUILD_GL=OFF -DBUILD_GLES2=OFF -DBUILD_GLES3=OFF
  -DBUILD_TEST=OFF -DBUILD_SUITE=OFF -DBUILD_PERF=OFF -DBUILD_HEADLESS=OFF -DBUILD_EXAMPLE=OFF -DBUILD_CINEMA=OFF
  -DENABLE_DEBUGGERS=OFF -DENABLE_GDB_STUB=OFF -DENABLE_SCRIPTING=OFF
  -DUSE_EDITLINE=OFF -DUSE_EPOXY=OFF -DUSE_FFMPEG=OFF -DUSE_LIBZIP=OFF -DUSE_MINIZIP=OFF -DUSE_SQLITE3=OFF
  -DUSE_ELF=OFF -DUSE_LUA=OFF -DUSE_JSON_C=OFF -DUSE_FREETYPE=OFF -DUSE_LZMA=OFF -DUSE_DISCORD_RPC=OFF
  -DUSE_ZLIB=OFF -DUSE_PNG=OFF
  -DSKIP_INSTALL_ALL=ON
)
if [ "${MGBA_LIBONLY:-0}" = "1" ]; then CMAKE_FLAGS+=(-DLIBMGBA_ONLY=ON); fi

export PKG_CONFIG_LIBDIR=/nonexistent # never pick up Homebrew libraries for an iOS binary

hints() {
  cat >&2 <<'MSG'

Likely causes, in order:
  1. mGBA's CMake changed (a new Apple-specific line, a renamed option). Read the first error above. If it is
     about a feature or dependency, try MGBA_LIBONLY=1 (mGBA's embedded mode). If ci/mgba_patch.py failed, update it.
  2. A compile error in an mGBA source file on the newer Xcode: pin the older known-good MGBA_REF
     cc94070a8910ecb8c1d10c515e913a4599223a31 (edit it in this file; both commits compile against rp_core.c on a
     desktop). Do not go back to the 0.10.5 tag: its audio API differs and rp_core.c would not compile.
  3. The runner image changed (cmake version, Xcode). The log prints both at the top.
MSG
}
trap hints ERR

echo "==> Configuring libmgba for iOS arm64 (deployment target $IOS_MIN)"
cmake -S "$SRC" -B "$BUILD" ${GEN[@]+"${GEN[@]}"} "${CMAKE_FLAGS[@]}"

echo "==> Building libmgba"
cmake --build "$BUILD" --target mgba --parallel
trap - ERR

lib="$(find "$BUILD" -name 'libmgba.a' -type f | head -n 1)"
[ -n "$lib" ] || die "Build finished but libmgba.a was not found under $BUILD."

# ---- sanity-check the binary --------------------------------------------------------------------------------
archs="$(xcrun lipo -archs "$lib")"
[ "$archs" = "arm64" ] || die "libmgba.a has architectures '$archs', expected exactly 'arm64'."
# (nm output goes into a variable first: `nm | grep -q` can SIGPIPE nm and fail under pipefail.)
syms="$(xcrun nm -g "$lib" 2>/dev/null || true)"
for sym in _mCoreFind _mCoreLoadFile _mCoreLoadSaveFile _mCoreInitConfig _mCoreConfigSetIntValue _GBACoreCreate _GBASavedataSize; do
  grep -q " T $sym\$" <<<"$syms" || die "libmgba.a does not define $sym. Is it an LTO (bitcode) archive? mgba_patch.py should have removed -flto."
done
# Only symbols the archive references but never defines can be outside dependencies: without zlib, mGBA builds
# its own crc32 (src/util/crc32.c), so "U _crc32" in one object is resolved by "T _crc32" in another.
defined="$(awk '$2 ~ /^[TDSBCRVW]$/ {print $3}' <<<"$syms" | sort -u)"
undefined="$(awk '$1 == "U" {print $2}' <<<"$syms" | sort -u)"
external="$(comm -23 <(printf '%s
' "$undefined") <(printf '%s
' "$defined"))"
deps="$(grep -E '^_(crc32|adler32|inflate|deflate|png_)' <<<"$external" || true)"
if [ -n "$deps" ]; then
  echo "$deps" | head -n 10 >&2
  die "libmgba.a needs zlib/libpng symbols (above), but the app does not link them; DISABLE_DEPS did not take effect."
fi
echo "libmgba.a: arm64, core symbols present, no zlib/png references. Size: $(du -h "$lib" | cut -f1)"

# ---- lay out the dist --------------------------------------------------------------------------------------
mkdir -p "$DIST/lib" "$DIST/include"
cp "$lib" "$DIST/lib/libmgba.a"
cp -R "$SRC/include/mgba" "$SRC/include/mgba-util" "$DIST/include/"
cp "$BUILD/include/mgba/flags.h" "$DIST/include/mgba/flags.h"
cp "$SRC/LICENSE" "$DIST/LICENSE-mGBA.txt"
python3 "$here/mgba_defs.py" "$BUILD" "$DIST/include"

{
  echo "mGBA commit: $(git -C "$SRC" rev-parse HEAD)"
  echo "iOS deployment target: $IOS_MIN"
  echo "Xcode: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
} > "$DIST/BUILD-INFO.txt"
printf '%s' "$stamp" > "$DIST/STAMP"
echo "==> libmgba ready in $DIST"
