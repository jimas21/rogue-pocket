#!/usr/bin/env bash
# Always runs at the end of the job: removes the API key file.
set -u
if [ -n "${ASC_KEY_PATH:-}" ]; then
  rm -f "$ASC_KEY_PATH" "$ASC_KEY_PATH.dec"
  echo "Removed temp API key file."
else
  echo "No temp API key file to remove."
fi
