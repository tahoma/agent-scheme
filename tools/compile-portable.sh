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
# execution.
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

# Internal libraries whose compiled modules the generated main registers in the
# runtime's native-library registry: library key | path under scheme/ | the
# main's import prefix. Under the internal-libraries grant the resolver binds
# imports of these keys to the compiled modules directly (the product serving
# as its own host runner) instead of re-interpreting their source.
native_library_table() {
  cat <<'EOF'
(agent task)|agent/task.sld|consent-main:agent-task:
(agent transcript)|agent/transcript.sld|consent-main:agent-transcript:
(agent registry)|agent/registry.sld|consent-main:agent-registry:
(agent proposal)|agent/proposal.sld|consent-main:agent-proposal:
(consent approval)|consent/approval.sld|consent-main:approval:
(consent base)|consent/base.sld|consent-main:base:
(consent context)|consent/context.sld|consent-main:context:
(consent eval)|consent/eval.sld|consent-main:eval:
(consent helper)|consent/helper.sld|consent-main:helper:
(consent interpreter)|consent/interpreter.sld|consent-main:interpreter:
(consent job)|consent/job.sld|consent-main:job:
(consent library)|consent/library.sld|consent-main:library:
(consent macro)|consent/macro.sld|consent-main:macro:
(consent memory)|consent/memory.sld|consent-main:memory:
(consent plan)|consent/plan.sld|consent-main:plan:
(consent reader)|consent/reader.sld|consent-main:reader:
(consent redaction)|consent/redaction.sld|consent-main:redaction:
(consent runtime)|consent/runtime.sld|consent-main:runtime:
(consent session)|consent/session.sld|consent-main:session:
(consent version)|consent/version.sld|consent-main:version:
(cli native-cli)|cli/native-cli.sld|consent-main:cli-native-cli:
(cli process-host)|cli/process-host.sld|consent-main:cli-process-host:
(cli repl-chrome)|cli/repl-chrome.sld|consent-main:cli-repl-chrome:
(cli repl-shell)|cli/repl-shell.sld|consent-main:cli-repl-shell:
(cli script)|cli/script.sld|consent-main:cli-script:
EOF
}

# Generate the native-library registration forms the generated main evaluates at
# startup. Export lists are extracted from each library's define-library form by
# the compile host's own reader (handling (rename internal external) clauses), so
# the registry is single-sourced from the .sld files rather than hand-maintained.
write_native_library_registrations() {
  registrations_file=$1

  extract_file="$build_dir/native-library-exports-extract.scm"
  {
    printf '%s\n' '(import (scheme base) (scheme file) (scheme read) (scheme write))'
    printf '%s\n' '(define library-files'
    printf '%s\n' '  (list'
    native_library_table | while IFS='|' read -r key path prefix; do
      [ -n "$key" ] || continue
      printf '    "%s/%s"\n' "$scheme_dir" "$path"
    done
    printf '%s\n' '    ))'
    cat <<'EOF'
(for-each
 (lambda (path)
   (call-with-input-file path
     (lambda (port)
       (let ((form (read port)))
         (for-each
          (lambda (clause)
            (if (and (pair? clause) (eq? (car clause) 'export))
                (for-each
                 (lambda (entry)
                   (display path)
                   (display "\t")
                   (write (if (pair? entry) (car (cddr entry)) entry))
                   (newline))
                 (cdr clause))))
          (cddr form))))))
 library-files)
EOF
  } > "$extract_file"

  case "$compile_host" in
    gambit)
      exports=$("$gsi" -:r7rs "$extract_file") \
        || die "could not extract native library exports via gsi"
      ;;
    racket)
      extract_rkt="$build_dir/native-library-exports-extract.rkt"
      { printf '%s\n' '#lang r7rs'; cat "$extract_file"; } > "$extract_rkt"
      exports=$("$racket" "$extract_rkt") \
        || { rm -f "$extract_rkt"; die "could not extract native library exports via racket"; }
      rm -f "$extract_rkt"
      ;;
    *)
      die "cannot extract native library exports for host $compile_host"
      ;;
  esac

  [ -n "$exports" ] || die "native library export extraction produced no entries"

  {
    printf '\n%s\n' ';; Register the compiled internal libraries in the native-library registry'
    printf '%s\n' ';; so imports made under the internal-libraries grant bind to the modules'
    printf '%s\n' ';; linked into this executable (the product serving as its own host runner).'
    native_library_table | while IFS='|' read -r key path prefix; do
      [ -n "$key" ] || continue
      printf '(consent-main:runtime:consent-register-native-library!\n'
      printf " '%s\n" "$key"
      printf ' (list\n'
      printf '%s\n' "$exports" | awk -F'\t' -v p="$scheme_dir/$path" -v prefix="$prefix" '
        $1 == p && !seen[$2]++ {
          printf "  (cons (quote %s) %s%s)\n", $2, prefix, $2
        }'
      printf '  ))\n'
    done
  } > "$registrations_file"
}

# Write a `(consent embedded-source)' library whose exported installer registers
# each embedded source string with the runtime. SOURCE_LIST is the newline-
# separated set of canonical relative paths from enumerate_runtime_source_files
# (the zero-dependency bootstrap floor). The source text is emitted as a Scheme
# string literal by escaping only backslash and double-quote (R7RS string literals
# admit literal newlines), so the embedded text round-trips byte-for-byte back
# through the reader. LANG_HEADER is `#lang r7rs' for Racket, empty for Gambit.
write_embedded_source_module() {
  lang_header=$1
  source_list=$2

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
  }
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
        (prefix (agent registry) consent-main:agent-registry:)
        (prefix (agent proposal) consent-main:agent-proposal:)
        (prefix (consent approval) consent-main:approval:)
        (prefix (consent base) consent-main:base:)
        (prefix (consent context) consent-main:context:)
        (prefix (consent eval) consent-main:eval:)
        (prefix (consent helper) consent-main:helper:)
        (prefix (consent interpreter) consent-main:interpreter:)
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
        (prefix (consent version) consent-main:version:)
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
  (display "  --color=WHEN    Colorize chrome: auto (default), always, never.\n")
  (display "  --replay FILE   Replay a captured transcript, exiting non-zero if\n")
  (display "                  the replay diverged from the captured outcomes.\n"))

(define (consent-main-error message)
  (display "consent: " (current-error-port))
  (display message (current-error-port))
  (newline (current-error-port))
  (exit 2))

(define (consent-main-stdio-options options)
  ;; Attach the process standard streams to OPTIONS so an evaluated --eval/--script
  ;; program reads stdin and writes stdout/stderr.  The standard streams are
  ;; consented by invocation -- what the shell handed this process -- so the host
  ;; supplies a stdin reader, stdout/stderr writers, and one port grant per stream,
  ;; and the runtime connects current-input/output/error from them.  Ambient
  ;; effects (files, processes, network, ...) still fail closed without a grant,
  ;; and no raw host port is exposed to Scheme.
  (append
   (list
    (cons 'program-input-reader
          (lambda ()
            (let ((line (read-line)))
              (if (eof-object? line) #f (string-append line "\n")))))
    (cons 'program-output-writer
          (lambda (text) (display text) (flush-output-port)))
    (cons 'program-error-writer
          (lambda (text)
            (display text (current-error-port))
            (flush-output-port (current-error-port))))
    (list 'capability-grants
          (list 'capability-grant (list 'id 'program-input) (list 'domain 'port)
                (cons 'operations '(read close))
                (list 'scope (list 'backing 'stdin)) (list 'expires 'never))
          (list 'capability-grant (list 'id 'program-output) (list 'domain 'port)
                (cons 'operations '(write flush close))
                (list 'scope (list 'backing 'stdout)) (list 'expires 'never))
          (list 'capability-grant (list 'id 'program-error) (list 'domain 'port)
                (cons 'operations '(write flush close))
                (list 'scope (list 'backing 'stderr)) (list 'expires 'never))))
   options))

(define (consent-main-eval source options)
  (guard (condition
          (else
           (display "consent: evaluation failed" (current-error-port))
           (display ": " (current-error-port))
           (write condition (current-error-port))
           (newline (current-error-port))
           (exit 1)))
    (display
     (consent-value->external
      (consent-eval-source source #f (consent-main-stdio-options options))))
    (newline)))

(define (consent-main-script path options)
  (guard (condition
          (else
           (display "consent: script failed" (current-error-port))
           (display ": " (current-error-port))
           (write condition (current-error-port))
           (newline (current-error-port))
           (exit 1)))
    ;; Run the script through the Consent interpreter with the standard streams
    ;; connected by invocation (capability-gated; ambient effects still fail closed;
    ;; no raw host objects exposed) -- the same gated path as --eval and the Emacs
    ;; `consent-script-run-file' twin.
    (consent-main:cli-script:cli-script-run-file
     path #f (consent-main-stdio-options options))))

(define (consent-main-host-run path)
  ;; Run a Consent-Scheme host-runner test file on THIS runtime: every form is
  ;; evaluated through the runtime's own interpreter under the host-run
  ;; capability bundle, program output is streamed to real stdout, and the exit
  ;; code is non-zero exactly when a captured test assertion raised. This is the
  ;; product serving as its own host runner -- no separate host-load binary.
  (guard (condition
          (else
           (display "consent: host-run failed" (current-error-port))
           (display ": " (current-error-port))
           (write condition (current-error-port))
           (newline (current-error-port))
           (exit 1)))
    (let ((outcome
           (consent-main:cli-script:cli-script-host-run-file
            path
            ;; Scope file access and includes to the invoking working directory.
            ;; PWD is the shell-provided absolute cwd; fall back to "." so a run
            ;; that performs no file I/O (e.g. the reader suite) still works.
            (let ((pwd (get-environment-variable "PWD")))
              (if (and pwd (> (string-length pwd) 0)) pwd "."))
            (lambda (chunk) (display chunk)))))
      (if (eq? outcome #t)
          (exit 0)
          (begin
            (display "consent: host-run failed: " (current-error-port))
            (write outcome (current-error-port))
            (newline (current-error-port))
            (exit 1))))))

(define (consent-main args)
  ;; A leading --internal-libraries grant lets the program import the runtime's
  ;; own (consent ...)/(cli ...) libraries from source -- the deliberate host
  ;; capability that turns the product into a Consent-Scheme host runner. It is
  ;; off by default, keeping the bare command surface fail-closed.
  (let* ((host? (and (pair? args)
                     (string=? (car args) "--internal-libraries")))
         (options (if host? '((internal-libraries-allowed . #t)) '()))
         (args (if host? (cdr args) args)))
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
          (consent-main-eval (cadr args) options)))
     ((string=? (car args) "--script")
      (if (null? (cdr args))
          (consent-main-error "--script requires FILE")
          (consent-main-script (cadr args) options)))
     ((string=? (car args) "--host-run")
      ;; Run FILE as a host-runner test on this runtime (internal libraries,
      ;; captured program output, raised budgets, exit code from assertions).
      (if (null? (cdr args))
          (consent-main-error "--host-run requires FILE")
          (consent-main-host-run (cadr args))))
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
      (consent-main-script (car args) options)))))

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
  registrations_file=$1

  write_racket_main_common
  cat "$registrations_file"
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
}

# Emit the shared Gambit main body (imports + helpers + dispatch, no startup).
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
        (prefix (agent registry) consent-main:agent-registry:)
        (prefix (agent proposal) consent-main:agent-proposal:)
        (prefix (consent approval) consent-main:approval:)
        (prefix (consent base) consent-main:base:)
        (prefix (consent context) consent-main:context:)
        (prefix (consent eval) consent-main:eval:)
        (prefix (consent helper) consent-main:helper:)
        (prefix (consent interpreter) consent-main:interpreter:)
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
        (prefix (consent version) consent-main:version:)
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
  (display "  --color=WHEN    Colorize chrome: auto (default), always, never.\n")
  (display "  --replay FILE   Replay a captured transcript, exiting non-zero if\n")
  (display "                  the replay diverged from the captured outcomes.\n"))

(define (consent-main-error message)
  (display "consent: " (current-error-port))
  (display message (current-error-port))
  (newline (current-error-port))
  (exit 2))

(define (consent-main-stdio-options options)
  ;; Attach the process standard streams to OPTIONS so an evaluated --eval/--script
  ;; program reads stdin and writes stdout/stderr.  The standard streams are
  ;; consented by invocation -- what the shell handed this process -- so the host
  ;; supplies a stdin reader, stdout/stderr writers, and one port grant per stream,
  ;; and the runtime connects current-input/output/error from them.  Ambient
  ;; effects (files, processes, network, ...) still fail closed without a grant,
  ;; and no raw host port is exposed to Scheme.
  (append
   (list
    (cons 'program-input-reader
          (lambda ()
            (let ((line (read-line)))
              (if (eof-object? line) #f (string-append line "\n")))))
    (cons 'program-output-writer
          (lambda (text) (display text) (flush-output-port)))
    (cons 'program-error-writer
          (lambda (text)
            (display text (current-error-port))
            (flush-output-port (current-error-port))))
    (list 'capability-grants
          (list 'capability-grant (list 'id 'program-input) (list 'domain 'port)
                (cons 'operations '(read close))
                (list 'scope (list 'backing 'stdin)) (list 'expires 'never))
          (list 'capability-grant (list 'id 'program-output) (list 'domain 'port)
                (cons 'operations '(write flush close))
                (list 'scope (list 'backing 'stdout)) (list 'expires 'never))
          (list 'capability-grant (list 'id 'program-error) (list 'domain 'port)
                (cons 'operations '(write flush close))
                (list 'scope (list 'backing 'stderr)) (list 'expires 'never))))
   options))

(define (consent-main-eval source options)
  (guard (condition
          (else
           (display "consent: evaluation failed" (current-error-port))
           (display ": " (current-error-port))
           (write condition (current-error-port))
           (newline (current-error-port))
           (exit 1)))
    (display
     (consent-value->external
      (consent-eval-source source #f (consent-main-stdio-options options))))
    (newline)))

(define (consent-main-script path options)
  (guard (condition
          (else
           (display "consent: script failed" (current-error-port))
           (display ": " (current-error-port))
           (write condition (current-error-port))
           (newline (current-error-port))
           (exit 1)))
    ;; Run the script through the Consent interpreter with the standard streams
    ;; connected by invocation (capability-gated; ambient effects still fail closed;
    ;; no raw host objects exposed) -- the same gated path as --eval and the Emacs
    ;; `consent-script-run-file' twin.
    (consent-main:cli-script:cli-script-run-file
     path #f (consent-main-stdio-options options))))

(define (consent-main-host-run path)
  ;; Run a Consent-Scheme host-runner test file on THIS runtime: every form is
  ;; evaluated through the runtime's own interpreter under the host-run
  ;; capability bundle, program output is streamed to real stdout, and the exit
  ;; code is non-zero exactly when a captured test assertion raised. This is the
  ;; product serving as its own host runner -- no separate host-load binary.
  (guard (condition
          (else
           (display "consent: host-run failed" (current-error-port))
           (display ": " (current-error-port))
           (write condition (current-error-port))
           (newline (current-error-port))
           (exit 1)))
    (let ((outcome
           (consent-main:cli-script:cli-script-host-run-file
            path
            ;; Scope file access and includes to the invoking working directory.
            ;; PWD is the shell-provided absolute cwd; fall back to "." so a run
            ;; that performs no file I/O (e.g. the reader suite) still works.
            (let ((pwd (get-environment-variable "PWD")))
              (if (and pwd (> (string-length pwd) 0)) pwd "."))
            (lambda (chunk) (display chunk)))))
      (if (eq? outcome #t)
          (exit 0)
          (begin
            (display "consent: host-run failed: " (current-error-port))
            (write outcome (current-error-port))
            (newline (current-error-port))
            (exit 1))))))

(define (consent-main args)
  ;; A leading --internal-libraries grant lets the program import the runtime's
  ;; own (consent ...)/(cli ...) libraries from source -- the deliberate host
  ;; capability that turns the product into a Consent-Scheme host runner. It is
  ;; off by default, keeping the bare command surface fail-closed.
  (let* ((host? (and (pair? args)
                     (string=? (car args) "--internal-libraries")))
         (options (if host? '((internal-libraries-allowed . #t)) '()))
         (args (if host? (cdr args) args)))
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
          (consent-main-eval (cadr args) options)))
     ((string=? (car args) "--script")
      (if (null? (cdr args))
          (consent-main-error "--script requires FILE")
          (consent-main-script (cadr args) options)))
     ((string=? (car args) "--host-run")
      ;; Run FILE as a host-runner test on this runtime (internal libraries,
      ;; captured program output, raised budgets, exit code from assertions).
      (if (null? (cdr args))
          (consent-main-error "--host-run requires FILE")
          (consent-main-host-run (cadr args))))
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
      (consent-main-script (car args) options)))))

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
  registrations_file=$3

  printf '#!gsi -:r7rs,search=%s\n' "$search_dir" > "$main_file"
  {
    write_gambit_main_common
    cat "$registrations_file"
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

# Replace $1 with stdin only when the bytes differ, leaving an unchanged target's
# mtime intact. The Racket compilation manager keys cached bytecode on source
# timestamps, so unconditionally rewriting every generated file would invalidate
# every `.zo' each run; this keeps untouched generated sources stable so `raco
# make' reuses their bytecode across runs.
write_if_changed() {
  wic_target=$1
  wic_tmp="$wic_target.tmp.$$"

  cat > "$wic_tmp"
  if [ -f "$wic_target" ] && cmp -s "$wic_tmp" "$wic_target"; then
    rm -f "$wic_tmp"
  else
    mv "$wic_tmp" "$wic_target"
  fi
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
    } | write_if_changed "$target"
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

# Resolve the parallel-compile width. CONSENT_COMPILE_JOBS overrides; otherwise
# the online CPU count, falling back to 4 when it cannot be probed and clamping a
# probed 0 up to 1.
consent_compile_jobs() {
  if [ -n "${CONSENT_COMPILE_JOBS:-}" ]; then
    printf '%s\n' "$CONSENT_COMPILE_JOBS"
    return
  fi
  jobs_n=
  if command -v nproc >/dev/null 2>&1; then
    jobs_n=$(nproc 2>/dev/null)
  elif command -v getconf >/dev/null 2>&1; then
    jobs_n=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
  fi
  case "$jobs_n" in
    '' | *[!0-9]*) printf '%s\n' 4 ;;
    0) printf '%s\n' 1 ;;
    *) printf '%s\n' "$jobs_n" ;;
  esac
}

# Content-hash command resolved once into consent_hash_command. It reads stdin and
# prints a digest as its first whitespace-delimited field. Left empty when no
# hasher is available, which disables the incremental skip (every module is then
# recompiled) rather than risking a stale object.
consent_hash_command=
detect_hash_command() {
  if command -v sha256sum >/dev/null 2>&1; then
    consent_hash_command="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    consent_hash_command="shasum -a 256"
  elif command -v cksum >/dev/null 2>&1; then
    consent_hash_command="cksum"
  fi
}

# Print the digest of stdin using the resolved content-hash command.
hash_stdin() {
  $consent_hash_command | awk '{print $1; exit}'
}

# Run worker function $1 once per newline-delimited task read on stdin, at most $2
# concurrently, using a FIFO token semaphore (POSIX mkfifo/exec/read; no `wait -n`
# dependency, so it works under dash on the CI runners). The worker receives its
# task as "$1" and records a failure by creating a file under a stamp directory it
# shares with the caller, which treats a non-empty stamp directory as a build
# failure. Each child releases its token from an EXIT trap, so a worker fault can
# never deadlock the pool.
run_compile_pool() {
  pool_worker=$1
  pool_max=$2

  pool_dir=$(mktemp -d "${TMPDIR:-/tmp}/consent-pool.XXXXXX") \
    || die "could not create the compile worker pool directory"
  mkfifo "$pool_dir/tokens" \
    || { rm -rf "$pool_dir"; die "could not create the compile worker pool semaphore"; }
  # Open the token FIFO read/write on fd 8 so seeding does not block on a reader.
  exec 8<>"$pool_dir/tokens"
  pool_i=0
  while [ "$pool_i" -lt "$pool_max" ]; do
    printf '\n' >&8
    pool_i=$((pool_i + 1))
  done

  while IFS= read -r pool_task; do
    [ -n "$pool_task" ] || continue
    IFS= read -r _ <&8 || break
    (
      trap 'printf "\n" >&8 2>/dev/null' EXIT
      "$pool_worker" "$pool_task" </dev/null
    ) &
  done

  wait
  exec 8>&-
  rm -rf "$pool_dir"
}

# Emit the Scheme program that prints, for every compile unit, its transitive
# project-import closure as a `label<TAB>path ...` line. The closure is the set of
# project source files the unit's compiled object can depend on: its own source,
# every project library it imports (transitively, unwrapping only/except/prefix/
# rename and descending into every cond-expand branch and include), and the
# single-sourced standard libraries. (consent version) is a structurally-guarded
# leaf: it is emitted as a fixed sentinel for every dependent, so the
# every-branch version bump changes only the version unit's own hash (forcing the
# version module to recompile and the executable to relink) without invalidating
# any dependent. The runtime reads the version datum at run time through the
# separately compiled version module, so no dependent bakes the value in.
write_gambit_closure_program() {
  program_file=$1
  all_sld_file=$2
  units_file=$3
  version_source=$4

  {
    printf '%s\n' '(import (scheme base) (scheme file) (scheme read) (scheme write))'
    printf '(define all-sld-file "%s")\n' "$all_sld_file"
    printf '(define units-file "%s")\n' "$units_file"
    printf '(define version-path "%s")\n' "$version_source"
    cat <<'SCHEME'
(define sentinel "@@consent-version-structural@@")

(define (read-lines path)
  (call-with-input-file path
    (lambda (p)
      (let loop ((acc '()))
        (let ((line (read-line p)))
          (if (eof-object? line)
              (reverse acc)
              (loop (if (= 0 (string-length line)) acc (cons line acc)))))))))

(define (split-tab line)
  (let loop ((i 0))
    (cond
     ((>= i (string-length line)) (cons line ""))
     ((char=? (string-ref line i) #\tab)
      (cons (substring line 0 i)
            (substring line (+ i 1) (string-length line))))
     (else (loop (+ i 1))))))

(define (file->string path)
  (call-with-input-file path
    (lambda (p)
      (let loop ((chunks '()))
        (let ((chunk (read-string 65536 p)))
          (if (eof-object? chunk)
              (apply string-append (reverse chunks))
              (loop (cons chunk chunks))))))))

(define (strip-shebang s)
  (if (and (>= (string-length s) 2)
           (char=? (string-ref s 0) #\#)
           (char=? (string-ref s 1) #\!))
      (let loop ((i 0))
        (cond
         ((>= i (string-length s)) "")
         ((char=? (string-ref s i) #\newline)
          (substring s (+ i 1) (string-length s)))
         (else (loop (+ i 1)))))
      s))

(define (forms-of path)
  (let ((port (open-input-string (strip-shebang (file->string path)))))
    (let loop ((acc '()))
      (let ((form (read port)))
        (if (eof-object? form) (reverse acc) (loop (cons form acc)))))))

(define all-sld (read-lines all-sld-file))
(define units (map split-tab (read-lines units-file)))

(define name->path
  (let loop ((files all-sld) (acc '()))
    (if (null? files)
        acc
        (let* ((path (car files))
               (forms (forms-of path))
               (form (if (pair? forms) (car forms) #f))
               (name (and (pair? form)
                          (eq? (car form) 'define-library)
                          (cadr form))))
          (loop (cdr files) (if name (cons (cons name path) acc) acc))))))

(define (resolve-library name)
  (let ((cell (assoc name name->path)))
    (and cell (cdr cell))))

(define (dir-of path)
  (let loop ((i (- (string-length path) 1)))
    (cond
     ((< i 0) "")
     ((char=? (string-ref path i) #\/) (substring path 0 (+ i 1)))
     (else (loop (- i 1))))))

(define (spec->library spec)
  (cond
   ((not (pair? spec)) #f)
   ((memq (car spec) '(only except prefix rename)) (spec->library (cadr spec)))
   (else spec)))

(define (collect-deps clause base-dir add!)
  (when (pair? clause)
    (let ((head (car clause)))
      (cond
       ((eq? head 'import)
        (for-each
         (lambda (spec)
           (let* ((lib (spec->library spec))
                  (path (and lib (resolve-library lib))))
             (when path (add! path))))
         (cdr clause)))
       ((or (eq? head 'include) (eq? head 'include-ci))
        (for-each
         (lambda (f) (when (string? f) (add! (string-append base-dir f))))
         (cdr clause)))
       ((eq? head 'cond-expand)
        (for-each
         (lambda (branch)
           (when (pair? branch)
             (for-each (lambda (c) (collect-deps c base-dir add!)) (cdr branch))))
         (cdr clause)))
       (else #f)))))

(define (direct-deps path)
  (let ((deps '())
        (base-dir (dir-of path)))
    (for-each
     (lambda (form)
       (cond
        ((and (pair? form) (eq? (car form) 'import))
         (collect-deps form base-dir (lambda (d) (set! deps (cons d deps)))))
        ((and (pair? form) (eq? (car form) 'define-library))
         (for-each
          (lambda (clause)
            (collect-deps clause base-dir (lambda (d) (set! deps (cons d deps)))))
          (cddr form)))
        (else #f)))
     (forms-of path))
    deps))

(define (closure unit-path)
  (let loop ((queue (list unit-path)) (seen '()))
    (cond
     ((null? queue) seen)
     ((member (car queue) seen) (loop (cdr queue) seen))
     (else
      (let ((cur (car queue)))
        (loop (append (direct-deps cur) (cdr queue))
              (cons cur seen)))))))

(for-each
 (lambda (unit)
   (let* ((label (car unit))
          (unit-path (cdr unit))
          (paths (closure unit-path)))
     (display label)
     (write-char #\tab)
     (let loop ((ps paths) (first #t))
       (unless (null? ps)
         (unless first (write-char #\space))
         (display (let ((p (car ps)))
                    (if (and (string=? p version-path)
                             (not (string=? unit-path version-path)))
                        sentinel
                        p)))
         (loop (cdr ps) #f)))
     (newline)))
 units)
SCHEME
  } > "$program_file"
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

  racket_jobs=$(consent_compile_jobs)
  mkdir -p "$src_dir" "$collections_dir" "$bin_dir" "$logs_dir"

  # Generate the collection tree write-if-changed so unchanged generated sources
  # keep their mtime and Racket's compilation manager reuses their bytecode.
  generate_racket_collections "$collections_dir"

  # Build the (consent library) closure to bytecode before enumeration so the
  # enumeration run reuses the bytecode instead of expanding the library stack in
  # memory; without this the cold build would expand the stack once here and again
  # under raco exe.
  PLTCOLLECTS="$collections_dir:${PLTCOLLECTS:-}" \
    "$raco" make -j "$racket_jobs" "$collections_dir/consent/library.rkt" \
    >"$logs_dir/raco-make-library.log" 2>&1 \
    || die "raco make of the runtime library closure failed; see $logs_dir/raco-make-library.log"

  runtime_source_list=$(enumerate_runtime_source_files)
  mkdir -p "$collections_dir/consent"
  write_embedded_source_module '#lang r7rs' "$runtime_source_list" \
    | write_if_changed "$collections_dir/consent/embedded-source.rkt"
  write_runtime_source_manifest "$host_root" "$runtime_source_list"
  registrations_file="$src_dir/native-library-registrations.scm"
  write_native_library_registrations "$registrations_file"
  write_racket_main "$registrations_file" | write_if_changed "$main_file"
  assert_product_main_gated "$main_file"
  write_manifest "$host_root" racket "$version"

  # Build the full product closure to bytecode once; raco exe then links from the
  # bytecode rather than expanding the library stack a second time. On a warm
  # cache only the changed modules (for example the every-branch version bump)
  # recompile, since write-if-changed preserved the other sources' timestamps.
  PLTCOLLECTS="$collections_dir:${PLTCOLLECTS:-}" \
    "$raco" make -j "$racket_jobs" "$main_file" \
    >"$logs_dir/raco-make-main.log" 2>&1 \
    || die "raco make of the product main failed; see $logs_dir/raco-make-main.log"

  PLTCOLLECTS="$collections_dir:${PLTCOLLECTS:-}" \
    "$raco" exe --cs ++lang r7rs -o "$runner" "$main_file" \
    >"$logs_dir/raco-exe.log" 2>&1 \
    || die "raco exe failed; see $logs_dir/raco-exe.log"

  [ -f "$runner" ] \
    || die "raco exe did not create $runner; see $logs_dir/raco-exe.log"
  chmod +x "$runner"
  run_smoke "$runner" "$smoke_log" "$version"

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
    "$scheme_dir/agent/registry.sld" \
    "$src_dir/agent/registry.sld"
  copy_gambit_source \
    "$scheme_dir/agent/proposal.sld" \
    "$src_dir/agent/proposal.sld"
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

  registrations_file="$src_dir/native-library-registrations.scm"
  write_native_library_registrations "$registrations_file"
  write_gambit_main "$main_file" "$src_dir" "$registrations_file"
  assert_product_main_gated "$main_file"
  write_manifest "$host_root" gambit "$version"
  runtime_source_list=$(enumerate_runtime_source_files)
  write_runtime_source_manifest "$host_root" "$runtime_source_list"
  write_embedded_source_module '' "$runtime_source_list" > "$src_dir/consent/embedded-source.sld"
  detect_hash_command
  compile_jobs=$(consent_compile_jobs)
  tab=$(printf '\t')
  version_sentinel='@@consent-version-structural@@'

  # Ordered Consent Scheme module list. This is also the executable link order;
  # the per-module compiled artifacts are $src_dir/<ref>.c and $src_dir/<ref>.o.
  # (consent embedded-source) is generated into $src_dir; every other module's
  # source lives under $scheme_dir.
  gambit_module_order='consent/version consent/reader consent/runtime consent/base consent/library consent/result consent/macro consent/approval consent/context consent/helper consent/job consent/memory consent/plan consent/redaction consent/session agent/task agent/transcript agent/registry agent/proposal consent/interpreter consent/eval cli/process-host cli/native-cli cli/repl-chrome cli/repl-shell cli/script consent/embedded-source'

  gambit_module_source() {
    case "$1" in
      consent/embedded-source) printf '%s\n' "$src_dir/consent/embedded-source.sld" ;;
      *) printf '%s\n' "$scheme_dir/$1.sld" ;;
    esac
  }

  # Compute the per-unit content hashes that drive the incremental skip. The
  # closure analysis runs the interpreter's own reader, so a future reader-level
  # construct it cannot parse degrades to a full recompile (the program exits
  # non-zero) rather than silently under-approximating a dependency.
  incremental_dir="$host_root/incremental"
  mkdir -p "$incremental_dir"
  all_sld_file="$incremental_dir/all-sld.txt"
  units_file="$incremental_dir/units.txt"
  closures_file="$incremental_dir/closures.txt"
  modulehash_file="$incremental_dir/module-hashes.txt"
  closure_program="$incremental_dir/closure.scm"
  stamp_dir="$incremental_dir/stamps"
  rm -rf "$stamp_dir"
  mkdir -p "$stamp_dir"

  use_incremental=false
  if [ -n "$consent_hash_command" ]; then
    {
      find "$scheme_dir" -type f -name '*.sld'
      printf '%s\n' "$src_dir/consent/embedded-source.sld"
    } | sort > "$all_sld_file"
    : > "$units_file"
    for ref in $gambit_module_order; do
      printf '%s\t%s\n' "$ref" "$(gambit_module_source "$ref")" >> "$units_file"
    done
    printf '%s\t%s\n' main "$main_file" >> "$units_file"

    write_gambit_closure_program \
      "$closure_program" "$all_sld_file" "$units_file" "$scheme_dir/consent/version.sld"
    if "$gsi" -:r7rs "$closure_program" > "$closures_file" 2>"$logs_dir/gambit-closure.log"; then
      script_hash=$(hash_stdin < "$script_dir/$(basename -- "$0")" 2>/dev/null || true)
      gsc_identity=$("$gsc" -v 2>/dev/null | head -n 1)
      : > "$modulehash_file"
      # Per unit, fold every closure source file's content hash (the version leaf
      # as a fixed token), the compiler identity, and this script's text into one
      # digest. Sorting makes the digest independent of closure traversal order.
      while IFS="$tab" read -r unit_label unit_paths; do
        unit_digest=$(
          {
            printf 'gsc\t%s\n' "$gsc_identity"
            printf 'script\t%s\n' "$script_hash"
            for unit_path in $unit_paths; do
              if [ "$unit_path" = "$version_sentinel" ]; then
                printf 'version\tSTRUCTURAL\n'
              else
                printf '%s\t%s\n' "$unit_path" "$(hash_stdin < "$unit_path")"
              fi
            done
          } | sort | hash_stdin
        )
        printf '%s\t%s\n' "$unit_label" "$unit_digest" >> "$modulehash_file"
      done < "$closures_file"
      use_incremental=true
    else
      printf '%s\n' "consent compile: Gambit closure analysis failed; recompiling every module (see $logs_dir/gambit-closure.log)" >&2
    fi
  fi

  # Compile one unit: skip when its stored hash still matches, else run the
  # Scheme->C (gsc -c) and C->object (gsc -obj) passes and persist the new hash.
  # Failures are recorded as stamp files; the parent aggregates them after the
  # pool drains so one module's error does not abort sibling workers mid-flight.
  compile_gambit_unit() {
    cgu_ref=${1%%|*}
    cgu_rest=${1#*|}
    cgu_src=${cgu_rest%%|*}
    cgu_rest=${cgu_rest#*|}
    cgu_search=${cgu_rest%%|*}
    cgu_rest=${cgu_rest#*|}
    cgu_cout=${cgu_rest%%|*}
    cgu_oout=${cgu_rest#*|}
    cgu_safe=$(printf '%s' "$cgu_ref" | tr '/' '-')
    cgu_log="$logs_dir/gsc-$cgu_safe.log"
    cgu_hashfile="$cgu_oout.hash"

    cgu_expected=
    if $use_incremental; then
      cgu_expected=$(awk -F"$tab" -v l="$cgu_ref" '$1 == l { print $2; exit }' "$modulehash_file")
    fi

    if [ -n "$cgu_expected" ] && [ -f "$cgu_cout" ] && [ -f "$cgu_oout" ] \
      && [ -f "$cgu_hashfile" ] && [ "$(cat "$cgu_hashfile")" = "$cgu_expected" ]; then
      return 0
    fi

    mkdir -p "$(dirname -- "$cgu_cout")"
    : > "$cgu_log"
    # Clear the stored hash before recompiling so an interrupted or failed pass
    # can never leave behind an object that a later run would treat as current;
    # on failure the partial .c/.o are removed too, so the skip check only ever
    # finds a complete, hash-matched pair.
    rm -f "$cgu_hashfile"
    cgu_moduleflag=
    if [ "$cgu_ref" != "main" ]; then
      cgu_moduleflag="-module-ref $cgu_ref"
    fi
    # Record each pass's real exit status (128+signal when the kernel kills a
    # compiler, e.g. 137 for an out-of-memory SIGKILL) into the per-unit log, so
    # a failure that emits no compiler diagnostics is still diagnosable instead
    # of leaving an empty log behind.
    cgu_rc=0
    # shellcheck disable=SC2086
    "$gsc" -:r7rs,"$cgu_search" -c $cgu_moduleflag -o "$cgu_cout" "$cgu_src" \
      >>"$cgu_log" 2>&1 || cgu_rc=$?
    if [ "$cgu_rc" -ne 0 ]; then
      printf 'consent compile: gsc -c exited %s for %s\n' "$cgu_rc" "$cgu_ref" >>"$cgu_log"
      rm -f "$cgu_cout" "$cgu_oout"
      printf '%s\n' "$cgu_ref" > "$stamp_dir/$cgu_safe.fail"
      return 0
    fi
    cgu_rc=0
    "$gsc" -obj -o "$cgu_oout" "$cgu_cout" >>"$cgu_log" 2>&1 || cgu_rc=$?
    if [ "$cgu_rc" -ne 0 ]; then
      printf 'consent compile: gsc -obj exited %s for %s\n' "$cgu_rc" "$cgu_ref" >>"$cgu_log"
      rm -f "$cgu_cout" "$cgu_oout"
      printf '%s\n' "$cgu_ref" > "$stamp_dir/$cgu_safe.fail"
      return 0
    fi
    if [ -n "$cgu_expected" ]; then
      printf '%s\n' "$cgu_expected" > "$cgu_hashfile"
    fi
    return 0
  }

  search_default="search=$scheme_dir"
  search_main="search=$scheme_dir,search=$src_dir"

  # Emit the `ref|src|search|c-out|o-out` compile-unit tuple for one module ref,
  # shared by the parallel dispatch and the serial retry below so both build the
  # exact same task.
  gambit_module_task() {
    if [ "$1" = "main" ]; then
      printf '%s|%s|%s|%s|%s\n' \
        main "$main_file" "$search_main" "$main_c" "$src_dir/consent-main.o"
    else
      printf '%s|%s|%s|%s|%s\n' \
        "$1" "$(gambit_module_source "$1")" "$search_default" \
        "$src_dir/$1.c" "$src_dir/$1.o"
    fi
  }

  compile_started=$(date +%s)
  {
    for ref in $gambit_module_order; do
      gambit_module_task "$ref"
    done
    gambit_module_task main
  } | run_compile_pool compile_gambit_unit "$compile_jobs"

  # A module can fail under the parallel pool from transient resource contention
  # rather than a real translation error: the largest single-host C units (the
  # runtime and interpreter objects) each peak at several GB of compiler memory,
  # so a wide pool can drive a transient kill on exactly those units while every
  # other module succeeds. Retry any failed modules once, serially, before
  # giving up. A genuine error fails again in the aggregation below with its
  # captured diagnostics; a contention casualty compiles cleanly on its own. The
  # retry is announced so flakiness stays visible instead of silently absorbed,
  # and it is skipped entirely (no extra cost) on a clean parallel pass.
  if [ -n "$(ls -A "$stamp_dir" 2>/dev/null)" ]; then
    retry_refs=
    for stamp in "$stamp_dir"/*.fail; do
      [ -f "$stamp" ] || continue
      retry_refs="$retry_refs $(cat "$stamp")"
    done
    rm -f "$stamp_dir"/*.fail
    printf 'consent compile: parallel pass failed for%s; retrying serially\n' \
      "$retry_refs" >&2
    for ref in $retry_refs; do
      compile_gambit_unit "$(gambit_module_task "$ref")"
    done
  fi

  if [ -n "$(ls -A "$stamp_dir" 2>/dev/null)" ]; then
    for stamp in "$stamp_dir"/*.fail; do
      [ -f "$stamp" ] || continue
      failed_ref=$(cat "$stamp")
      failed_safe=$(printf '%s' "$failed_ref" | tr '/' '-')
      printf 'consent compile: gsc failed while compiling %s:\n' "$failed_ref" >&2
      [ -f "$logs_dir/gsc-$failed_safe.log" ] && cat "$logs_dir/gsc-$failed_safe.log" >&2
    done
    die "gsc failed while compiling one or more Gambit modules; see $logs_dir/gsc-*.log"
  fi

  # Link the executable once from the shared objects. The link file is generated
  # and compiled every build (cheap; it is non-deterministic so it is never
  # cached), then the final link reuses every pre-built object instead of
  # recompiling the generated C, which is the bulk of the build.
  gambit_o_files=
  gambit_c_files=
  for ref in $gambit_module_order; do
    gambit_o_files="$gambit_o_files $src_dir/$ref.o"
    gambit_c_files="$gambit_c_files $src_dir/$ref.c"
  done
  link_c="$src_dir/consent-main_.c"
  link_o="$src_dir/consent-main_.o"

  # shellcheck disable=SC2086
  "$gsc" -:r7rs,search="$scheme_dir" -link -o "$link_c" -nopreload $gambit_c_files "$main_c" \
    >"$logs_dir/gsc-link.log" 2>&1 \
    || die "gsc -link failed; see $logs_dir/gsc-link.log"
  "$gsc" -obj -o "$link_o" "$link_c" \
    >>"$logs_dir/gsc-link.log" 2>&1 \
    || die "gsc -obj failed for the link file; see $logs_dir/gsc-link.log"
  # shellcheck disable=SC2086
  "$gsc" -:r7rs,search="$scheme_dir" -exe -o "$runner" -nopreload \
    $gambit_o_files "$src_dir/consent-main.o" "$link_o" \
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
