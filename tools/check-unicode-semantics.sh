#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Tahoma Toelkes

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
host=${CONSENT_UNICODE_SEMANTIC_HOST:-racket}
target_root=${CONSENT_TEST_TARGET_ROOT:-$root}
expected_file=${CONSENT_UNICODE_SEMANTIC_EXPECTED:-\
$root/tests/fixtures/unicode-17.0.0-semantic-digest.scm}
configured_version=${CONSENT_UNICODE_SEMANTIC_VERSION:-}
program=$root/tests/scheme/consent-unicode-semantic-stream.scm

case $host in
  gambit) runner=${CONSENT_GAMBIT:-gsi} ;;
  racket) runner=${CONSENT_RACKET:-racket} ;;
  gauche) runner=${CONSENT_GAUCHE:-gosh} ;;
  guile) runner=${CONSENT_GUILE:-guile} ;;
  chibi) runner=${CONSENT_CHIBI:-chibi-scheme} ;;
  *)
    printf 'unsupported Unicode semantic host: %s\n' "$host" >&2
    exit 2
    ;;
esac

if [[ $runner != */* ]] && ! command -v "$runner" >/dev/null 2>&1; then
  printf '%s is required for the Unicode semantic check\n' "$runner" >&2
  exit 2
fi
if [[ $runner == */* && ! -x $runner ]]; then
  printf '%s is required for the Unicode semantic check\n' "$runner" >&2
  exit 2
fi

expected_schema=$(awk '/^[[:space:]]*\(schema / { \
  value = $2; sub(/\).*/, "", value); print value; exit }' "$expected_file")
expected_version=$(awk -F '"' \
  '/^[[:space:]]*\(unicode-version / { print $2; exit }' "$expected_file")
expected_scalars=$(awk '/^[[:space:]]*\(scalar-count / { \
  value = $2; sub(/\).*/, "", value); print value; exit }' "$expected_file")
expected_digest=$(awk -F '"' '/^[[:space:]]*\(sha256 / { print $2; exit }' \
  "$expected_file")
expected_bytes=$(awk '/^[[:space:]]*\(byte-count / { \
  value = $2; sub(/\).*/, "", value); print value; exit }' "$expected_file")
if [[ -z $configured_version ]]; then
  printf 'CONSENT_UNICODE_SEMANTIC_VERSION is required\n' >&2
  exit 2
fi
if [[ $expected_schema != 1 ]]; then
  printf 'unsupported Unicode semantic schema in %s\n' \
    "$expected_file" >&2
  exit 2
fi
if [[ $expected_version != "$configured_version" ]]; then
  printf 'Unicode semantic version mismatch: expected %s, configured %s\n' \
    "$expected_version" "$configured_version" >&2
  exit 2
fi
if [[ $expected_scalars != 1112064 ]]; then
  printf 'invalid Unicode semantic scalar count in %s\n' \
    "$expected_file" >&2
  exit 2
fi
if [[ ! $expected_digest =~ ^[[:xdigit:]]{64}$ ]]; then
  printf 'invalid checked Unicode semantic digest in %s\n' \
    "$expected_file" >&2
  exit 2
fi
if [[ ! $expected_bytes =~ ^[0-9]+$ ]]; then
  printf 'invalid checked Unicode semantic byte count in %s\n' \
    "$expected_file" >&2
  exit 2
fi

temporary_root=$(mktemp -d \
  "${TMPDIR:-/tmp}/consent-unicode-semantics.XXXXXX")
stream=$temporary_root/semantics.bin
cleanup() {
  rm -rf "$temporary_root"
}
trap cleanup EXIT

CONSENT_PORTABLE_HOST=$host \
CONSENT_PORTABLE_PROGRAM=$program \
CONSENT_TEST_TARGET_ROOT=$target_root \
CONSENT_UNICODE_SEMANTIC_OUTPUT=$stream \
  "$root/tools/run-portable-tests.sh"

if [[ ! -f $stream ]]; then
  printf 'Unicode semantic program did not write %s\n' "$stream" >&2
  exit 1
fi

actual_bytes=$(wc -c < "$stream" | tr -d '[:space:]')
if [[ $actual_bytes != "$expected_bytes" ]]; then
  printf 'Unicode semantic byte count mismatch: expected %s, got %s\n' \
    "$expected_bytes" "$actual_bytes" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual_digest=$(sha256sum "$stream" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  actual_digest=$(shasum -a 256 "$stream" | awk '{print $1}')
elif command -v openssl >/dev/null 2>&1; then
  actual_digest=$(openssl dgst -sha256 "$stream" | awk '{print $NF}')
else
  printf 'sha256sum, shasum, or openssl is required\n' >&2
  exit 2
fi

if [[ $actual_digest != "$expected_digest" ]]; then
  printf 'Unicode semantic digest mismatch\n' >&2
  printf '  expected: %s\n' "$expected_digest" >&2
  printf '  actual:   %s\n' "$actual_digest" >&2
  exit 1
fi

printf 'Unicode semantic digest verified: %s\n' "$actual_digest"
