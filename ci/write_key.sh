#!/usr/bin/env bash
# Writes the App Store Connect API key (.p8) from the ASC_KEY_P8 secret to a temp
# file and exports its path as ASC_KEY_PATH for later steps. Never echoes the key.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$here/common.sh"

: "${ASC_KEY_P8:?ASC_KEY_P8 is empty}"
: "${ASC_KEY_ID:?ASC_KEY_ID is empty}"
: "${RUNNER_TEMP:?RUNNER_TEMP is not set}"
: "${GITHUB_ENV:?GITHUB_ENV is not set}"

umask 077
key_path="$RUNNER_TEMP/AuthKey_${ASC_KEY_ID}.p8"
printf '%s\n' "$ASC_KEY_P8" > "$key_path"

# Tolerate a base64-encoded paste as well as the raw PEM text.
if ! grep -q 'BEGIN PRIVATE KEY' "$key_path"; then
  if printf '%s' "$ASC_KEY_P8" | base64 -d > "$key_path.dec" 2>/dev/null && grep -q 'BEGIN PRIVATE KEY' "$key_path.dec"; then
    mv "$key_path.dec" "$key_path"
  else
    rm -f "$key_path" "$key_path.dec"
    die "ASC_KEY_P8 does not look like a .p8 file. Paste the whole file contents, including the BEGIN PRIVATE KEY and END PRIVATE KEY lines."
  fi
fi

# Parses the key without printing it. Catches pastes that lost their line breaks.
if ! openssl pkey -in "$key_path" -noout 2>/dev/null; then
  rm -f "$key_path"
  die "ASC_KEY_P8 is not a readable private key. Re-paste the .p8 file contents with its line breaks intact."
fi

echo "ASC_KEY_PATH=$key_path" >> "$GITHUB_ENV"
echo "API key written to a temp file (removed at the end of the job)."
