#!/usr/bin/env bash
# Generates the Xcode project and archives it unsigned. Signing happens once, at export, with Apple's
# cloud-managed distribution certificate. (Signing the archive made a new development certificate on
# every fresh runner, and the account's certificate limit filled up.)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$here/common.sh"
cd "$here/.."

for name in BUNDLE_ID TEAM_ID ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID GITHUB_RUN_NUMBER; do
  [ -n "${!name:-}" ] || die "$name is not set"
done
asc_auth_flags
mkdir -p build

hints() {
  echo "::error::Archive failed. Last error lines from build/archive.log:" >&2
  grep -E 'error:|ARCHIVE FAILED|Cloud signing|No Accounts|No profiles|provisioning' build/archive.log | tail -n 25 >&2 || true
  cat >&2 <<'MSG'

Likely causes, in order:
  1. The API key's Access is not Admin ("Cloud signing permission error"). Make a new Team Key with Admin access.
  2. The bundle ID is not registered, or BUNDLE_ID differs from the registered one.
  3. TEAM_ID is wrong (must match the team that owns the bundle ID and the key).
  4. A pending agreement: the Account Holder must accept it under Business in App Store Connect.
  5. A network blip that looks like an auth error ("No Accounts with App Store Connect Access"): re-run.
MSG
}
trap hints ERR

echo "Build number: $GITHUB_RUN_NUMBER"
xcodegen generate

xcodebuild \
  -project RoguePocket.xcodeproj \
  -scheme RoguePocket \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/RoguePocket.xcarchive \
  "${ASC_AUTH[@]}" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGNING_ALLOWED=NO \
  CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER" \
  archive 2>&1 | tee build/archive.log

trap - ERR
test -d build/RoguePocket.xcarchive || die "xcodebuild reported success but build/RoguePocket.xcarchive is missing."
echo "Archive OK."
