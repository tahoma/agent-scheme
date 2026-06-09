#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Tahoma Toelkes

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

compile_host=${CONSENT_COMPILE_HOST:-gambit}
build_dir=${CONSENT_COMPILE_BUILD_DIR:-"$repo_root/build/compile"}
case "$build_dir" in
  /*) ;;
  *) build_dir="$repo_root/$build_dir" ;;
esac
scheme_dir="$repo_root/scheme"
version_file="$scheme_dir/consent/version.sld"
# Install datadir baked into the binary as a runtime library search directory so
# an installed library tree is resolved ahead of the embedded floor. Empty for a
# plain `make compile' (then only CONSENT_LIBRARY_PATH and the embedded floor
# apply); the Makefile passes the configured $(consentlibdir).
install_datadir=${CONSENT_INSTALL_DATADIR:-}

die() {
  printf '%s\n' "consent compile: $*" >&2
  exit 2
}

find_command() {
  env_name=$1
  fallback=$2
  value=$(eval "printf '%s' \"\${$env_name:-}\"")

  if [ -n "$value" ]; then
    case "$value" in
      */*)
        if [ -x "$value" ]; then
          printf '%s\n' "$value"
          return 0
        fi
        return 1
        ;;
      *)
        command -v "$value" 2>/dev/null && return 0
        return 1
        ;;
    esac
  fi

  command -v "$fallback" 2>/dev/null && return 0
  return 1
}

version_components() {
  awk '
    match($0, /\(consent-version [0-9]+ [0-9]+ [0-9]+\)/) {
      text = substr($0, RSTART + 1, RLENGTH - 2)
      split(text, parts, " ")
      print parts[2] "." parts[3] "." parts[4]
      exit
    }
  ' "$version_file"
}

version_datum() {
  components=$1
  printf '(consent-version %s)\n' "$(printf '%s\n' "$components" | tr '.' ' ')"
}

# Structural guard: the product main must route --script through the gated
# Consent interpreter (cli-script-run-file) and must NOT host-load user input.
# This fails the build if the product entry point ever regresses to host
# execution. (The non-shipped host-runner main legitimately uses host `load' and
# is checked separately.)
assert_product_main_gated() {
  main_file=$1
  grep -q 'cli-script-run-file' "$main_file" \
    || die "product main does not route --script through the gated cli-script-run-file: $main_file"
  if grep -Eq '\(load[[:space:]]' "$main_file"; then
    die "product main contains a host (load ...) call; --script must not host-load user input: $main_file"
  fi
}

write_manifest() {
  host_root=$1
  host=$2
  version=$3
  manifest="$host_root/manifest.scm"

  cat > "$manifest" <<EOF
(consent-compile
  (compile-host $host)
  (version $(version_datum "$version"))
  (layout
    (root "$host_root")
    (executable "bin/consent")
    (generated-source "src")
    (dependency-manifest "manifest.scm")
    (smoke-log "logs/smoke.log")))
EOF
}

# Enumerate the runtime-provided source files (canonical relative paths) by asking
# the runtime itself, via the compile host's interpreter, so the embed and install
# manifest is single-sourced from the interpreter's library declarations
# (base.sld prelude/syntax paths + library.sld source-library tables) rather than
# hand-maintained. gsi reads the source tree directly; racket reads the generated
# collections, so the Racket call must run after generate_racket_collections.
enumerate_runtime_source_files() {
  enum_prog='(import (scheme base) (scheme write) (consent library)) (for-each (lambda (p) (display p) (newline)) (consent-runtime-source-files))'
  case "$compile_host" in
    gambit)
      "$gsi" -:r7rs,search="$scheme_dir" -e "$enum_prog" \
        || die "could not enumerate runtime source files via gsi"
      ;;
    racket)
      enum_file="$build_dir/consent-runtime-source-files.rkt"
      { printf '%s\n' '#lang r7rs'; printf '%s\n' "$enum_prog"; } > "$enum_file"
      PLTCOLLECTS="$collections_dir:${PLTCOLLECTS:-}" "$racket" "$enum_file" \
        || { rm -f "$enum_file"; die "could not enumerate runtime source files via racket"; }
      rm -f "$enum_file"
      ;;
    *)
      die "cannot enumerate runtime source files for host $compile_host"
      ;;
  esac
}

# Write the runtime-source manifest (one canonical relative path per line) into
# the host build root, so `make install'/`make dist' consume the same enumeration
# as the embedded floor rather than a hand-maintained list.
write_runtime_source_manifest() {
  manifest_root=$1
  source_list=$2
  printf '%s\n' "$source_list" > "$manifest_root/runtime-source-manifest"
}

# Write a `(consent embedded-source)' library whose exported installer registers
# each embedded source string with the runtime. SOURCE_LIST is the newline-
# separated set of canonical relative paths from enumerate_runtime_source_files
# (the zero-dependency bootstrap floor). The source text is emitted as a Scheme
# string literal by escaping only backslash and double-quote (R7RS string literals
# admit literal newlines), so the embedded text round-trips byte-for-byte back
# through the reader. LANG_HEADER is `#lang r7rs' for Racket, empty for Gambit.
write_embedded_source_module() {
  out_file=$1
  lang_header=$2
  source_list=$3

  {
    if [ -n "$lang_header" ]; then
      printf '%s\n' "$lang_header"
    fi
    printf '%s\n' '(define-library (consent embedded-source)'
    printf '%s\n' '  (export consent-install-embedded-source! consent-embedded-datadir)'
    printf '%s\n' '  (import (scheme base) (consent runtime))'
    printf '%s\n' '  (begin'
    printf '    (define consent-embedded-datadir "%s")\n' "$install_datadir"
    printf '%s\n' '    (define (consent-install-embedded-source!)'
    printf '%s\n' "$source_list" | while IFS= read -r relative
    do
      [ -n "$relative" ] || continue
      printf '      (consent-register-embedded-source! "%s" "' "$relative"
      sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' "$scheme_dir/$relative"
      printf '")\n'
    done
    printf '%s\n' '      #t)))'
  } > "$out_file"
}

# Emit the shared Racket main body: imports plus every helper and the dispatch,
# but not the startup expression. The product binary and the non-shipped
# host-execution test runner append their own startup, keeping one import list.
write_racket_main_common() {
  cat <<'EOF'
#lang r7rs

;; Prefix imports keep script-time R7RS and project libraries linked into the
;; executable even when user programs import them only after startup.
(import (scheme base)
        (prefix (scheme case-lambda) consent-main:r7rs-case-lambda:)
        (prefix (scheme char) consent-main:r7rs-char:)
        (prefix (scheme complex) consent-main:r7rs-complex:)
        (prefix (scheme cxr) consent-main:r7rs-cxr:)
        (only (scheme eval) environment)
        (prefix (scheme file) consent-main:r7rs-file:)
        (prefix (scheme inexact) consent-main:r7rs-inexact:)
        (prefix (scheme lazy) consent-main:r7rs-lazy:)
        (scheme load)
        (scheme process-context)
        (prefix (scheme r5rs) consent-main:r7rs-r5rs:)
        (prefix (scheme read) consent-main:r7rs-read:)
        (prefix (scheme repl) consent-main:r7rs-repl:)
        (prefix (scheme time) consent-main:r7rs-time:)
        (scheme write)
        (prefix (agent task) consent-main:agent-task:)
        (prefix (agent transcript) consent-main:agent-transcript:)
        (prefix (consent approval) consent-main:approval:)
        (prefix (consent base) consent-main:base:)
        (prefix (consent context) consent-main:context:)
        (prefix (consent helper) consent-main:helper:)
        (prefix (consent job) consent-main:job:)
        (prefix (consent library) consent-main:library:)
        (prefix (consent macro) consent-main:macro:)
        (prefix (consent memory) consent-main:memory:)
        (prefix (consent plan) consent-main:plan:)
        (prefix (consent reader) consent-main:reader:)
        (prefix (consent redaction) consent-main:redaction:)
        (prefix (consent result) consent-main:result:)
        (prefix (consent runtime) consent-main:runtime:)
        (prefix (consent session) consent-main:session:)
        (prefix (cli process-host) consent-main:cli-process-host:)
        (prefix (cli native-cli) consent-main:cli-native-cli:)
        (prefix (cli repl-chrome) consent-main:cli-repl-chrome:)
        (prefix (cli repl-shell) consent-main:cli-repl-shell:)
        (prefix (cli script) consent-main:cli-script:)
        (prefix (consent embedded-source) consent-main:embedded:)
        (only (consent eval)
              consent-eval-source
              consent-value->external)
        (only (consent version)
              consent-version-datum))

(define (consent-main-version-string)
  (let ((primary (list-ref consent-version-datum 1))
        (secondary (list-ref consent-version-datum 2))
        (tertiary (list-ref consent-version-datum 3)))
    (string-append
     "Consent Scheme "
     (number->string primary)
     "."
     (number->string secondary)
     "."
     (number->string tertiary))))

(define (consent-main-help)
  (display "Usage: consent [--help] [--version] [--repl] [--eval SOURCE] [--script FILE | FILE]\n")
  (display "\n")
  (display "Commands:\n")
  (display "  --help          Show this help.\n")
  (display "  --version       Print the Consent Scheme runtime version.\n")
  (display "  --eval SOURCE   Evaluate a Consent Scheme expression.\n")
  (display "  --script FILE   Run a Consent Scheme script file (capability-gated).\n")
  (display "  --repl          Start the portable terminal REPL shell.\n")
  (display "  FILE            Run FILE as a script (same as --script FILE),\n")
  (display "                  so a #!/usr/bin/env consent shebang runs directly.\n")
  (display "\n")
  (display "REPL options (with --repl):\n")
  (display "  --session NAME  Name the REPL session id.\n")
  (display "  --chrome NAME   Presentation chrome: comment (default), datum,\n")
  (display "                  classic, quiet, or silent.\n")
  (display "  --color=WHEN    Colorize chrome: auto (default), always, never.\n"))

(define (consent-main-error message)
  (display "consent: " (current-error-port))
  (display message (current-error-port))
  (newline (current-error-port))
  (exit 2))

(define (consent-main-eval source)
  (guard (condition
          (else
           (display "consent: evaluation failed" (current-error-port))
           (display ": " (current-error-port))
           (write condition (current-error-port))
           (newline (current-error-port))
           (exit 1)))
    (display
     (consent-value->external
      (consent-eval-source source)))
    (newline)))

(define (consent-main-script path)
  (guard (condition
          (else
           (display "consent: script failed" (current-error-port))
           (display ": " (current-error-port))
           (write condition (current-error-port))
           (newline (current-error-port))
           (exit 1)))
    ;; Run the script through the Consent interpreter with the non-interactive
    ;; fail-closed posture (capability-gated; no raw host objects exposed) -- the
    ;; same gated path as --eval and the Emacs `consent-script-run-file' twin.
    (consent-main:cli-script:cli-script-run-file path)))

(define (consent-main args)
  (cond
   ((null? args)
    (consent-main-help))
   ((string=? (car args) "--help")
    (consent-main-help))
   ((string=? (car args) "--version")
    (display (consent-main-version-string))
    (newline))
   ((string=? (car args) "--eval")
    (if (null? (cdr args))
        (consent-main-error "--eval requires SOURCE")
        (consent-main-eval (cadr args))))
   ((string=? (car args) "--script")
    (if (null? (cdr args))
        (consent-main-error "--script requires FILE")
        (consent-main-script (cadr args))))
   ((string=? (car args) "--repl")
    (consent-main:cli-repl-shell:cli-repl-main))
   ((and (> (string-length (car args)) 0)
         (char=? (string-ref (car args) 0) #\-))
    (consent-main-error
     (string-append "unknown option " (car args))))
   (else
    ;; A bare path is a script file: consent FILE == consent --script FILE.
    ;; This lets a #!/usr/bin/env consent shebang run a file with no flag,
    ;; avoiding the kernel single-argument rule that breaks a flagged shebang.
    (consent-main-script (car args)))))

(define (consent-main--split-search-path value)
  ;; Split a colon-separated path string into directory components.
  (let loop ((chars (string->list value)) (current '()) (parts '()))
    (cond
     ((null? chars)
      (reverse (if (null? current)
                   parts
                   (cons (list->string (reverse current)) parts))))
     ((char=? (car chars) #\:)
      (loop (cdr chars) '()
            (if (null? current)
                parts
                (cons (list->string (reverse current)) parts))))
     (else
      (loop (cdr chars) (cons (car chars) current) parts)))))

(define (consent-main--library-search-directories)
  ;; Host-injected runtime library search directories, highest precedence first:
  ;; CONSENT_LIBRARY_PATH (explicit override), then the install datadir baked at
  ;; compile time. The core resolver consults these ahead of the source tree and
  ;; the embedded floor.
  (let ((env (get-environment-variable "CONSENT_LIBRARY_PATH"))
        (datadir consent-main:embedded:consent-embedded-datadir))
    (append
     (if (and env (> (string-length env) 0))
         (consent-main--split-search-path env)
         '())
     (if (> (string-length datadir) 0)
         (list datadir)
         '()))))
EOF
}

write_racket_main() {
  main_file=$1

  {
    write_racket_main_common
    cat <<'EOF'

;; Register the embedded bootstrap source (prelude, syntax prelude, and runtime
;; source-libraries) so the interpreter boots from this standalone binary even
;; when relocated outside a source tree.
(consent-main:embedded:consent-install-embedded-source!)

;; Inject the host's runtime library search directories (CONSENT_LIBRARY_PATH and
;; the baked install datadir) so an installed or overridden library tree is
;; resolved ahead of the embedded floor.
(consent-main:runtime:consent-set-library-search-directories!
 (consent-main--library-search-directories))

(let ((arguments (command-line)))
  (consent-main
   (if (null? arguments) '() (cdr arguments))))
EOF
  } > "$main_file"
}

# Non-shipped host-execution test runner: runs an R7RS program on the host
# substrate so the compiled test shard can exercise the compiled libraries'
# white-box tests, which import internal modules (e.g. (consent interpreter)) and
# cannot run through the consent interpreter. This is NOT the consent sandbox and
# is never installed or shipped (make install/dist copy only bin/consent).
write_racket_host_runner_main() {
  main_file=$1

  {
    write_racket_main_common
    cat <<'EOF'

(let ((arguments (command-line)))
  (if (and (pair? arguments) (pair? (cdr arguments)))
      (load (cadr arguments) (environment))
      (begin
        (display "consent-host-runner: expected a script file argument\n"
                 (current-error-port))
        (exit 2))))
EOF
  } > "$main_file"
}

# Emit the shared Gambit main body (imports + helpers + dispatch, no startup),
# shared by the product binary and the non-shipped host-execution test runner.
write_gambit_main_common() {
  cat <<'EOF'

;; Gambit R7RS main program for the host-compiled Consent Scheme runner.

(import (scheme base)
        (prefix (scheme case-lambda) consent-main:r7rs-case-lambda:)
        (prefix (scheme char) consent-main:r7rs-char:)
        (prefix (scheme complex) consent-main:r7rs-complex:)
        (prefix (scheme cxr) consent-main:r7rs-cxr:)
        (prefix (scheme eval) consent-main:r7rs-eval:)
        (prefix (scheme file) consent-main:r7rs-file:)
        (prefix (scheme inexact) consent-main:r7rs-inexact:)
        (prefix (scheme lazy) consent-main:r7rs-lazy:)
        (scheme load)
        (scheme process-context)
        (prefix (scheme r5rs) consent-main:r7rs-r5rs:)
        (prefix (scheme read) consent-main:r7rs-read:)
        (prefix (scheme repl) consent-main:r7rs-repl:)
        (prefix (scheme time) consent-main:r7rs-time:)
        (scheme write)
        (prefix (agent task) consent-main:agent-task:)
        (prefix (agent transcript) consent-main:agent-transcript:)
        (prefix (consent approval) consent-main:approval:)
        (prefix (consent base) consent-main:base:)
        (prefix (consent context) consent-main:context:)
        (prefix (consent helper) consent-main:helper:)
        (prefix (consent job) consent-main:job:)
        (prefix (consent library) consent-main:library:)
        (prefix (consent macro) consent-main:macro:)
        (prefix (consent memory) consent-main:memory:)
        (prefix (consent plan) consent-main:plan:)
        (prefix (consent reader) consent-main:reader:)
        (prefix (consent redaction) consent-main:redaction:)
        (prefix (consent result) consent-main:result:)
        (prefix (consent runtime) consent-main:runtime:)
        (prefix (consent session) consent-main:session:)
        (prefix (cli process-host) consent-main:cli-process-host:)
        (prefix (cli native-cli) consent-main:cli-native-cli:)
        (prefix (cli repl-chrome) consent-main:cli-repl-chrome:)
        (prefix (cli repl-shell) consent-main:cli-repl-shell:)
        (prefix (cli script) consent-main:cli-script:)
        (prefix (consent embedded-source) consent-main:embedded:)
        (only (consent eval)
              consent-eval-source
              consent-value->external)
        (only (consent version)
              consent-version-datum))

(define (consent-main-version-string)
  (let ((primary (list-ref consent-version-datum 1))
        (secondary (list-ref consent-version-datum 2))
        (tertiary (list-ref consent-version-datum 3)))
    (string-append
     "Consent Scheme "
     (number->string primary)
     "."
     (number->string secondary)
     "."
     (number->string tertiary))))

(define (consent-main-help)
  (display "Usage: consent [--help] [--version] [--repl] [--eval SOURCE] [--script FILE | FILE]\n")
  (display "\n")
  (display "Commands:\n")
  (display "  --help          Show this help.\n")
  (display "  --version       Print the Consent Scheme runtime version.\n")
  (display "  --eval SOURCE   Evaluate a Consent Scheme expression.\n")
  (display "  --script FILE   Run a Consent Scheme script file (capability-gated).\n")
  (display "  --repl          Start the portable terminal REPL shell.\n")
  (display "  FILE            Run FILE as a script (same as --script FILE),\n")
  (display "                  so a #!/usr/bin/env consent shebang runs directly.\n")
  (display "\n")
  (display "REPL options (with --repl):\n")
  (display "  --session NAME  Name the REPL session id.\n")
  (display "  --chrome NAME   Presentation chrome: comment (default), datum,\n")
  (display "                  classic, quiet, or silent.\n")
  (display "  --color=WHEN    Colorize chrome: auto (default), always, never.\n"))

(define (consent-main-error message)
  (display "consent: " (current-error-port))
  (display message (current-error-port))
  (newline (current-error-port))
  (exit 2))

(define (consent-main-eval source)
  (guard (condition
          (else
           (display "consent: evaluation failed" (current-error-port))
           (display ": " (current-error-port))
           (write condition (current-error-port))
           (newline (current-error-port))
           (exit 1)))
    (display
     (consent-value->external
      (consent-eval-source source)))
    (newline)))

(define (consent-main-script path)
  (guard (condition
          (else
           (display "consent: script failed" (current-error-port))
           (display ": " (current-error-port))
           (write condition (current-error-port))
           (newline (current-error-port))
           (exit 1)))
    ;; Run the script through the Consent interpreter with the non-interactive
    ;; fail-closed posture (capability-gated; no raw host objects exposed) -- the
    ;; same gated path as --eval and the Emacs `consent-script-run-file' twin.
    (consent-main:cli-script:cli-script-run-file path)))

(define (consent-main args)
  (cond
   ((null? args)
    (consent-main-help))
   ((string=? (car args) "--help")
    (consent-main-help))
   ((string=? (car args) "--version")
    (display (consent-main-version-string))
    (newline))
   ((string=? (car args) "--eval")
    (if (null? (cdr args))
        (consent-main-error "--eval requires SOURCE")
        (consent-main-eval (cadr args))))
   ((string=? (car args) "--script")
    (if (null? (cdr args))
        (consent-main-error "--script requires FILE")
        (consent-main-script (cadr args))))
   ((string=? (car args) "--repl")
    (consent-main:cli-repl-shell:cli-repl-main))
   ((and (> (string-length (car args)) 0)
         (char=? (string-ref (car args) 0) #\-))
    (consent-main-error
     (string-append "unknown option " (car args))))
   (else
    ;; A bare path is a script file: consent FILE == consent --script FILE.
    ;; This lets a #!/usr/bin/env consent shebang run a file with no flag,
    ;; avoiding the kernel single-argument rule that breaks a flagged shebang.
    (consent-main-script (car args)))))

(define (consent-main--split-search-path value)
  ;; Split a colon-separated path string into directory components.
  (let loop ((chars (string->list value)) (current '()) (parts '()))
    (cond
     ((null? chars)
      (reverse (if (null? current)
                   parts
                   (cons (list->string (reverse current)) parts))))
     ((char=? (car chars) #\:)
      (loop (cdr chars) '()
            (if (null? current)
                parts
                (cons (list->string (reverse current)) parts))))
     (else
      (loop (cdr chars) (cons (car chars) current) parts)))))

(define (consent-main--library-search-directories)
  ;; Host-injected runtime library search directories, highest precedence first:
  ;; CONSENT_LIBRARY_PATH (explicit override), then the install datadir baked at
  ;; compile time. The core resolver consults these ahead of the source tree and
  ;; the embedded floor.
  (let ((env (get-environment-variable "CONSENT_LIBRARY_PATH"))
        (datadir consent-main:embedded:consent-embedded-datadir))
    (append
     (if (and env (> (string-length env) 0))
         (consent-main--split-search-path env)
         '())
     (if (> (string-length datadir) 0)
         (list datadir)
         '()))))
EOF
}

write_gambit_main() {
  main_file=$1
  search_dir=$2

  printf '#!gsi -:r7rs,search=%s\n' "$search_dir" > "$main_file"
  {
    write_gambit_main_common
    cat <<'EOF'

;; Register the embedded bootstrap source (prelude, syntax prelude, and runtime
;; source-libraries) so the interpreter boots from this standalone binary even
;; when relocated outside a source tree.
(consent-main:embedded:consent-install-embedded-source!)

;; Inject the host's runtime library search directories (CONSENT_LIBRARY_PATH and
;; the baked install datadir) so an installed or overridden library tree is
;; resolved ahead of the embedded floor.
(consent-main:runtime:consent-set-library-search-directories!
 (consent-main--library-search-directories))

(let ((arguments (command-line)))
  (consent-main
   (if (null? arguments) '() (cdr arguments))))
EOF
  } >> "$main_file"
}

# Non-shipped host-execution test runner (Gambit). See the Racket twin above:
# runs an R7RS program on the host substrate for the gambit-native test shard;
# not the consent sandbox, never installed or shipped.
write_gambit_host_runner_main() {
  main_file=$1
  search_dir=$2

  printf '#!gsi -:r7rs,search=%s\n' "$search_dir" > "$main_file"
  {
    write_gambit_main_common
    cat <<'EOF'

(let ((arguments (command-line)))
  (if (and (pair? arguments) (pair? (cdr arguments)))
      (load (cadr arguments))
      (begin
        (display "consent-host-runner: expected a script file argument\n"
                 (current-error-port))
        (exit 2))))
EOF
  } >> "$main_file"
}

generate_racket_collections() {
  collections_dir=$1

  find "$scheme_dir" -type f -name '*.sld' | sort | while IFS= read -r source
  do
    relative=${source#"$scheme_dir/"}
    target="$collections_dir/$(printf '%s\n' "$relative" | sed 's/\.sld$/.rkt/')"
    mkdir -p "$(dirname -- "$target")"
    {
      printf '%s\n' '#lang r7rs'
      cat "$source"
    } > "$target"
  done
}

run_smoke() {
  runner=$1
  log_file=$2
  expected_version=$3
  smoke_started=$(date +%s)

  version_output=$("$runner" --version 2>"$log_file.version.err") \
    || die "compiled runner failed --version; see $log_file.version.err"
  eval_output=$("$runner" --eval "(+ 1 2)" 2>"$log_file.eval.err") \
    || die "compiled runner failed --eval; see $log_file.eval.err"

  if [ "$version_output" != "Consent Scheme $expected_version" ]; then
    die "compiled runner --version returned '$version_output', expected 'Consent Scheme $expected_version'"
  fi

  if [ "$eval_output" != "3" ]; then
    die "compiled runner --eval returned '$eval_output', expected '3'"
  fi

  # --script and --eval must run through the Consent interpreter, NOT host load.
  # Discriminator: the script posture allows program output but denies an
  # ungranted, confirm-gated host capability. Under host execution the write
  # would succeed; under the interpreter it is denied and leaves no file. These
  # smokes fail if any entry point ever regresses to the host evaluator.
  smoke_dir=$(mktemp -d "${TMPDIR:-/tmp}/consent-smoke.XXXXXX") \
    || die "could not create a temporary directory for the script smokes"

  # Positive: a pure script (no gated capabilities) evaluates through the
  # interpreter and exits 0. Program output is fail-closed under the script
  # posture, so the smoke proves evaluation by exit status, not stdout.
  ok_script="$smoke_dir/ok.scm"
  cat > "$ok_script" <<'EOF'
(import (scheme base))
(define (smoke-sq n) (* n n))
(if (not (= (smoke-sq 6) 36))
    (error "consent --script smoke computed the wrong value"))
EOF
  "$runner" --script "$ok_script" >"$log_file.script.out" 2>"$log_file.script.err" \
    || die "compiled runner failed --script interpreter smoke; see $log_file.script.err"
  script_output=ok

  deny_marker="$smoke_dir/denied-file"
  deny_script="$smoke_dir/deny.scm"
  cat > "$deny_script" <<EOF
(import (scheme base) (scheme file))
(call-with-output-file "$deny_marker"
  (lambda (port) (write-char #\\x port)))
EOF
  if "$runner" --script "$deny_script" >"$log_file.script-deny.out" 2>"$log_file.script-deny.err"; then
    die "compiled runner --script allowed an ungranted file write (host execution leaked); see $log_file.script-deny.err"
  fi
  if [ -e "$deny_marker" ]; then
    die "compiled runner --script created a denied file at $deny_marker (host execution leaked)"
  fi
  if "$runner" --eval "(begin (import (scheme file)) (call-with-output-file \"$deny_marker\" (lambda (port) (write-char #\\x port))))" \
       >"$log_file.eval-deny.out" 2>"$log_file.eval-deny.err"; then
    die "compiled runner --eval allowed an ungranted file write (host execution leaked); see $log_file.eval-deny.err"
  fi
  if [ -e "$deny_marker" ]; then
    die "compiled runner --eval created a denied file at $deny_marker (host execution leaked)"
  fi
  rm -rf "$smoke_dir"

  # Executable-script smokes (#399): prove the runner runs a real on-disk
  # shebang script end to end, exercising the OS-level dispatch that the
  # in-process tests cannot.
  shebang_dir=$(mktemp -d "${TMPDIR:-/tmp}/consent-shebang.XXXXXX") \
    || die "could not create a temporary directory for the shebang smokes"

  # Bare-path form: kernel runs `consent FILE`; the runner skips the shebang
  # line and runs the file as a script with no `--script` flag.
  bare_script="$shebang_dir/bare.scm"
  cat > "$bare_script" <<'EOF'
#!/usr/bin/env consent
(import (scheme base))
(if (not (= (+ 40 2) 42))
    (error "bare-path shebang smoke failed"))
EOF
  "$runner" "$bare_script" >"$log_file.bare.out" 2>"$log_file.bare.err" \
    || die "compiled runner failed bare-path shebang smoke; see $log_file.bare.err"
  bare_output=ok

  # sh-polyglot form: kernel runs /bin/sh, whose `exec` re-launches the runner
  # on the same file; the runner skips the shebang and reads the `#| exec |#`
  # block comment that hides the shell line from Scheme.
  polyglot_script="$shebang_dir/polyglot.scm"
  cat > "$polyglot_script" <<EOF
#!/bin/sh
#|
exec "$runner" --script "\$0" "\$@"
|#
(import (scheme base))
(if (not (= (+ 40 2) 42))
    (error "sh-polyglot shebang smoke failed"))
EOF
  chmod +x "$polyglot_script"
  "$polyglot_script" >"$log_file.polyglot.out" 2>"$log_file.polyglot.err" \
    || die "compiled runner failed sh-polyglot shebang smoke; see $log_file.polyglot.err"
  polyglot_output=ok

  # Bare-path deny discriminator: a bare-path script (consent FILE) attempting an
  # ungranted file write must be denied and leave no file -- proving the bare /
  # shebang dispatch also lands in the gated interpreter, not host execution.
  bare_deny_marker="$shebang_dir/bare-denied-file"
  bare_deny_script="$shebang_dir/bare-deny.scm"
  cat > "$bare_deny_script" <<EOF
#!/usr/bin/env consent
(import (scheme base) (scheme file))
(call-with-output-file "$bare_deny_marker"
  (lambda (port) (write-char #\\x port)))
EOF
  if "$runner" "$bare_deny_script" >"$log_file.bare-deny.out" 2>"$log_file.bare-deny.err"; then
    die "bare-path script allowed an ungranted file write (host execution leaked); see $log_file.bare-deny.err"
  fi
  if [ -e "$bare_deny_marker" ]; then
    die "bare-path script created a denied file at $bare_deny_marker (host execution leaked)"
  fi
  rm -rf "$shebang_dir"
  smoke_finished=$(date +%s)

  cat > "$log_file" <<EOF
(consent-compile-smoke
  (version-output "$version_output")
  (eval-output "$eval_output")
  (script-output "$script_output")
  (shebang-bare-output "$bare_output")
  (shebang-polyglot-output "$polyglot_output")
  (run-seconds $((smoke_finished - smoke_started))))
EOF
}

compile_racket() {
  racket=$(find_command CONSENT_RACKET racket) \
    || die "Racket compile prerequisites are missing; set CONSENT_RACKET to a runnable racket executable."
  raco=$(find_command CONSENT_RACO raco) \
    || die "Racket compile prerequisites are missing; set CONSENT_RACO to a runnable raco executable."

  host_root="$build_dir/racket"
  src_dir="$host_root/src"
  collections_dir="$host_root/collections"
  bin_dir="$host_root/bin"
  logs_dir="$host_root/logs"
  main_file="$src_dir/consent-main.rkt"
  runner="$bin_dir/consent"
  smoke_log="$logs_dir/smoke.log"
  version=$(version_components)

  [ -n "$version" ] || die "could not read Consent Scheme version from $version_file"

  mkdir -p "$src_dir" "$collections_dir" "$bin_dir" "$logs_dir"
  generate_racket_collections "$collections_dir"
  runtime_source_list=$(enumerate_runtime_source_files)
  mkdir -p "$collections_dir/consent"
  write_embedded_source_module "$collections_dir/consent/embedded-source.rkt" '#lang r7rs' "$runtime_source_list"
  write_runtime_source_manifest "$host_root" "$runtime_source_list"
  write_racket_main "$main_file"
  assert_product_main_gated "$main_file"
  write_manifest "$host_root" racket "$version"

  PLTCOLLECTS="$collections_dir:${PLTCOLLECTS:-}" \
    "$raco" exe --cs ++lang r7rs -o "$runner" "$main_file" \
    >"$logs_dir/raco-exe.log" 2>&1 \
    || die "raco exe failed; see $logs_dir/raco-exe.log"

  [ -f "$runner" ] \
    || die "raco exe did not create $runner; see $logs_dir/raco-exe.log"
  chmod +x "$runner"
  run_smoke "$runner" "$smoke_log" "$version"

  # Non-shipped host-execution test runner (not installed; see make install/dist).
  # Built when CONSENT_BUILD_TEST_RUNNER is set: the compiled white-box shard runs
  # the suite against it to test the COMPILED interpreter (every lane, including
  # per-push). A plain `make compile' (the install path) leaves it unset and skips
  # the second `raco exe' link.
  if [ -n "${CONSENT_BUILD_TEST_RUNNER:-}" ]; then
    host_runner_main="$src_dir/consent-host-runner.rkt"
    host_runner="$bin_dir/consent-host-runner"
    write_racket_host_runner_main "$host_runner_main"
    PLTCOLLECTS="$collections_dir:${PLTCOLLECTS:-}" \
      "$raco" exe --cs ++lang r7rs -o "$host_runner" "$host_runner_main" \
      >"$logs_dir/raco-exe-host-runner.log" 2>&1 \
      || die "raco exe (host runner) failed; see $logs_dir/raco-exe-host-runner.log"
    [ -f "$host_runner" ] \
      || die "raco exe did not create $host_runner; see $logs_dir/raco-exe-host-runner.log"
    chmod +x "$host_runner"
  fi

  printf '%s\n' "$runner"
}

compile_gambit() {
  gsi=$(find_command CONSENT_GAMBIT gsi) \
    || die "Gambit compile prerequisites are missing; set CONSENT_GAMBIT to a runnable gsi executable."
  gsc=$(find_command CONSENT_GAMBIT_COMPILER gsc) \
    || die "Gambit compile prerequisites are missing; set CONSENT_GAMBIT_COMPILER to a runnable gsc executable."

  host_root="$build_dir/gambit"
  src_dir="$host_root/src"
  bin_dir="$host_root/bin"
  logs_dir="$host_root/logs"
  main_file="$src_dir/consent-main.scm"
  main_c="$src_dir/consent-main.c"
  runner="$bin_dir/consent"
  smoke_log="$logs_dir/smoke.log"
  version=$(version_components)

  [ -n "$version" ] || die "could not read Consent Scheme version from $version_file"

  mkdir -p "$src_dir" "$bin_dir" "$logs_dir"

  copy_gambit_source() {
    source_file=$1
    target_file=$2

    mkdir -p "$(dirname -- "$target_file")"
    cp "$source_file" "$target_file"
  }

  copy_gambit_source \
    "$scheme_dir/consent/version.sld" \
    "$src_dir/consent/version.sld"
  copy_gambit_source \
    "$scheme_dir/consent/reader.sld" \
    "$src_dir/consent/reader.sld"
  copy_gambit_source \
    "$scheme_dir/consent/runtime.sld" \
    "$src_dir/consent/runtime.sld"
  copy_gambit_source \
    "$scheme_dir/consent/base.sld" \
    "$src_dir/consent/base.sld"
  copy_gambit_source \
    "$scheme_dir/consent/base-prelude.scm" \
    "$src_dir/consent/base-prelude.scm"
  copy_gambit_source \
    "$scheme_dir/consent/base-syntax.scm" \
    "$src_dir/consent/base-syntax.scm"
  copy_gambit_source \
    "$scheme_dir/consent/library.sld" \
    "$src_dir/consent/library.sld"
  copy_gambit_source \
    "$scheme_dir/consent/result.sld" \
    "$src_dir/consent/result.sld"
  copy_gambit_source \
    "$scheme_dir/consent/macro.sld" \
    "$src_dir/consent/macro.sld"
  copy_gambit_source \
    "$scheme_dir/consent/approval.sld" \
    "$src_dir/consent/approval.sld"
  copy_gambit_source \
    "$scheme_dir/consent/context.sld" \
    "$src_dir/consent/context.sld"
  copy_gambit_source \
    "$scheme_dir/consent/helper.sld" \
    "$src_dir/consent/helper.sld"
  copy_gambit_source \
    "$scheme_dir/consent/job.sld" \
    "$src_dir/consent/job.sld"
  copy_gambit_source \
    "$scheme_dir/consent/memory.sld" \
    "$src_dir/consent/memory.sld"
  copy_gambit_source \
    "$scheme_dir/consent/plan.sld" \
    "$src_dir/consent/plan.sld"
  copy_gambit_source \
    "$scheme_dir/consent/redaction.sld" \
    "$src_dir/consent/redaction.sld"
  copy_gambit_source \
    "$scheme_dir/consent/session.sld" \
    "$src_dir/consent/session.sld"
  copy_gambit_source \
    "$scheme_dir/consent/interpreter.sld" \
    "$src_dir/consent/interpreter.sld"
  copy_gambit_source \
    "$scheme_dir/consent/eval.sld" \
    "$src_dir/consent/eval.sld"
  copy_gambit_source \
    "$scheme_dir/agent/task.sld" \
    "$src_dir/agent/task.sld"
  copy_gambit_source \
    "$scheme_dir/agent/transcript.sld" \
    "$src_dir/agent/transcript.sld"
  copy_gambit_source \
    "$scheme_dir/cli/process-host.sld" \
    "$src_dir/cli/process-host.sld"
  copy_gambit_source \
    "$scheme_dir/cli/native-cli.sld" \
    "$src_dir/cli/native-cli.sld"
  copy_gambit_source \
    "$scheme_dir/cli/repl-chrome.sld" \
    "$src_dir/cli/repl-chrome.sld"
  copy_gambit_source \
    "$scheme_dir/cli/repl-shell.sld" \
    "$src_dir/cli/repl-shell.sld"
  copy_gambit_source \
    "$scheme_dir/cli/script.sld" \
    "$src_dir/cli/script.sld"

  "$gsi" -:r7rs,search="$scheme_dir" \
    -e '(import (scheme base) (scheme write)) (write (+ 1 2)) (newline)' \
    >"$logs_dir/gsi-r7rs-probe.log" 2>&1 \
    || die "Gambit gsi does not accept R7RS mode with the Consent Scheme library search path; see $logs_dir/gsi-r7rs-probe.log"

  write_gambit_main "$main_file" "$src_dir"
  assert_product_main_gated "$main_file"
  write_manifest "$host_root" gambit "$version"
  runtime_source_list=$(enumerate_runtime_source_files)
  write_runtime_source_manifest "$host_root" "$runtime_source_list"
  write_embedded_source_module "$src_dir/consent/embedded-source.sld" '' "$runtime_source_list"
  : >"$logs_dir/gsc-modules.log"

  compile_started=$(date +%s)
  gambit_c_files=

  compile_gambit_module() {
    module_ref=$1
    source_file=$2
    target_file=$3

    mkdir -p "$(dirname -- "$target_file")"
    "$gsc" -:r7rs,search="$scheme_dir" \
      -c -module-ref "$module_ref" -o "$target_file" "$source_file" \
      >>"$logs_dir/gsc-modules.log" 2>&1 \
      || die "gsc failed while compiling module $module_ref; see $logs_dir/gsc-modules.log"
    gambit_c_files="$gambit_c_files $target_file"
  }

  compile_gambit_module \
    consent/version \
    "$scheme_dir/consent/version.sld" \
    "$src_dir/consent/version.c"
  compile_gambit_module \
    consent/reader \
    "$scheme_dir/consent/reader.sld" \
    "$src_dir/consent/reader.c"
  compile_gambit_module \
    consent/runtime \
    "$scheme_dir/consent/runtime.sld" \
    "$src_dir/consent/runtime.c"
  compile_gambit_module \
    consent/base \
    "$scheme_dir/consent/base.sld" \
    "$src_dir/consent/base.c"
  compile_gambit_module \
    consent/library \
    "$scheme_dir/consent/library.sld" \
    "$src_dir/consent/library.c"
  compile_gambit_module \
    consent/result \
    "$scheme_dir/consent/result.sld" \
    "$src_dir/consent/result.c"
  compile_gambit_module \
    consent/macro \
    "$scheme_dir/consent/macro.sld" \
    "$src_dir/consent/macro.c"
  compile_gambit_module \
    consent/approval \
    "$scheme_dir/consent/approval.sld" \
    "$src_dir/consent/approval.c"
  compile_gambit_module \
    consent/context \
    "$scheme_dir/consent/context.sld" \
    "$src_dir/consent/context.c"
  compile_gambit_module \
    consent/helper \
    "$scheme_dir/consent/helper.sld" \
    "$src_dir/consent/helper.c"
  compile_gambit_module \
    consent/job \
    "$scheme_dir/consent/job.sld" \
    "$src_dir/consent/job.c"
  compile_gambit_module \
    consent/memory \
    "$scheme_dir/consent/memory.sld" \
    "$src_dir/consent/memory.c"
  compile_gambit_module \
    consent/plan \
    "$scheme_dir/consent/plan.sld" \
    "$src_dir/consent/plan.c"
  compile_gambit_module \
    consent/redaction \
    "$scheme_dir/consent/redaction.sld" \
    "$src_dir/consent/redaction.c"
  compile_gambit_module \
    consent/session \
    "$scheme_dir/consent/session.sld" \
    "$src_dir/consent/session.c"
  compile_gambit_module \
    agent/task \
    "$scheme_dir/agent/task.sld" \
    "$src_dir/agent/task.c"
  compile_gambit_module \
    agent/transcript \
    "$scheme_dir/agent/transcript.sld" \
    "$src_dir/agent/transcript.c"
  compile_gambit_module \
    consent/interpreter \
    "$scheme_dir/consent/interpreter.sld" \
    "$src_dir/consent/interpreter.c"
  compile_gambit_module \
    consent/eval \
    "$scheme_dir/consent/eval.sld" \
    "$src_dir/consent/eval.c"
  compile_gambit_module \
    cli/process-host \
    "$scheme_dir/cli/process-host.sld" \
    "$src_dir/cli/process-host.c"
  compile_gambit_module \
    cli/native-cli \
    "$scheme_dir/cli/native-cli.sld" \
    "$src_dir/cli/native-cli.c"
  compile_gambit_module \
    cli/repl-chrome \
    "$scheme_dir/cli/repl-chrome.sld" \
    "$src_dir/cli/repl-chrome.c"
  compile_gambit_module \
    cli/repl-shell \
    "$scheme_dir/cli/repl-shell.sld" \
    "$src_dir/cli/repl-shell.c"
  compile_gambit_module \
    cli/script \
    "$scheme_dir/cli/script.sld" \
    "$src_dir/cli/script.c"
  compile_gambit_module \
    consent/embedded-source \
    "$src_dir/consent/embedded-source.sld" \
    "$src_dir/consent/embedded-source.c"

  "$gsc" -:r7rs,search="$scheme_dir",search="$src_dir" \
    -c -o "$main_c" "$main_file" \
    >>"$logs_dir/gsc-modules.log" 2>&1 \
    || die "gsc failed while compiling the Gambit main program; see $logs_dir/gsc-modules.log"

  # shellcheck disable=SC2086
  "$gsc" -:r7rs,search="$scheme_dir" -exe -o "$runner" -nopreload $gambit_c_files "$main_c" \
    >"$logs_dir/gsc-exe.log" 2>&1 \
    || die "gsc -exe failed; see $logs_dir/gsc-exe.log"
  compile_finished=$(date +%s)

  [ -f "$runner" ] \
    || die "gsc -exe did not create $runner; see $logs_dir/gsc-exe.log"
  chmod +x "$runner"
  cat > "$logs_dir/compile.log" <<EOF
(consent-compile-timing
  (compile-host gambit)
  (compile-seconds $((compile_finished - compile_started))))
EOF
  run_smoke "$runner" "$smoke_log" "$version"

  # Non-shipped host-execution test runner. Built when CONSENT_BUILD_TEST_RUNNER is
  # set: the gambit-native white-box shard runs the suite against it to test the
  # COMPILED interpreter (every lane, including per-push). A plain `make compile'
  # (the install path) leaves it unset and skips this second full `gsc -exe' link,
  # which recompiles the entire module set and is the single largest build cost.
  if [ -n "${CONSENT_BUILD_TEST_RUNNER:-}" ]; then
    host_runner_main="$src_dir/consent-host-runner.scm"
    host_runner_main_c="$src_dir/consent-host-runner.c"
    host_runner="$bin_dir/consent-host-runner"
    write_gambit_host_runner_main "$host_runner_main" "$src_dir"
    "$gsc" -:r7rs,search="$scheme_dir",search="$src_dir" \
      -c -o "$host_runner_main_c" "$host_runner_main" \
      >>"$logs_dir/gsc-modules.log" 2>&1 \
      || die "gsc failed while compiling the Gambit host runner; see $logs_dir/gsc-modules.log"
    # shellcheck disable=SC2086
    "$gsc" -:r7rs,search="$scheme_dir" -exe -o "$host_runner" -nopreload $gambit_c_files "$host_runner_main_c" \
      >"$logs_dir/gsc-exe-host-runner.log" 2>&1 \
      || die "gsc -exe (host runner) failed; see $logs_dir/gsc-exe-host-runner.log"
    [ -f "$host_runner" ] \
      || die "gsc -exe did not create $host_runner; see $logs_dir/gsc-exe-host-runner.log"
    chmod +x "$host_runner"
  fi

  printf '%s\n' "$runner"
}

case "$compile_host" in
  racket)
    compile_racket
    ;;
  gambit)
    compile_gambit
    ;;
  *)
    die "CONSENT_COMPILE_HOST must be one of: racket, gambit"
    ;;
esac
