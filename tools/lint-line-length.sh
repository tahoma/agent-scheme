#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Tahoma Toelkes

# Keep checked-in Scheme source and Scheme test files within the repository's
# soft line limit. Fixture corpora deliberately use dense Scheme-readable
# records and need a separate format-aware pass before they join this gate.

set -eu

limit=${CONSENT_LINE_LENGTH_LIMIT:-120}
case "$limit" in
  ''|*[!0-9]*)
    printf '%s\n' "lint-line-length: CONSENT_LINE_LENGTH_LIMIT must be a positive integer." >&2
    exit 2 ;;
esac

if [ "$limit" -eq 0 ]; then
  printf '%s\n' "lint-line-length: CONSENT_LINE_LENGTH_LIMIT must be greater than zero." >&2
  exit 2
fi

violations=$(mktemp "${TMPDIR:-/tmp}/consent-line-length.XXXXXX")
trap 'rm -f "$violations"' EXIT HUP INT TERM

git ls-files -- scheme tests/scheme tools |
while IFS= read -r file; do
  case "$file" in
    *.sld|*.scm)
      awk -v limit="$limit" -v file="$file" '
        length($0) > limit {
          printf "%s:%d:%d: %s\n", file, FNR, length($0), $0
        }
      ' "$file"
      ;;
  esac
done > "$violations"

if [ -s "$violations" ]; then
  cat "$violations"
  printf 'lint-line-length: found lines longer than %s columns.\n' "$limit" >&2
  exit 1
fi

printf 'lint-line-length: Scheme source and test lines fit within %s columns.\n' "$limit"
