#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Tahoma Toelkes

# Compatibility entry point.  The repository-wide readability gate supersedes
# this Scheme-only command.

set -eu

exec "$(dirname "$0")/lint-readability.sh" "$@"
