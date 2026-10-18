#!/usr/bin/env bash
# Shared helpers, sourced by the other ci/*.sh scripts. Never prints secret values.

die() {
  echo "::error::$*" >&2
  exit 1
}

# App Store Connect API authentication flags for xcodebuild. Both archive and
# -exportArchive get them (a 2024 forum report has export failing with
# "no profile found" when only archive had them).
# Needs ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID in the environment.
asc_auth_flags() {
  ASC_AUTH=(
    -allowProvisioningUpdates
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
}
