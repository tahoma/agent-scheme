#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Tahoma Toelkes

set -eu

soft_limit=${CONSENT_READABILITY_SOFT_LIMIT:-80}
hard_limit=${CONSENT_READABILITY_HARD_LIMIT:-100}
repository_root=${CONSENT_READABILITY_ROOT:-$(git rev-parse --show-toplevel)}
exclusions_file=${CONSENT_READABILITY_EXCLUSIONS:-tools/readability-exclusions.txt}
file_list=${CONSENT_READABILITY_FILE_LIST:-}

fail_usage() {
  printf 'lint-readability: %s\n' "$1" >&2
  exit 2
}

case "$soft_limit" in
  ''|*[!0-9]*) fail_usage "width limits must be positive integers" ;;
esac
case "$hard_limit" in
  ''|*[!0-9]*) fail_usage "width limits must be positive integers" ;;
esac
if [ "$soft_limit" -eq 0 ] || [ "$hard_limit" -le "$soft_limit" ]; then
  fail_usage "the hard limit must be greater than the nonzero soft limit"
fi

is_covered_file() {
  case "$1" in
    Makefile|*.el|*.scm|*.sld|*.sh|*.yml|*.yaml) return 0 ;;
    tools/consent-native-cli|tools/consent-repl) return 0 ;;
    *) return 1 ;;
  esac
}

is_first_party_path() {
  case "$1" in
    scheme/*|lisp/*|tests/*|fixtures/*|tools/*|.github/workflows/*|Makefile)
      return 0 ;;
    *) return 1 ;;
  esac
}

validate_exclusions() {
  [ -f "$repository_root/$exclusions_file" ] ||
    fail_usage "missing exclusions file $exclusions_file"
  awk -F '|' '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    NF != 4 || $1 !~ /\/$/ || $2 !~ /^vendored-(byte-exact|verbatim)$/ ||
      length($3) == 0 || length($4) < 20 {
        printf "%s:%d: invalid provenance exclusion\n", FILENAME, FNR > "/dev/stderr"
        failed = 1
      }
    END { exit failed }
  ' "$repository_root/$exclusions_file" || exit 1
}

is_excluded() {
  awk -F '|' -v candidate="$1" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    index(candidate, $1) == 1 { found = 1 }
    END { exit !found }
  ' "$repository_root/$exclusions_file"
}

make_file_list() {
  if [ -n "$file_list" ]; then
    sed '/^[[:space:]]*$/d' "$file_list"
  else
    git -C "$repository_root" ls-files -- \
      scheme lisp tests fixtures tools .github/workflows Makefile
  fi
}

check_file() {
  checked_file=$1
  awk -v file="$checked_file" -v soft="$soft_limit" -v hard="$hard_limit" '
    function marker(line) {
      return line ~ /readability-allow: (contiguous-datum|external-identifier|exact-text) -- .{12,}/
    }
    {
      width = length($0)
      if (marker(previous) && width <= soft) {
        printf "%s:%d:%d: stale soft-limit exception\n", file, FNR - 1,
          length(previous)
        failed = 1
      }
      if (width > hard) {
        printf "%s:%d:%d: hard-limit>%d\n", file, FNR, width, hard
        hard_count++
        failed = 1
      } else if (width > soft) {
        soft_count++
        if (!marker(previous)) {
          printf "%s:%d:%d: unclassified-soft-limit>%d\n", file, FNR,
            width, soft
          failed = 1
        } else {
          allowed_count++
        }
      }
      previous = $0
    }
    END {
      if (marker(previous)) {
        printf "%s:%d:%d: stale soft-limit exception\n", file, FNR,
          length(previous)
        failed = 1
      }
      printf "%d %d %d\n", soft_count + 0, hard_count + 0,
        allowed_count + 0 >> metrics
      exit failed
    }
  ' metrics="$metrics_file" "$repository_root/$checked_file"
}

run_repository_check() {
  validate_exclusions
  findings_file=$(mktemp "${TMPDIR:-/tmp}/consent-readability-findings.XXXXXX")
  metrics_file=$(mktemp "${TMPDIR:-/tmp}/consent-readability-metrics.XXXXXX")
  listed_file=$(mktemp "${TMPDIR:-/tmp}/consent-readability-files.XXXXXX")
  trap 'rm -f "$findings_file" "$metrics_file" "$listed_file"' EXIT HUP INT TERM
  make_file_list > "$listed_file"

  failed=0
  checked=0
  excluded=0
  while IFS= read -r checked_file; do
    is_first_party_path "$checked_file" || continue
    is_covered_file "$checked_file" || continue
    if is_excluded "$checked_file"; then
      excluded=$((excluded + 1))
      continue
    fi
    checked=$((checked + 1))
    check_file "$checked_file" >> "$findings_file" || failed=1
  done < "$listed_file"

  cat "$findings_file"
  set -- $(awk '{soft += $1; hard += $2; allowed += $3}
    END {print soft + 0, hard + 0, allowed + 0}' "$metrics_file")
  repository_soft=$1
  repository_hard=$2
  allowed_soft=$3

  changed_soft=0
  changed_hard=0
  if [ "${CONSENT_READABILITY_SKIP_CHANGED:-0}" != 1 ] &&
     git -C "$repository_root" rev-parse --verify origin/main >/dev/null 2>&1; then
    set -- $(git -C "$repository_root" diff --no-ext-diff --unified=0 \
      origin/main -- scheme lisp tests fixtures tools .github/workflows Makefile |
      awk -v soft="$soft_limit" -v hard="$hard_limit" '
        /^\+\+\+/ { next }
        /^\+/ {
          width = length(substr($0, 2))
          if (width > soft) changed_soft++
          if (width > hard) changed_hard++
        }
        END { print changed_soft + 0, changed_hard + 0 }
      ')
    changed_soft=$1
    changed_hard=$2
  fi

  printf '%s\n' \
    "lint-readability: checked=$checked excluded=$excluded repository>80=$repository_soft repository>100=$repository_hard allowed-soft=$allowed_soft changed>80=$changed_soft changed>100=$changed_hard"
  [ "$failed" -eq 0 ] || exit 1
}

run_self_test() {
  self_root=$(mktemp -d "${TMPDIR:-/tmp}/consent-readability-test.XXXXXX")
  trap 'rm -rf "$self_root"' EXIT HUP INT TERM
  mkdir -p "$self_root/tools" "$self_root/.github/workflows"
  : > "$self_root/tools/readability-exclusions.txt"
  classes='Makefile lisp/sample.el fixtures/sample.scm scheme/sample.sld tools/sample.sh .github/workflows/sample.yml .github/workflows/sample.yaml tools/consent-repl'
  for sample in $classes; do
    sample_path="$self_root/$sample"
    mkdir -p "$(dirname "$sample_path")"
    printf 'short\n' > "$sample_path"
    printf '%s\n' "$sample" > "$self_root/files"
    CONSENT_READABILITY_ROOT="$self_root" \
      CONSENT_READABILITY_FILE_LIST="$self_root/files" \
      CONSENT_READABILITY_EXCLUSIONS=tools/readability-exclusions.txt \
      CONSENT_READABILITY_SKIP_CHANGED=1 "$0" >/dev/null
    awk 'BEGIN { for (i = 0; i < 101; i++) printf "x"; printf "\n" }' > "$sample_path"
    if CONSENT_READABILITY_ROOT="$self_root" \
       CONSENT_READABILITY_FILE_LIST="$self_root/files" \
       CONSENT_READABILITY_EXCLUSIONS=tools/readability-exclusions.txt \
       CONSENT_READABILITY_SKIP_CHANGED=1 "$0" >/dev/null 2>&1; then
      fail_usage "$sample did not reject a hard-limit violation"
    fi
    awk 'BEGIN { for (i = 0; i < 81; i++) printf "x"; printf "\n" }' > "$sample_path"
    if CONSENT_READABILITY_ROOT="$self_root" \
       CONSENT_READABILITY_FILE_LIST="$self_root/files" \
       CONSENT_READABILITY_EXCLUSIONS=tools/readability-exclusions.txt \
       CONSENT_READABILITY_SKIP_CHANGED=1 "$0" >/dev/null 2>&1; then
      fail_usage "$sample did not reject an unclassified soft-limit violation"
    fi
    printf '%s\n' \
      '# readability-allow: contiguous-datum -- fixture identity stays intact.' \
      'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' \
      > "$sample_path"
    CONSENT_READABILITY_ROOT="$self_root" \
      CONSENT_READABILITY_FILE_LIST="$self_root/files" \
      CONSENT_READABILITY_EXCLUSIONS=tools/readability-exclusions.txt \
      CONSENT_READABILITY_SKIP_CHANGED=1 "$0" >/dev/null
  done
  printf '%s\n' "lint-readability: self-test passed for every supported file class."
}

case "${1:-}" in
  --self-test) run_self_test ;;
  '') run_repository_check ;;
  *) fail_usage "unknown argument $1" ;;
esac
