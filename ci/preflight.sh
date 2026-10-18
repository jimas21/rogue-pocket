#!/usr/bin/env bash
# Fails fast, with a plain message, if any repo variable or secret is missing.
# Checks only that values are non-empty / well-formed. Never prints them.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$here/common.sh"

missing=()
for name in BUNDLE_ID TEAM_ID; do
  [ -n "${!name:-}" ] || missing+=("variable $name (Settings > Secrets and variables > Actions > Variables)")
done
for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8; do
  [ -n "${!name:-}" ] || missing+=("secret $name (Settings > Secrets and variables > Actions > Secrets)")
done
if [ "${#missing[@]}" -gt 0 ]; then
  printf '::error::Missing %s\n' "${missing[@]}" >&2
  die "Set the items above, then re-run the workflow (Actions > TestFlight > Run workflow)."
fi

case "$BUNDLE_ID" in
  *REPLACE*) die "BUNDLE_ID still contains the REPLACE placeholder. Set the repo variable to the bundle ID you registered at developer.apple.com." ;;
esac
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$BUNDLE_ID" == *.* ]] \
  || die "BUNDLE_ID is not a valid reverse-DNS bundle ID (letters, digits, dots, hyphens; at least one dot)."
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
  || die "TEAM_ID must be the 10-character Team ID from developer.apple.com > Membership details."

echo "Preflight OK: all five settings present and well-formed (values not printed)."
