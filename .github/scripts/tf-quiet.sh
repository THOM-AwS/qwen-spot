#!/usr/bin/env bash
# Run terraform without leaking plan values into public workflow logs.
# Output goes to a private file; on failure only error lines are printed,
# with 12-digit account IDs and email addresses redacted.
set -uo pipefail

log=$(mktemp)
trap 'rm -f "$log"' EXIT

# Capture the status directly: after "if cmd; then ...; fi" $? is the status of
# the if statement (0), not of cmd, which silently turned failures into success.
status=0
terraform "$@" >"$log" 2>&1 || status=$?
if [ "$status" -eq 0 ]; then
  exit 0
fi

echo "::error::terraform $1 failed (exit $status); redacted error lines follow"
grep -E -A6 'Error|error:' "$log" \
  | sed -E \
      -e 's/[0-9]{12}/<acct>/g' \
      -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
  | head -n 200
exit "$status"
