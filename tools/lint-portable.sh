#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Tahoma Toelkes

# Portable-host compiler warnings-as-errors gate (#421).
#
# The portable twin of the Emacs byte-compile gate (#415). Compiles the
# host-loadable portable Consent Scheme libraries under Guile with the static
# warning classes promoted to errors, so unbound-variable, arity-mismatch,
# use-before-definition, and unused-lexical findings fail the build instead of
# passing silently.
#
# Guile is the gate host because, among the portable hosts already wired into
# CI (Gambit, Racket, Guile, Gauche), it is the only one with a usable
# ahead-of-time warning facility -- `guild compile -W ...`, the same `-W`
# baseline the linting survey records for Chez/Guile. Gambit reports arity only
# at run time, and Racket/Gauche expose no comparable unused/unbound static
# warning pass, so they are intentionally out of scope here (see
# docs/development.md); this gate is bounded to hosts already in CI per #421.
#
# Mechanism: auto-compilation with a pinned warning set surfaces warnings for
# every transitively compiled library, not just the entry module, so a single
# driver that imports the whole host-loadable set lints the whole set. The
# driver and the bytecode cache live in a throwaway build directory and a fresh
# compile is forced each run so cached `.go` files never mask a warning.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
scheme_dir="$repo_root/scheme"

guile=${CONSENT_GUILE:-guile}
build_dir=${CONSENT_PORTABLE_LINT_BUILD_DIR:-"$repo_root/build/lint-portable"}
case "$build_dir" in
  /*) ;;
  *) build_dir="$repo_root/$build_dir" ;;
esac

# Libraries excluded from the gate because they are not host-loadable as pure
# R7RS: their import closure reaches runtime-virtual library names or the
# host-adapter primitive layer that only exists inside the Consent runtime, not
# on the bare host. They are exercised through the runtime instead. Keep this
# list explicit so a newly added library that depends on such a module fails the
# gate loudly (forcing either a host-loadable design or a documented entry here)
# rather than being silently skipped.
#   (agent diagnostics) (agent diff) (agent test) -> import (agent io)
#   (agent models)                                -> imports (agent reflect)
#                                                    and (agent models primitive)
#   (consent capability)                          -> imports (consent capability primitive)
is_excluded() {
  case "$1" in
    "(agent diagnostics)"|"(agent diff)"|"(agent test)"|"(agent models)"|"(consent capability)")
      return 0 ;;
    *) return 1 ;;
  esac
}

if ! command -v "$guile" >/dev/null 2>&1; then
  printf '%s\n' "lint-portable: Guile ($guile) is not available; skipping the portable warnings gate."
  exit 0
fi

rm -rf "$build_dir"
mkdir -p "$build_dir/consent-lint" "$build_dir/cache"

driver="$build_dir/consent-lint/driver.sld"
setup="$build_dir/setup.scm"

# Generate the driver: import every host-loadable project library with a unique
# prefix (prefixing avoids export-name collisions between libraries while still
# forcing each one to be compiled). Libraries Guile provides natively -- the
# `(scheme ...)` standard libraries the project single-sources for hosts that
# lack them -- are skipped because Guile compiles its own, not ours.
{
  printf '%s\n' '(define-library (consent-lint driver)'
  printf '%s\n' '  (import (scheme base)'
  i=0
  find "$scheme_dir" -name '*.sld' | sort | while IFS= read -r sld; do
    name=$(sed -n 's/.*(define-library \(([^)]*)\).*/\1/p' "$sld" | head -n 1)
    [ -n "$name" ] || continue
    case "$name" in "(scheme "*) continue ;; esac
    if is_excluded "$name"; then continue; fi
    i=$((i + 1))
    printf '    (prefix %s p%s:)\n' "$name" "$i"
  done
  printf '%s\n' '    )'
  printf '%s\n' '  (begin (define consent-lint-driver-ok #t)))'
} > "$driver"

# Pin the gated warning classes. `unused-toplevel`, `unused-module`,
# `shadowed-toplevel`, and `non-idempotent-definition` are deliberately omitted:
# the project registers internal helpers and primitives through runtime dispatch
# tables that Guile's per-module static analysis cannot see, so those classes
# fire hundreds of false positives on the library bodies and cannot gate
# cleanly. The retained set is the high-signal subset the issue targets --
# unbound variables, arity mismatches, use-before-definition, unused lexicals,
# format-argument and case-datum mistakes.
cat > "$setup" <<'EOF'
(use-modules (system base compile))
(set! %auto-compilation-options
  '(#:warnings (unbound-variable
                arity-mismatch
                format
                unused-variable
                macro-use-before-definition
                use-before-definition
                duplicate-case-datum
                bad-case-datum)))
EOF

output_file="$build_dir/output.log"
set +e
XDG_CACHE_HOME="$build_dir/cache" "$guile" \
  --fresh-auto-compile \
  --r7rs \
  -L "$scheme_dir" \
  -L "$build_dir" \
  -l "$setup" \
  -c '(import (consent-lint driver))' \
  > "$output_file" 2>&1
status=$?
set -e

# Surface the host's own ";;; compiling ..." progress and any warnings.
cat "$output_file"

if [ "$status" -ne 0 ]; then
  printf '%s\n' 'lint-portable: Guile failed to load the portable libraries (see output above).' >&2
  rm -rf "$build_dir"
  exit 1
fi

if grep -q 'warning:' "$output_file"; then
  printf '%s\n' 'lint-portable: portable libraries produced compiler warnings under Guile (treated as errors).' >&2
  rm -rf "$build_dir"
  exit 1
fi

rm -rf "$build_dir"
printf '%s\n' 'lint-portable: portable libraries compiled clean under the Guile warnings-as-errors gate.'
