#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Tahoma Toelkes

set -euo pipefail

host=${CONSENT_PORTABLE_HOST:?CONSENT_PORTABLE_HOST is required}
group=${CONSENT_PORTABLE_GROUP:-full}
root=$(cd "$(dirname "$0")/.." && pwd)
target_root=${CONSENT_TEST_TARGET_ROOT:-$root}
library_root=$target_root/scheme
export CONSENT_LIBRARY_PATH=$library_root
plan_file=$root/tests/scheme/test-plan.scm
plan_runner=$root/tests/scheme/run-test-plan.scm
started=$SECONDS
ran=0
racket_collections=
plan_output=
current_test=

cleanup() {
  if [[ -n $racket_collections && -d $racket_collections ]]; then
    rm -rf "$racket_collections"
  fi
  if [[ -n $plan_output && -f $plan_output ]]; then
    rm -f "$plan_output"
  fi
}
trap cleanup EXIT

failure() {
  status=$?
  printf 'portable Scheme test failed: host=%s file=%s status=%d\n' \
    "$host" "${current_test:-unknown}" "$status" >&2
  exit "$status"
}
trap failure ERR

case $host in
  gambit)
    runner=${CONSENT_GAMBIT:-gsi}
    ;;
  gambit-native)
    runner=${CONSENT_GAMBIT_NATIVE:-$root/build/compile/gambit/bin/consent}
    ;;
  racket)
    runner=${CONSENT_RACKET:-racket}
    ;;
  compiled)
    runner=${CONSENT_COMPILED:-$root/build/compile/racket/bin/consent}
    ;;
  gauche)
    runner=${CONSENT_GAUCHE:-gosh}
    ;;
  guile)
    runner=${CONSENT_GUILE:-guile}
    ;;
  chibi)
    runner=${CONSENT_CHIBI:-chibi-scheme}
    ;;
  *)
    printf 'unknown portable Scheme host: %s\n' "$host" >&2
    exit 2
    ;;
esac

if [[ $runner != */* ]] && ! command -v "$runner" >/dev/null 2>&1; then
  printf '%s is unavailable; skipping portable %s tests\n' "$runner" "$host"
  exit 0
fi
if [[ $runner == */* && ! -x $runner ]]; then
  printf '%s is unavailable; skipping portable %s tests\n' "$runner" "$host"
  exit 0
fi

if [[ $host == racket ]]; then
  racket_collections=$(mktemp -d "${TMPDIR:-/tmp}/consent-racket-collections.XXXXXX")
  while IFS= read -r source; do
    relative=${source#"$library_root/"}
    target=$racket_collections/${relative%.sld}.rkt
    mkdir -p "$(dirname "$target")"
    {
      printf '#lang r7rs\n'
      sed -n '1,$p' "$source"
    } > "$target"
  done < <(find "$library_root" -name '*.sld' -type f | sort)
fi

run_scheme_program() {
  local program=$1
  case $host in
    gambit)
      "$runner" "-:r7rs,search=$library_root" "$program"
      ;;
    gambit-native|compiled)
      "$runner" --host-run "$program"
      ;;
    racket)
      "$runner" -S "$racket_collections" -I r7rs -f "$program"
      ;;
    gauche)
      "$runner" -I "$library_root" -r7 "$program"
      ;;
    guile)
      "$runner" --no-auto-compile --r7rs -L "$library_root" "$program"
      ;;
    chibi)
      "$runner" -A "$library_root" "$program"
      ;;
  esac
}

cd "$root"
plan_output=$(mktemp "${TMPDIR:-/tmp}/consent-test-plan.XXXXXX")
current_test=$plan_runner
export TESTING_PLAN_FILE=$plan_file
export TESTING_PLAN_SHARD=$group
run_scheme_program "$plan_runner" > "$plan_output"
unset TESTING_PLAN_FILE TESTING_PLAN_SHARD

while IFS= read -r test_file; do
  [[ -n $test_file ]] || continue
  current_test=$test_file
  run_scheme_program "$test_file"
  ran=$((ran + 1))
done < "$plan_output"

elapsed=$((SECONDS - started))
printf 'CONSENT_CI_PORTABLE_SUMMARY=%d %d 0 0 %d\n' "$ran" "$ran" "$elapsed"
