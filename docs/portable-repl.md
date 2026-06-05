# Portable Terminal REPL Shell

The portable terminal REPL shell is the first interactive non-Emacs entry point
for Consent Scheme. It runs the portable R7RS runtime, reads forms incrementally
from a terminal or pipe, evaluates them one at a time in a durable authorized
session, and emits the Scheme-readable record vocabulary defined by the
[Cross-Host REPL Interaction Contract](repl-interaction-contract.md). It is the
portable-host implementation of that contract (issue #360); the Emacs incremental
entry (#391) is its parity twin, and the shared conformance corpus (#392) asserts
both hosts against the same records.

This document covers setup, invocation, the emitted records, limitations, and
verification. For the host-neutral behavioral obligations themselves — the
interaction model, record fields, stream separation, and close-status vocabulary
— see the contract document; this shell satisfies those obligations rather than
re-deriving them.

## Setup

The shell is interpreted Consent Scheme run under any supported R7RS host. You
need one of the following on your `PATH`:

- [Chibi-Scheme](https://github.com/ashinn/chibi-scheme) (`chibi-scheme`)
- [Guile](https://www.gnu.org/software/guile/) 3 (`guile`)
- [Gauche](https://practical-scheme.net/gauche/) (`gosh`)

No build step is required: the launcher puts the repository `scheme/` directory
on the host's library search path and runs the interpreted entry point.

## Invocation

Start the shell with the launcher or the make target:

```sh
tools/consent-repl                 # auto-detect the first available host
tools/consent-repl --session demo  # name the session id
make repl                          # same launcher via make
make repl ARGS='--session demo'    # pass flags through ARGS
```

Select the host explicitly with `CONSENT_REPL_HOST=chibi|guile|gauche`.

The shell reads forms from standard input. Interactively, type a form and press
return; in a pipeline, feed forms on standard input:

```sh
printf '(+ 1 2)\n(exit)\n' | tools/consent-repl
```

### Running on a host-compiled binary

The setup above is for the *interpreted* shell, which needs a Scheme host on
`PATH`. A host-compiled Consent Scheme executable
([development.md](development.md), "Host-Compiled Portable Executables") links
`(cli repl-shell)` into the binary and exposes it as a `--repl` command, so it
runs the REPL with **no runtime setup at all** — no Scheme host and no language
packages on `PATH`, and nothing else on disk, because the binary is
self-contained:

```sh
build/compile/racket/bin/consent --repl                # or the gambit binary
printf '(+ 1 2)\n(exit)\n' | build/compile/gambit/bin/consent --repl --session demo
```

`--repl` accepts the same `--session NAME` option and uses the same stream
separation (records on stderr, program output on stdout) and close-status exit
code as the interpreted launcher.

The setup such a binary needs is at *build* time, not run time: the compile
toolchain documented in [development.md](development.md) — Gambit (`gsi`/`gsc`),
or Racket plus its R7RS language package (`raco pkg install --auto r7rs`).

### Streams

The shell keeps the contract's interaction streams separate from program output
so it can be scripted without corrupting program output:

- **stdout** carries only *program output* — whatever evaluated forms write to
  the current output port (for example via `(display ...)` from `(scheme write)`,
  or `write-string` from `(scheme base)`).
- **stderr** carries the *interaction records* — prompts, submissions, results,
  conditions, and the close record.

So a pipeline that reads the shell's stdout sees only program output:

```sh
printf '(import (scheme base) (scheme write)) (display "hi") (newline) (exit)\n' \
  | tools/consent-repl 2>/dev/null
# => hi
```

The process exit code is `0` for a clean close (`closed-ok`) and `1` for an error
close (`closed-error`), mapping the contract close status to a shell exit code.

## Emitted records

Each turn of the loop emits the contract records on stderr, one Scheme datum per
line. For `(+ 1 2)` followed by end of input:

```scheme
(repl-prompt (session demo) (ordinal 1) (state ready) (pending #f))
(repl-submission (id sub-1) (session demo) (ordinal 1) (source "(+ 1 2)") (complete #t) (eof #f))
(repl-result (id res-1) (submission sub-1) (session demo) (evaluation-result (evaluation-result (status ok) (value 3) ...)) (display "3"))
(repl-prompt (session demo) (ordinal 2) (state ready) (pending #f))
(repl-exit (session demo) (reason eof) (status closed-ok) (count 1) (detail #f))
```

- Results wrap the existing `(consent result)` `evaluation-result` datum
  unchanged and add an optional human-readable `display` string.
- A recoverable reader or evaluator condition is reported as a `repl-condition`
  and the session keeps running; an unbalanced form at the end of input closes
  with `(status closed-error)`.
- `(exit)` / `(exit OBJECT)` end the session with `(reason explicit)`; a nonzero
  exit object closes with `(status closed-error)`.
- A durable session evaluation environment preserves definitions, imports, and
  macros across submitted forms, and `(interaction-environment)` from
  `(scheme repl)` resolves to that environment only inside the authorized
  session, failing closed otherwise.
- Host effects that lack an explicit capability grant fail closed with their
  normal capability condition surfaced as a `repl-condition`; the shell grants no
  authority of its own.

## Limitations

This is the minimal v1 shell. The following are intentionally out of scope and
are owned by later issues:

- **No line editing, history, or completion.** Input is read line by line; use a
  terminal wrapper such as `rlwrap` for editing convenience.
- **Program input.** The loop consumes standard input as interaction input, so a
  form that reads from the current input port has no separate program-input
  stream in this v1 shell; such a read fails closed.
- **Synchronous, flat error model.** Each submission runs to completion before
  the next is read, and a condition is rendered and the loop continues. The
  nested break loop, asynchronous/streamed evaluation, and cancellation are
  forward-compatibility points described in the contract, not implemented here.
- **No meta-command syntax.** Submissions are ordinary Scheme forms; introspection
  and control are ordinary procedures, per the contract's deliberate non-goal.
- **Approval UX.** Interactive approval prompts use the prompt posture from the
  [Native CLI and daemon adapter contract](native-cli-daemon-adapter.md); a
  noninteractive session fails closed on a `confirm` action without a covering
  grant.

## Verification

The shell is covered by the portable Scheme test
`tests/scheme/consent-repl-test.scm`, which is in the shared host-suite file list
and therefore runs on every portable host shard (Gambit, Racket, Guile, Gauche,
and the compiled host). It asserts simple evaluation, persistent definitions and
macros, session-gated `interaction-environment`, recoverable reader and evaluator
conditions, EOF and explicit-exit close status, policy-gated host-effect denial,
and program-output/record stream separation.

Run the default verification, which includes the Racket host shard:

```sh
make test
```

Run every portable host shard, including the compiled host:

```sh
make test-full
```

A single host can be exercised directly, for example with Chibi-Scheme:

```sh
chibi-scheme -A scheme tests/scheme/consent-repl-test.scm
```
