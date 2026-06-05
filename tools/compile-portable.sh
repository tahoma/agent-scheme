#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Tahoma Toelkes

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

compile_host=${CONSENT_COMPILE_HOST:-racket}
build_dir=${CONSENT_COMPILE_BUILD_DIR:-"$repo_root/build/compile"}
case "$build_dir" in
  /*) ;;
  *) build_dir="$repo_root/$build_dir" ;;
esac
scheme_dir="$repo_root/scheme"
version_file="$scheme_dir/consent/version.sld"

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

write_racket_main() {
  main_file=$1

  cat > "$main_file" <<'EOF'
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
        (prefix (cli repl-shell) consent-main:cli-repl-shell:)
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
  (display "Usage: consent [--help] [--version] [--eval SOURCE] [--script FILE]\n")
  (display "\n")
  (display "Commands:\n")
  (display "  --help          Show this help.\n")
  (display "  --version       Print the Consent Scheme runtime version.\n")
  (display "  --eval SOURCE   Evaluate a pure Consent Scheme expression.\n")
  (display "  --script FILE   Run an R7RS Scheme source file.\n"))

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
    (load path (environment))))

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
   (else
    (consent-main-error
     (string-append "unknown option " (car args))))))

(let ((arguments (command-line)))
  (consent-main
   (if (null? arguments) '() (cdr arguments))))
EOF
}

write_gambit_main() {
  main_file=$1
  search_dir=$2

  printf '#!gsi -:r7rs,search=%s\n' "$search_dir" > "$main_file"
  cat >> "$main_file" <<'EOF'

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
        (prefix (cli repl-shell) consent-main:cli-repl-shell:)
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
  (display "Usage: consent [--help] [--version] [--eval SOURCE] [--script FILE]\n")
  (display "\n")
  (display "Commands:\n")
  (display "  --help          Show this help.\n")
  (display "  --version       Print the Consent Scheme runtime version.\n")
  (display "  --eval SOURCE   Evaluate a pure Consent Scheme expression.\n")
  (display "  --script FILE   Run an R7RS Scheme source file.\n"))

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
    (load path)))

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
   (else
    (consent-main-error
     (string-append "unknown option " (car args))))))

(let ((arguments (command-line)))
  (consent-main
   (if (null? arguments) '() (cdr arguments))))
EOF
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
  script_output=$("$runner" --script "$repo_root/tests/scheme/consent-reader-test.scm" 2>"$log_file.script.err") \
    || die "compiled runner failed --script reader smoke; see $log_file.script.err"

  if [ "$version_output" != "Consent Scheme $expected_version" ]; then
    die "compiled runner --version returned '$version_output', expected 'Consent Scheme $expected_version'"
  fi

  if [ "$eval_output" != "3" ]; then
    die "compiled runner --eval returned '$eval_output', expected '3'"
  fi

  if [ "$script_output" != "Scheme reader tests passed" ]; then
    die "compiled runner --script returned '$script_output', expected 'Scheme reader tests passed'"
  fi
  smoke_finished=$(date +%s)

  cat > "$log_file" <<EOF
(consent-compile-smoke
  (version-output "$version_output")
  (eval-output "$eval_output")
  (script-output "$script_output")
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
  write_racket_main "$main_file"
  write_manifest "$host_root" racket "$version"

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
    "$scheme_dir/cli/process-host.sld" \
    "$src_dir/cli/process-host.sld"
  copy_gambit_source \
    "$scheme_dir/cli/native-cli.sld" \
    "$src_dir/cli/native-cli.sld"
  copy_gambit_source \
    "$scheme_dir/cli/repl-shell.sld" \
    "$src_dir/cli/repl-shell.sld"

  "$gsi" -:r7rs,search="$scheme_dir" \
    -e '(import (scheme base) (scheme write)) (write (+ 1 2)) (newline)' \
    >"$logs_dir/gsi-r7rs-probe.log" 2>&1 \
    || die "Gambit gsi does not accept R7RS mode with the Consent Scheme library search path; see $logs_dir/gsi-r7rs-probe.log"

  write_gambit_main "$main_file" "$src_dir"
  write_manifest "$host_root" gambit "$version"
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
    cli/repl-shell \
    "$scheme_dir/cli/repl-shell.sld" \
    "$src_dir/cli/repl-shell.c"

  "$gsc" -:r7rs,search="$scheme_dir" \
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
