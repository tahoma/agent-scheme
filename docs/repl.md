# Using the Consent Scheme REPL

Consent Scheme has a functional, interactive read-eval-print loop on more than
one host. This document is the single place to learn how to *use* it: how to
start a session on each host, what the two hosts share, and how they differ. It
is task-oriented; the behavioral rules the hosts implement live elsewhere and are
linked rather than restated.

The REPL is defined once and realized twice:

- The host-neutral behavior — the interaction loop, the Scheme-readable record
  vocabulary, stream separation, close-status vocabulary, and policy-gated host
  effects — is the
  [Cross-Host REPL Interaction Contract](repl-interaction-contract.md) (#390).
- The **portable terminal REPL** (#360) implements the contract outside Emacs.
  Its setup, invocation, chrome/color options, emitted records, and verification
  are documented in detail in the
  [Portable Terminal REPL Shell](portable-repl.md).
- The **Emacs incremental REPL** (#391) is the parity twin, implemented on the
  Emacs host.
- A single shared [conformance corpus](../fixtures/repl/parity-cases.scm) (#392)
  drives the same cases against both hosts, so parity is enforced rather than
  asserted.

If you are reading the runtime's behavior into tooling, read the contract. If you
just want to start typing forms, start here.

## The two hosts at a glance

| | Portable terminal REPL | Emacs incremental REPL |
| --- | --- | --- |
| Module | `(cli repl-shell)` | `consent-repl-stream.el` |
| Start (scripted) | `printf '…' \| tools/consent-repl` | `emacs -Q --batch -l consent-repl-stream -f consent-repl-stream-main` |
| Start (interactive) | `tools/consent-repl` / `make repl` | `M-x consent-repl-stream` |
| Input source | terminal / stdin byte stream | batch stdin, or a submitted buffer/region |
| Canonical surface | Scheme-readable record stream | Scheme-readable record stream |
| Default human view | `comment` chrome (ANSI) | `comment` chrome (Emacs faces) |
| Close status maps to | process exit code (0 / 1) | `emacs --batch` exit code, or buffer/session disposition |
| Detailed docs | [portable-repl.md](portable-repl.md) | this document, [getting-started.md](getting-started.md) |

Both hosts read **one complete form at a time** over the shared recovery-aware
reader, evaluate it in a **durable, authorized session**, and emit the same
`repl-prompt` / `repl-submission` / `repl-result` / `repl-condition` /
`repl-exit` records. What differs is how each draws input, multiplexes output
streams, and encodes the close status — the host-specific obligations enumerated
in the contract.

## Portable terminal REPL

The portable shell is the first interactive non-Emacs entry point. It runs under
any supported R7RS host (Chibi, Guile 3, or Gauche) with no build step, or as a
`--repl` command on a host-compiled binary with no runtime setup at all.

```sh
tools/consent-repl                 # auto-detect the first available host
make repl                          # same launcher via make
printf '(+ 1 2)\n(exit)\n' | tools/consent-repl
```

Setup, host selection (`CONSENT_REPL_HOST`), the `--session`/`--chrome`/`--color`
options, the chrome model (`comment`/`datum`/`classic`/`quiet`/`silent`), the
emitted records, and verification are documented in full in the
[Portable Terminal REPL Shell](portable-repl.md). This document does not repeat
them; the parity matrix below references that behavior.

## Emacs incremental REPL

Emacs has two related interactive surfaces, and it helps to keep them distinct.

### Session UX (`consent-repl.el`)

`consent-start-repl` and `consent-repl-eval` provide the native session UX:
project/named session buffers, a transcript buffer, event and approval buffers,
and a mode line. `consent-repl-eval` evaluates a whole submitted source string at
once. This is the editor-integrated surface and is documented in
[getting-started.md](getting-started.md) under "Emacs REPL Startup."

### Incremental entry (`consent-repl-stream.el`)

`consent-repl-stream` is the contract parity twin of the portable shell. Unlike
`consent-repl-eval`, it reads forms **incrementally, one at a time**, recovers
from per-form reader and evaluator conditions without ending the session, and
closes cleanly on EOF or explicit exit — the same per-form read-eval-print
semantics the portable shell has. It reuses the existing `(scheme repl)` session
substrate and the durable interaction context (`consent-make-interaction-context`
over `consent-interaction-eval-form`), so definitions, imports, and macros
persist across submitted forms in the same session.

It has two entry points:

- **Scripted / batch.** Run a piped session through batch stdin, with contract
  records on the error stream and program output on stdout:

  ```sh
  printf '(+ 1 2)\n(exit)\n' \
    | emacs -Q --batch -l consent-repl-stream -f consent-repl-stream-main
  ```

  `consent-repl-stream-main` exits Emacs with the close-status code (`0` for
  `closed-ok`, `1` for `closed-error`), mirroring the portable shell's process
  exit code.

- **Interactive.** `M-x consent-repl-stream` reads a source string (or the active
  region), drives it through the same incremental loop, and renders the records
  into the `*Consent REPL Stream*` buffer through the shared chrome model
  (`consent-repl-chrome.el`) — the same named chromes and record-to-role mapping
  as the portable shell, realized as Emacs faces. The default chrome is
  `comment`, consistent with the portable terminal; `datum` recovers the raw
  record stream in the buffer.

The pure driver `consent-repl-stream-drive` maps an interaction-input chunk
source to the list of contract records, which is what the conformance corpus and
the Emacs smoke tests assert against without needing a terminal.

## Parity matrix

This matrix maps each host-neutral obligation of the
[interaction contract](repl-interaction-contract.md) (#390, "Host-neutral
obligations") to how each host realizes it, and names the
[conformance case](../fixtures/repl/parity-cases.scm) (#392) that pins it for
both hosts. Host-specific obligations (input editing, physical stream
multiplexing, close-status encoding, prompt/approval presentation, chrome
substrate, scheduling) are realized per host by design and are not parity-pinned;
see the contract's "Host-specific obligations" section.

| Contract obligation | Portable terminal REPL | Emacs incremental REPL | Conformance case (#392) |
| --- | --- | --- | --- |
| One-complete-form-at-a-time reading | `(cli repl-shell)` over the shared reader | `consent-repl-stream` over the shared reader | `repl-eval-simple` |
| Multiple forms in one input chunk, evaluated in order | one submission per form | one submission per form | `repl-multiple-forms-one-chunk` |
| Incomplete form continued as one submission | continuation prompt, buffered text | continuation prompt, buffered text | `repl-incomplete-continuation` |
| Durable session: definitions/imports/macros persist | session interaction environment | `consent-make-interaction-context` session | `repl-session-persistence` |
| Recoverable evaluator condition keeps session open | rendered, loop continues | rendered, loop continues | `repl-recoverable-eval-condition` |
| Recoverable reader condition resynchronizes | resync to next form boundary | resync to next form boundary | `repl-recoverable-read-condition` |
| Value rendering via `evaluation-result` | `(consent result)` datum | `(consent result)` datum | `repl-eval-simple` |
| Multiple-value rendering | `status values` datum | `status values` datum | `repl-multiple-values` |
| Zero-value rendering | empty `values` list | empty `values` list | `repl-zero-values` |
| EOF closes cleanly | `(reason eof) (status closed-ok)` | `(reason eof) (status closed-ok)` | `repl-eval-simple` |
| EOF mid-form closes with error status | `(reason eof) (status closed-error)` | `(reason eof) (status closed-error)` | `repl-eof-mid-form` |
| Explicit exit closes after current submission | `(reason explicit)`, exit-code map | `(reason explicit)`, exit-code map | `repl-explicit-exit` |
| Ungranted host effect fails closed, session survives | capability condition as `repl-condition` | capability condition as `repl-condition` | `repl-policy-denied-default` |
| Interaction environment fails closed without `repl` grant | session-policy denial | session-policy denial | `repl-policy-denied-interaction-environment` |
| Stream separation (program output vs interaction) | program output on stdout, records on stderr | program output on stdout, records on error stream | exercised across cases; see below |

Every conforming session also emits exactly one `repl-exit`, and the runners
correlate a `repl-result`/`repl-condition` to its submission by the
`(submission sub-N)` field rather than by record position, per the contract's
forward-compatibility guidance.

## Stream separation

Both hosts keep the contract's interaction streams separate from program output
so a session can be scripted without corrupting program output:

- **Program output** (whatever evaluated forms write to the current output port,
  e.g. `display`) goes to **stdout**.
- **Interaction records** (prompts, results, conditions, the close record),
  rendered through the active chrome, go to the **error/control channel**
  (stderr on the portable host; the error stream from
  `consent-repl-stream-main`).

So a pipeline reading the session's stdout sees only program output:

```sh
printf '(import (scheme base) (scheme write)) (display "hi") (newline) (exit)\n' \
  | tools/consent-repl 2>/dev/null
# => hi
```

The `datum` chrome puts the raw record stream on the control channel and is
always reachable on every host, so no chrome can suppress the canonical parity
surface. See the contract's "Stream Separation" section for the full channel
model and how interaction streams lower to the native CLI/daemon adapter event
kinds.

## Policy, approval, and host effects

The REPL is a driver over the capability/policy boundary; it grants no authority
of its own. On both hosts:

- Obtaining the session interaction environment requires the `repl` capability
  (`(policy session)`), so `(interaction-environment)` from `(scheme repl)`
  resolves only inside an authorized active session and fails closed otherwise
  (`repl-policy-denied-interaction-environment`).
- Effects performed by evaluated forms — file, process, model, editor,
  persistence, clock — flow through the same capability requests, decisions,
  grants, and audit records described in
  [Capability Environment and Effect Lowering](capability-environment.md). An
  unauthorized effect fails closed with its normal capability condition,
  surfaced as a `repl-condition`, and the session keeps running
  (`repl-policy-denied-default`).
- Approval prompts use the prompt posture from the
  [Native CLI and Daemon Adapter Contract](native-cli-daemon-adapter.md): they
  are rendered on the approval interaction stream, never by consuming program
  input. In a noninteractive (piped/batch) session, a `confirm` action with no
  covering grant fails closed with `noninteractive-confirmation-unavailable`.
- No record exposes a raw host object. Live environments, buffers, ports,
  processes, and continuations appear only through the stable renderings of
  `(consent result)` and the session/handle vocabulary.

## Limitations

These apply to both hosts and are intentionally out of scope for the v1 REPL;
they are owned by later issues, not omissions to fix here:

- **No line editing, history, or completion.** Input is read line by line; use a
  terminal wrapper such as `rlwrap` on the portable host for editing
  convenience.
- **No meta-command syntax.** Submissions are ordinary Scheme forms;
  introspection and control are ordinary procedures, a deliberate contract
  non-goal (no `,backtrace` / `:doc` / `%time` sigils).
- **No last-value bindings.** Neither host binds `*1`/`it`; this is a settled
  parity decision, not a per-host accident — a future revision must add them on
  both hosts together.
- **Synchronous, flat error model.** Each submission runs to completion before
  the next is read; a recoverable condition is rendered and the loop continues.
  Asynchronous/streamed evaluation, cancellation, and the nested break loop are
  forward-compatibility points in the contract, not implemented here.
- **Program input.** The loop consumes the interaction input stream, so a form
  that reads from the program input port has no separate program-input stream in
  v1; such a read fails closed.

## Conformance and verification

The portable shell is covered by `tests/scheme/consent-repl-test.scm` (in the
shared host-suite file list, so it runs on every portable host shard). The Emacs
incremental entry is covered by its own smoke tests over
`consent-repl-stream-drive`.

Cross-host parity is enforced by the shared corpus
[`fixtures/repl/parity-cases.scm`](../fixtures/repl/parity-cases.scm): the
portable runner `tests/scheme/consent-repl-parity-test.scm` and the Emacs runner
`tests/consent-repl-parity-test.el` drive the *same* cases against both hosts and
assert the same record sequence, so a host that drifts from the contract fails
its runner. This feeds the parity CI gate (#374). See
[development.md](development.md) for how the corpus is wired into `make test`.

```sh
make test        # default verification, includes the Emacs and Racket shards
make test-full   # every portable host shard, including the compiled host
```
