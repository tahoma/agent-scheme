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
re-deriving them. For a single guide that covers starting the REPL on *both*
hosts side by side, with a cross-host parity matrix, see
[Using the Consent Scheme REPL](repl.md).

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

`--repl` accepts the same `--session NAME`, `--chrome NAME`, `--color=WHEN`, and
`--replay FILE` options and uses the same stream separation (chrome on stderr,
program output on stdout) and close-status exit code as the interpreted launcher.

The setup such a binary needs is at *build* time, not run time: the compile
toolchain documented in [development.md](development.md) — Gambit (`gsi`/`gsc`),
or Racket plus its R7RS language package (`raco pkg install --auto r7rs`).

### Chrome (human presentation)

The canonical surface of the REPL is the Scheme-readable record stream
([the interaction contract](repl-interaction-contract.md))  — ideal for tooling,
debugging, and the cross-host parity corpus, but heavy as the everyday human
default. A **chrome** is a presentation layer over those records: a pure function
that maps each record to readable terminal text. Chrome is host-specific
presentation *under* the contract; the records stay the canonical, byte-level
parity surface, and chrome rides above them.

Select a chrome with `--chrome NAME`:

| Chrome    | Intent                                                                    |
| --------- | ------------------------------------------------------------------------- |
| `comment` | **Default.** The prompt is block-comment furniture (`#\| 1 \|# `); a submitted form is echoed as bare code; and each result, condition, exit, and line of program output is its own `;;` line comment whose marker right-aligns under the echoed form — `;;   => ` for a value, `;;   !! ` for a condition, `;;   :: ` for program output, `;;   __ exit <status>` to close — each followed by a `;;` separator. `comment` **owns** program output: it renders each printed line as a `;;   :: ` comment on the control channel (stderr) and leaves stdout empty, so the **whole** captured transcript is valid Consent Scheme that *replays* to the same forms (replay is now unconditional, not "apart from program output"). To get raw program output on stdout, use `silent` (or any non-`comment` chrome). On an interactive terminal the chrome suppresses its own echo (the terminal already echoed the typed form) so a captured transcript holds exactly one copy of each form; see [Replayable transcripts and input echo](#replayable-transcripts-and-input-echo). The prompt shows the ordinal alone for the lone default session and grows a session label when named; a continuation prompt is width-matched alignment dots (`#\| . \|# `), no nesting count. |
| `datum`   | The raw record stream, one datum per line — the canonical machine-readable surface. Never colored. Always reachable, regardless of the default. |
| `classic` | A familiar terminal-REPL look: a `>` prompt, a `.` continuation gutter (both two columns, no nesting count), the whole form echoed as bare source (TTY-gated like `comment`), and single-column `= `/`! `/`_ ` markers on the value, condition, and exit lines, with a blank line between turns. Unlike `comment` it makes no replay claim, so program output stays **raw and interleaved**, exactly as a real REPL shows it. |
| `quiet`   | No prompts; results and conditions only.                                  |
| `silent`  | Suppresses all interaction records; only program output reaches stdout.   |

```sh
printf '(+ 1 2)\n(exit)\n' | tools/consent-repl --chrome classic
printf '(+ 1 2)\n(exit)\n' | tools/consent-repl --chrome datum   # raw records
make repl ARGS='--chrome quiet'
```

The same printing session under `comment` (default) and `classic`. Note how
`comment` renders the `(display …)` output as a `;;   :: ` line comment — so the
transcript stays replayable — while `classic` leaves it raw:

```
#| 1 |# (define (greet who) (display "hi ")(display who)(newline))
;;   => (unspecified)
;;
#| 2 |# (greet "world")
;;   :: hi world
;;   => (unspecified)
;;
#| 3 |# (+ 2 3)
;;   => 5
;;
#| 4 |# (exit)
;;   __ exit closed-ok
```

```
> (define (greet who) (display "hi ")(display who)(newline))
= (unspecified)

> (greet "world")
hi world
= (unspecified)

> (+ 2 3)
= 5

> (exit)
_ exit closed-ok
```

Styling is expressed as named **semantic roles** (`furniture`, `prompt-session`,
`prompt-ordinal`, `result-marker`, `result-value`, `error-marker`, `error-text`,
`exit-marker`, `exit-status`, `output-marker`, `output-text`), never raw ANSI, so
another host realizes the same roles on its own substrate. The terminal renderer
maps roles to ANSI SGR; the Emacs host maps
the same named set and record-to-role mapping to faces in its session buffer
(`consent-repl-chrome.el`), so the standalone shell and the in-editor REPL share
a presentation. The built-in chromes are ordinary registered procedures over
records in `(cli repl-chrome)`, so a future custom chrome (#426) is the same
kind of value.

#### Color

`--color=WHEN` controls ANSI color, where `WHEN` is one of:

- `auto` (default) — color only when the control channel is a terminal and the
  `NO_COLOR` environment variable is unset, so output is plain when piped or
  redirected;
- `always` — color unconditionally (an explicit override that ignores `NO_COLOR`);
- `never` — never color.

`NO_COLOR` (when set to a non-empty value) disables color under `auto`. The
spaced form `--color always` is also accepted.

#### Replayable transcripts and input echo

The `comment` chrome's replay guarantee — a captured transcript is valid Consent
Scheme that re-evaluates to the same session — holds for the **whole** stream:
prompts, results, conditions, the exit, and program output are all `;;` line
comments or `;;` blanks, and the only bare source is the submitted forms
themselves. (Program output is commented as `;;   :: ` lines precisely so a
`(display …)` transcript replays instead of re-evaluating the printed text;
re-evaluation regenerates the same output, itself inert on replay, so replay is
idempotent.) The guarantee depends on each submitted form appearing **exactly
once** in the transcript. Who supplies that one copy depends on whether the
interaction input is itself echoed:

- **Piped or redirected stdin** is not echoed by any terminal, so the chrome
  echoes each complete submission as bare code. That chrome echo is the single
  replayable copy.
- **An interactive terminal** reads stdin in cooked mode and the terminal driver
  echoes every typed form, so the form is already in a `script(1)`-style capture
  before the chrome runs. Here the chrome **suppresses** its own echo; the
  terminal's echo, which lands in the same slot right after the prompt, is the
  single replayable copy.

Either way a captured transcript holds one copy of each form and replays once.
Without the suppression an interactive capture would carry every form twice —
the terminal echo plus the chrome echo — and replaying it would evaluate every
form twice, diverging from the original session for any definition, mutation, or
side effect. The shell decides which mode it is in with the same per-host
terminal-port predicate it uses for `--color=auto`, applied to **stdin** rather
than the control channel. `classic` echoes submissions through the same gate (so
it does not double-echo on a live TTY either); `quiet`, `silent`, and `datum` do
not echo submissions, so they are unaffected, and `--chrome datum` always
reproduces the raw record stream verbatim.

#### Capturing and replaying a session

The `datum` chrome stream is the canonical capture format, and `--replay FILE`
reloads and replays a captured transcript to a fresh session — so a transcript
doubles as a reproducible bug report or a fixture capture. Capture the record
stream by redirecting the control channel, then replay it:

```sh
printf '(+ 1 2)\n(define base 7)\n(* base 3)\n(exit)\n' \
  | tools/consent-repl --chrome datum 2>session.scm        # capture
tools/consent-repl --replay session.scm --chrome datum     # replay
```

Replay reconstructs the interaction input from the captured **complete
submissions** and re-evaluates them in a fresh session, then appends a
`repl-replay-report` datum and **exits non-zero if the replay diverged** from the
captured outcomes. A pure transcript reproduces an equal stream; a result that
depended on a capability grant the replay session lacks fails closed — its
recorded `repl-result` replays as a `repl-condition`, which the report flags
rather than silently reproducing the recorded value. The full capture format,
the reproduces-versus-cannot rules, and the report shape are specified in the
interaction contract's
[Capture and Replay](repl-interaction-contract.md#capture-and-replay) section;
`(cli repl-shell)` exposes the same driver as the library procedures
`cli-repl-replay-records` and `cli-repl-replay-report`.

### Streams

The shell keeps the contract's interaction streams separate from program output
so it can be scripted without corrupting program output:

- **stdout** carries only *program output* — whatever evaluated forms write to
  the current output port (for example via `(display ...)` from `(scheme write)`,
  or `write-string` from `(scheme base)`).
- **stderr** carries the *interaction channel* — prompts, results, conditions,
  and the close record, rendered through the active chrome (`--chrome datum` puts
  the raw record stream here).

So a pipeline that reads the shell's stdout sees only program output:

```sh
printf '(import (scheme base) (scheme write)) (display "hi") (newline) (exit)\n' \
  | tools/consent-repl 2>/dev/null
# => hi
```

The process exit code is `0` for a clean close (`closed-ok`) and `1` for an error
close (`closed-error`), mapping the contract close status to a shell exit code.

## Emitted records

Under `--chrome datum`, each turn of the loop emits the contract records on
stderr, one Scheme datum per line — the canonical surface every chrome renders
from. For `(+ 1 2)` followed by end of input:

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
  terminal wrapper such as `rlwrap` for editing convenience. Because the line is
  read in the terminal's cooked mode, the terminal driver echoes each typed form;
  the `comment` chrome accounts for that echo (see
  [Replayable transcripts and input echo](#replayable-transcripts-and-input-echo)).
- **Program input is multiplexed onto one stdin cursor.** A submitted form may
  read its standard input: the form reader and program reads share a single stdin
  cursor in time order, so `(display (read-line))` ⏎ then `hello` ⏎ reads
  `"hello"` and a following form is still read as its own submission, not stolen.
  The submission's terminating newline is the boundary (not program data), and a
  REPL session authorizes its own stdin by invocation. See the program stream
  model in the
  [REPL interaction contract](repl-interaction-contract.md#program-stream-model).
  (Binary stdio and live-TTY line editing remain out of scope; see that section.)
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
and program-output/record stream separation. It also covers the chrome layer:
the chrome registry, the `datum` chrome reproducing the raw record stream, the
`comment` chrome replaying unedited, its interactive-TTY echo suppression (the
no-double-echo path), the `classic`/`quiet`/`silent` renderings, the
TTY/NO_COLOR color decision, and option parsing.

Cross-host parity with the Emacs entry is enforced separately by the shared
conformance corpus [`fixtures/repl/parity-cases.scm`](../fixtures/repl/parity-cases.scm).
The portable runner `tests/scheme/consent-repl-parity-test.scm` and the Emacs
runner `tests/consent-repl-parity-test.el` drive the same cases against both
hosts and assert the same record sequence, so a host that drifts from the
[REPL interaction contract](repl-interaction-contract.md) fails its runner. The
portable runner is in the shared host-suite file list, so it runs on every
portable host shard, Chibi included.

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
