#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Tahoma Toelkes

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
host=${CONSENT_PORTABLE_HOST:-racket}
target_root=$(mktemp -d "${TMPDIR:-/tmp}/consent-owned-reader.XXXXXX")
reader_program=tests/scheme/consent-reader-owned-no-host-identity-test.scm
datum_program=tests/scheme/consent-datum-test.scm
datum_selector='(name native-no-bridge-result-import-'
datum_selector+='charges-only-fresh-compounds)'
datum_selector_args="(\"--select\" \"$datum_selector\")"

cleanup() {
  rm -rf "$target_root"
}
trap cleanup EXIT

cp -R "$root/scheme" "$target_root/scheme"
cp "$root/tests/fixtures/identity-map-poison.sld" \
  "$target_root/scheme/consent/identity-map.sld"

CONSENT_PORTABLE_HOST=$host \
CONSENT_PORTABLE_PROGRAM=$reader_program \
CONSENT_TEST_TARGET_ROOT=$target_root \
  "$root/tools/run-portable-tests.sh"

# The result-import case must observe the same poison while it proves that
# scalar and same-heap results bypass the host identity map and every fresh
# compound fails closed before the correctness-only identity alist is touched.
CONSENT_PORTABLE_HOST=$host \
CONSENT_PORTABLE_PROGRAM=$datum_program \
CONSENT_TEST_TARGET_ROOT=$target_root \
TESTING_RUNNER_ARGUMENTS=$datum_selector_args \
  "$root/tools/run-portable-tests.sh"
