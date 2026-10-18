#!/usr/bin/env bash
# Compiles the whole app UNSIGNED: builds libmgba, generates the Xcode project, builds Swift + the C shim for
# a generic iOS device and links libmgba in. Needs no Apple account, key or secret, so it can run before
# enrollment finishes and on every push. It proves the code compiles and links; it does not produce
# anything installable (that is the TestFlight workflow's job).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$here/common.sh"
cd "$here/.."

bash ci/build_mgba.sh

mkdir -p build
xcodegen generate

hints() {
  echo "::error::Unsigned build failed. Compiler errors from build/check.log:" >&2
  grep -E 'error:|fatal error|ld: |Undefined symbols|BUILD FAILED' build/check.log | head -n 40 >&2 || true
  cat >&2 <<'MSG'

Likely causes, in order:
  1. A Swift compile error (first "error:" line above names the file and line). This code was written without
     being able to compile it, so the first real build may need small fixes.
  2. "mgba/flags.h file not found" or an #error from rp_core.c: Vendor/mgba-dist is missing or stale. Re-run
     ci/build_mgba.sh (the earlier step prints why it failed).
  3. "Undefined symbols ... _mCore..." at link time: libmgba.a lacks that symbol or was built for another
     architecture. ci/build_mgba.sh checks both; read its output.
MSG
}
trap hints ERR

xcodebuild \
  -project RoguePocket.xcodeproj \
  -scheme RoguePocket \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  PRODUCT_BUNDLE_IDENTIFIER=org.example.roguepocket.ci \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" \
  build 2>&1 | tee build/check.log

trap - ERR

app="$(find build/DerivedData -name 'RoguePocket.app' -type d | head -n 1)"
[ -n "$app" ] || die "xcodebuild reported success but RoguePocket.app was not found."
exe="$app/RoguePocket"
[ -f "$exe" ] || die "RoguePocket.app has no RoguePocket executable."
# nm output goes into a variable first (nm | grep -q can SIGPIPE under pipefail).
syms="$(xcrun nm "$exe" 2>/dev/null || true)"
if grep -q ' _main$' <<<"$syms"; then
  for sym in _rp_open _rp_read_memory _mCoreFind _GBACoreCreate; do
    grep -q " [TtSs] $sym\$" <<<"$syms" || die "The linked executable does not contain $sym; libmgba or the shim was not linked in."
  done
else
  echo "::warning::The executable's symbol table is stripped, so the libmgba link check was skipped (the build itself linked)."
fi
echo "Unsigned build OK: $(du -h "$exe" | cut -f1) executable."
