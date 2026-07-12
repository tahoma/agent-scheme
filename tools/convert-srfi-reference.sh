#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Tahoma Toelkes

set -eu

usage() {
  cat <<'EOF'
Usage: tools/convert-srfi-reference.sh [--check] [HTML ...]

Convert vendored SRFI HTML snapshots to normalized GitHub-Flavored Markdown.
With no paths, converts every scheme/stdlib/reference/srfi-*/srfi-*.html file.
With --check, reports generated files that are absent or out of date.
EOF
}

check=false
case "${1-}" in
  --check)
    check=true
    shift
    ;;
  -h|--help)
    usage
    exit 0
    ;;
esac

for command_name in pandoc mdformat; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "convert-srfi-reference: required command not found: $command_name" >&2
    exit 1
  fi
done

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/consent-srfi-reference.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

convert_one() {
  source_path=$1
  case "$source_path" in
    scheme/stdlib/reference/srfi-*/srfi-*.html) ;;
    *)
      echo "convert-srfi-reference: unexpected source path: $source_path" >&2
      return 1
      ;;
  esac
  output_path=${source_path%.html}.md
  converted_path="$tmpdir/$(basename "${source_path%.html}").md"
  body_path="$tmpdir/$(basename "${source_path%.html}").body.md"
  trimmed_path="$tmpdir/$(basename "${source_path%.html}").trimmed.md"
  spdx_license='<!-- SPDX-'"License-Identifier: MIT -->"
  spdx_copyright='<!-- SPDX-'"FileCopyrightText: SRFI document authors -->"

  pandoc \
    --from=html \
    --to=gfm+raw_html \
    --wrap=none \
    "$source_path" \
    --output="$body_path"

  {
    echo "$spdx_license"
    echo "$spdx_copyright"
    echo
    cat "$body_path"
  } >"$converted_path"
  mdformat --wrap 80 "$converted_path"
  sed 's/[[:space:]]*$//' "$converted_path" >"$trimmed_path"
  mv "$trimmed_path" "$converted_path"

  for required_text in \
    "$spdx_license" \
    "$spdx_copyright" \
    'Permission is hereby granted'; do
    if ! grep -F "$required_text" "$converted_path" >/dev/null; then
      echo "convert-srfi-reference: missing required text in $output_path: $required_text" >&2
      return 1
    fi
  done

  if $check; then
    if ! test -f "$output_path" || ! cmp -s "$converted_path" "$output_path"; then
      echo "out of date: $output_path" >&2
      return 1
    fi
  else
    cp "$converted_path" "$output_path"
  fi
}

status=0
if test "$#" -gt 0; then
  for source_path do
    convert_one "$source_path" || status=1
  done
else
  found=false
  for source_path in scheme/stdlib/reference/srfi-*/srfi-*.html; do
    found=true
    convert_one "$source_path" || status=1
  done
  if ! $found; then
    echo "convert-srfi-reference: no SRFI HTML snapshots found" >&2
    status=1
  fi
fi

exit "$status"
