#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

compile_host=${AGENT_SCHEME_COMPILE_HOST:-racket}
build_dir=${AGENT_SCHEME_COMPILE_BUILD_DIR:-"$repo_root/build/compile"}
case "$build_dir" in
  /*) ;;
  *) build_dir="$repo_root/$build_dir" ;;
esac
scheme_dir="$repo_root/scheme"
version_file="$scheme_dir/agent-scheme/version.sld"

die() {
  printf '%s\n' "agent-scheme compile: $*" >&2
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
    match($0, /\(agent-scheme-version [0-9]+ [0-9]+ [0-9]+\)/) {
      text = substr($0, RSTART + 1, RLENGTH - 2)
      split(text, parts, " ")
      print parts[2] "." parts[3] "." parts[4]
      exit
    }
  ' "$version_file"
}

version_datum() {
  components=$1
  printf '(agent-scheme-version %s)\n' "$(printf '%s\n' "$components" | tr '.' ' ')"
}

write_manifest() {
  host_root=$1
  host=$2
  version=$3
  manifest="$host_root/manifest.scm"

  cat > "$manifest" <<EOF
(agent-scheme-compile
  (compile-host $host)
  (version $(version_datum "$version"))
  (layout
    (root "$host_root")
    (executable "bin/agent-scheme")
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
        (prefix (scheme case-lambda) agent-scheme-main:r7rs-case-lambda:)
        (prefix (scheme char) agent-scheme-main:r7rs-char:)
        (prefix (scheme complex) agent-scheme-main:r7rs-complex:)
        (prefix (scheme cxr) agent-scheme-main:r7rs-cxr:)
        (only (scheme eval) environment)
        (prefix (scheme file) agent-scheme-main:r7rs-file:)
        (prefix (scheme inexact) agent-scheme-main:r7rs-inexact:)
        (prefix (scheme lazy) agent-scheme-main:r7rs-lazy:)
        (scheme load)
        (scheme process-context)
        (prefix (scheme r5rs) agent-scheme-main:r7rs-r5rs:)
        (prefix (scheme read) agent-scheme-main:r7rs-read:)
        (prefix (scheme repl) agent-scheme-main:r7rs-repl:)
        (prefix (scheme time) agent-scheme-main:r7rs-time:)
        (scheme write)
        (prefix (agent task) agent-scheme-main:agent-task:)
        (prefix (agent transcript) agent-scheme-main:agent-transcript:)
        (prefix (agent-scheme approval) agent-scheme-main:approval:)
        (prefix (agent-scheme base) agent-scheme-main:base:)
        (prefix (agent-scheme context) agent-scheme-main:context:)
        (prefix (agent-scheme helper) agent-scheme-main:helper:)
        (prefix (agent-scheme job) agent-scheme-main:job:)
        (prefix (agent-scheme library) agent-scheme-main:library:)
        (prefix (agent-scheme macro) agent-scheme-main:macro:)
        (prefix (agent-scheme memory) agent-scheme-main:memory:)
        (prefix (agent-scheme plan) agent-scheme-main:plan:)
        (prefix (agent-scheme reader) agent-scheme-main:reader:)
        (prefix (agent-scheme redaction) agent-scheme-main:redaction:)
        (prefix (agent-scheme result) agent-scheme-main:result:)
        (prefix (agent-scheme runtime) agent-scheme-main:runtime:)
        (prefix (agent-scheme session) agent-scheme-main:session:)
        (only (agent-scheme eval)
              agent-scheme-eval-source
              agent-scheme-value->external)
        (only (agent-scheme version)
              agent-scheme-version-datum))

(define (agent-scheme-main-version-string)
  (let ((primary (list-ref agent-scheme-version-datum 1))
        (secondary (list-ref agent-scheme-version-datum 2))
        (tertiary (list-ref agent-scheme-version-datum 3)))
    (string-append
     "Agent Scheme "
     (number->string primary)
     "."
     (number->string secondary)
     "."
     (number->string tertiary))))

(define (agent-scheme-main-help)
  (display "Usage: agent-scheme [--help] [--version] [--eval SOURCE] [--script FILE]\n")
  (display "\n")
  (display "Commands:\n")
  (display "  --help          Show this help.\n")
  (display "  --version       Print the Agent Scheme runtime version.\n")
  (display "  --eval SOURCE   Evaluate a pure Agent Scheme expression.\n")
  (display "  --script FILE   Run an R7RS Scheme source file.\n"))

(define (agent-scheme-main-error message)
  (display "agent-scheme: " (current-error-port))
  (display message (current-error-port))
  (newline (current-error-port))
  (exit 2))

(define (agent-scheme-main-eval source)
  (guard (condition
          (else
           (display "agent-scheme: evaluation failed" (current-error-port))
           (display ": " (current-error-port))
           (write condition (current-error-port))
           (newline (current-error-port))
           (exit 1)))
    (display
     (agent-scheme-value->external
      (agent-scheme-eval-source source)))
    (newline)))

(define (agent-scheme-main-script path)
  (guard (condition
          (else
           (display "agent-scheme: script failed" (current-error-port))
           (display ": " (current-error-port))
           (write condition (current-error-port))
           (newline (current-error-port))
           (exit 1)))
    (load path (environment))))

(define (agent-scheme-main args)
  (cond
   ((null? args)
    (agent-scheme-main-help))
   ((string=? (car args) "--help")
    (agent-scheme-main-help))
   ((string=? (car args) "--version")
    (display (agent-scheme-main-version-string))
    (newline))
   ((string=? (car args) "--eval")
    (if (null? (cdr args))
        (agent-scheme-main-error "--eval requires SOURCE")
        (agent-scheme-main-eval (cadr args))))
   ((string=? (car args) "--script")
    (if (null? (cdr args))
        (agent-scheme-main-error "--script requires FILE")
        (agent-scheme-main-script (cadr args))))
   (else
    (agent-scheme-main-error
     (string-append "unknown option " (car args))))))

(let ((arguments (command-line)))
  (agent-scheme-main
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

  version_output=$("$runner" --version 2>"$log_file.version.err") \
    || die "compiled runner failed --version; see $log_file.version.err"
  eval_output=$("$runner" --eval "(+ 1 2)" 2>"$log_file.eval.err") \
    || die "compiled runner failed --eval; see $log_file.eval.err"

  if [ "$version_output" != "Agent Scheme $expected_version" ]; then
    die "compiled runner --version returned '$version_output', expected 'Agent Scheme $expected_version'"
  fi

  if [ "$eval_output" != "3" ]; then
    die "compiled runner --eval returned '$eval_output', expected '3'"
  fi

  cat > "$log_file" <<EOF
(agent-scheme-compile-smoke
  (version-output "$version_output")
  (eval-output "$eval_output"))
EOF
}

compile_racket() {
  racket=$(find_command AGENT_SCHEME_RACKET racket) \
    || die "Racket compile prerequisites are missing; set AGENT_SCHEME_RACKET to a runnable racket executable."
  raco=$(find_command AGENT_SCHEME_RACO raco) \
    || die "Racket compile prerequisites are missing; set AGENT_SCHEME_RACO to a runnable raco executable."

  host_root="$build_dir/racket"
  src_dir="$host_root/src"
  collections_dir="$host_root/collections"
  bin_dir="$host_root/bin"
  logs_dir="$host_root/logs"
  main_file="$src_dir/agent-scheme-main.rkt"
  runner="$bin_dir/agent-scheme"
  smoke_log="$logs_dir/smoke.log"
  version=$(version_components)

  [ -n "$version" ] || die "could not read Agent Scheme version from $version_file"

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
  die "Gambit compile selection is reserved for issue #273; use AGENT_SCHEME_COMPILE_HOST=racket for the supported path in this slice."
}

case "$compile_host" in
  racket)
    compile_racket
    ;;
  gambit)
    compile_gambit
    ;;
  *)
    die "AGENT_SCHEME_COMPILE_HOST must be one of: racket, gambit"
    ;;
esac
