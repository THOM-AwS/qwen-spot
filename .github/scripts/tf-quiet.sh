#!/usr/bin/env bash
# Run terraform without leaking plan values into public workflow logs.
# Output goes to a private file; on failure only error lines are printed,
# with 12-digit account IDs and email addresses redacted.
set -uo pipefail

log=$(mktemp)
trap 'rm -f "$log"' EXIT

if terraform "$@" >"$log" 2>&1; then
  exit 0
fi
status=$?

echo "::error::terraform $1 failed (exit $status); redacted error lines follow"
grep -E -A6 'Error|error:' "$log" \
  | sed -E \
      -e 's/[0-9]{12}/<acct>/g' \
      -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
  | head -n 200
exit "$status"
