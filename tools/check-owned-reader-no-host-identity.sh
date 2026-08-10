#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Tahoma Toelkes

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
host=${CONSENT_PORTABLE_HOST:-racket}
target_root=$(mktemp -d "${TMPDIR:-/tmp}/consent-owned-reader.XXXXXX")
program=tests/scheme/consent-reader-owned-no-host-identity-test.scm

cleanup() {
  rm -rf "$target_root"
}
trap cleanup EXIT

cp -R "$root/scheme" "$target_root/scheme"
cp "$root/tests/fixtures/identity-map-poison.sld" \
  "$target_root/scheme/consent/identity-map.sld"

CONSENT_PORTABLE_HOST=$host \
CONSENT_PORTABLE_PROGRAM=$program \
CONSENT_TEST_TARGET_ROOT=$target_root \
  "$root/tools/run-portable-tests.sh"
