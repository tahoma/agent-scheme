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
list_file=$root/tests/scheme/${group}-test-files.txt
started=$SECONDS
ran=0
racket_collections=
current_test=

if [[ ! -f $list_file ]]; then
  printf 'unknown portable test group: %s\n' "$group" >&2
  exit 2
fi

cleanup() {
  if [[ -n $racket_collections && -d $racket_collections ]]; then
    rm -rf "$racket_collections"
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

cd "$root"
while IFS= read -r test_file; do
  [[ -n $test_file ]] || continue
  current_test=$test_file
  case $host in
    gambit)
      "$runner" "-:r7rs,search=$library_root" "$test_file"
      ;;
    gambit-native|compiled)
      "$runner" --host-run "$test_file"
      ;;
    racket)
      "$runner" -S "$racket_collections" -I r7rs -f "$test_file"
      ;;
    gauche)
      "$runner" -I "$library_root" -r7 "$test_file"
      ;;
    guile)
      "$runner" --no-auto-compile --r7rs -L "$library_root" "$test_file"
      ;;
    chibi)
      "$runner" -A "$library_root" "$test_file"
      ;;
  esac
  ran=$((ran + 1))
done < "$list_file"

elapsed=$((SECONDS - started))
printf 'CONSENT_CI_PORTABLE_SUMMARY=%d %d 0 0 %d\n' "$ran" "$ran" "$elapsed"
