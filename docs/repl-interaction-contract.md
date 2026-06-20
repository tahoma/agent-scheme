# Cross-Host REPL Interaction Contract

Consent Scheme runs on more than one host. Emacs already exposes an interactive
REPL/session UX (`consent-start-repl`, `consent-repl-eval`, the native session
buffers), while the portable R7RS runtime is still batch-only (`--eval`,
`--script`). Before a portable terminal REPL (#360) and an Emacs incremental
stdin REPL entry (#391) are built, both hosts need one shared definition of what
a REPL *session* must do, so the two surfaces reach genuine behavioral parity
instead of drifting apart.

This document is that definition. It specifies, as Scheme-readable data plus
prose, the cross-host REPL interaction behavior both hosts must satisfy, defines
the shared record vocabulary the conformance fixtures (#392) assert against, and
records which obligations are host-neutral versus host-specific.

It builds on existing substrate rather than introducing new runtime mechanism:

- the policy-gated `(scheme repl)` `interaction-environment` substrate
  (#313/#314), which already fails closed without a `repl` capability grant;
- the durable session model in
  [Session Lifecycle and Snapshots](session-lifecycle.md);
- the result/condition rendering conventions owned by `(consent result)` and the
  [Debugger Workflow](debugger.md);
- the capability and policy boundary in
  [Capability Environment and Effect Lowering](capability-environment.md);
- the host boundary records and stream/event vocabulary in the
  [Native CLI and Daemon Adapter Contract](native-cli-daemon-adapter.md).

This is a *contract*, not an implementation. The portable terminal REPL (#360),
the Emacs incremental entry (#391), line editing, history, completion, daemon
control sockets, and multi-client routing are all out of scope here and are
owned by their own issues. For task-oriented guidance on *using* the REPL on
each host, with a parity matrix linking these obligations to their conformance
cases, see [Using the Consent Scheme REPL](repl.md).

## Interaction Model

A REPL session is a host-neutral loop over a durable session interaction
environment. Each turn of the loop reads exactly one complete Scheme form,
evaluates it in the session, and renders the outcome, until input reaches end of
file or the session is explicitly closed.

```text
open  -> (read one form) -> eval -> render result  -> read next form -> ...
                |                         |
                | reader needs more input |
                +-------------------------+   (continuation prompt, same form)
                |                         |
                | reader/eval condition   |
                +-------------------------+   (render condition, loop continues)
                |
                | EOF or explicit exit
                v
       close (with documented close status)
```

The loop is the contract. The five things it produces — a prompt, a submitted
form, a result, a condition, and a close record — are the shared record
vocabulary defined below. A host conforms when, driven by the same input, it
emits the same sequence of contract records with equivalent fields, regardless
of how it draws characters, paints a buffer, or schedules work.

### Incremental, one-form-at-a-time reading

- A turn reads **one** complete datum from the interaction input, using the
  shared reader. Reading is incremental: the loop does not require the whole
  input to be available, and it does not read past the end of the current form.
- When the available input is a syntactically incomplete prefix of a form (an
  unbalanced list, string, or block comment, or a pending datum prefix), the
  reader reports an *incomplete* condition. The loop must treat this as a
  request for more input on the same logical submission — it re-prompts with a
  continuation prompt and appends, rather than discarding the partial input or
  reporting a hard reader error.
- When a single line or buffer holds several complete forms, the loop reads and
  evaluates them in order, one submission per form, before drawing the next
  primary prompt.
- Leading intertoken space, comments, and datum comments (`#;`) are consumed as
  part of reading the next form and never become their own submission.
- Reading is the only place the loop consumes the interaction input. Evaluation
  must not consume interaction input as a side effect of reading the next form.

### Evaluation in a durable session environment

- Each form is evaluated in the session's `(scheme repl)`
  `interaction-environment`. That environment is durable for the lifetime of the
  session: definitions, `import`s, and macro/syntax bindings introduced by one
  submission are visible to every later submission in the same session.
- The interaction environment is the same authorized session environment
  described in [Session Lifecycle and Snapshots](session-lifecycle.md); the REPL
  loop is a driver over a session, not a separate evaluation scope. A `named` or
  `project` session persists across loop turns; a `fresh` session does not
  outlive its single evaluation and is therefore not a REPL session.
- Obtaining the interaction environment is itself a policy-gated host effect (see
  [Policy-Gated Host Effects](#policy-gated-host-effects)). A loop that cannot
  obtain an authorized interaction environment must not silently fall back to a
  global or ambient environment; it closes with an error close status instead.
- Top-level `import` and `define-library` reach the session environment through
  the existing evaluator path. The contract does not add new top-level forms; it
  only requires that their effects persist across submissions.

### Rendering

- Every evaluation outcome is rendered through the existing `(consent result)`
  conventions, so the REPL never invents a second result vocabulary.
- A successful evaluation carries the existing `evaluation-result` datum
  (`status ok` with a rendered `value`, or `status values` with a rendered list
  for multiple values, including the empty list for zero values).
- An error or recoverable condition carries the existing debugger condition
  datum, exactly as `(consent result)` `condition-result-datum` produces it.
- The REPL wraps these existing datums in the records below; it does not reshape
  their internal fields. A host may additionally present a human-readable
  display string, but the Scheme-readable datum is the contract.

## Stream Separation

A REPL session has two distinct classes of byte/character stream, and the
contract requires they stay separate so a session can be scripted without
corrupting program output.

**Program streams** are the Scheme program's own ports:

- `program-input` — the Scheme current input port (the program's stdin).
- `program-output` — the Scheme current output port (the program's stdout).
- `program-error` — the Scheme current error port.

**Interaction streams** are the REPL's own control channels:

- `repl-prompt` — primary and continuation prompts.
- `repl-result` — rendered submission results.
- `repl-diagnostic` — reader/evaluator condition rendering and warnings.
- `repl-approval` — approval prompts and capability decisions
  (the prompt posture from the
  [Native CLI and Daemon Adapter Contract](native-cli-daemon-adapter.md)).

Obligations:

- Prompts, results, diagnostics, and approval prompts MUST NOT be written to
  `program-output`, and MUST NOT be drawn by consuming `program-input`. A
  pipeline that reads the session's `program-output` sees only what evaluated
  forms wrote there.
- Interaction input (the characters the reader consumes to build submissions) is
  logically distinct from `program-input`. A form that reads from
  `program-input` reads program data, not the next REPL submission, and must not
  steal characters the loop has not yet read as a form.
- A host MAY multiplex several streams onto one physical device (for example, a
  terminal that shows prompts and results inline on a TTY, or an Emacs buffer
  that renders all channels). When it does, each piece of output still carries
  its contract channel so a scripted or programmatic consumer can demultiplex
  them. The default terminal posture renders prompts, diagnostics, and approval
  prompts on the error/control channel, keeping `program-output` clean.
- This mirrors the adapter event kinds (`stdout`, `stderr`, `stdin-request`,
  `approval-request`, `approval-decision`, `progress`, `warning`) in the native
  CLI/daemon contract. A REPL interaction stream lowers to those event kinds when
  it crosses the host boundary; the channel names above are the REPL-level view
  of the same separation.
- A chrome MAY *own* `program-output` — relocating its presentation onto the
  control channel — when that serves the chrome's contract. The default
  `comment` chrome does this: because its whole reason for being is a wholly
  replayable transcript, it renders each line of `program-output` as an aligned
  `;;   :: ` line comment **on the control channel** (where the records are), so a
  captured control-channel transcript with `(display …)` replays to the same
  forms instead of re-evaluating the printed text — and under `comment`,
  `program-output` (stdout) is therefore empty. Every other chrome (`classic`,
  `quiet`, `silent`, `datum`) leaves `program-output` raw on stdout, so a
  consumer that wants byte-exact program output selects one of those (`silent`
  for program output alone). This is a per-chrome policy, applied by the output
  formatter; it changes which stream carries the output presentation, not the
  record vocabulary.

### Program Stream Model

The program's own standard streams — `program-input` (stdin),
`program-output` (stdout), and `program-error` (stderr) — are **consented by
invocation**. They are what the caller handed the process (a shell pipe, a
redirection, the terminal the user is driving), so the *host* attaching real
stdio is the authorization. The runtime itself stays fail-closed: it connects a
stream only when the host supplies both that stream's device callback and a
matching active `port` grant. A context with no devices/grants — the daemon/agent
adapter, the host-run test runner — keeps its streams disconnected/captured, so
the sandbox is intact wherever there is no user at the other end. **Ambient
authority is unaffected**: named file opens, processes, network, environment,
clock, providers, and editor mutation keep gating independently of stdio. No raw
host port crosses into Scheme — input is pulled through a reader thunk and output
flushed through a writer thunk.

- **Grants.** One active `port`-domain grant per connected stream, distinguished
  by its scope backing:

  ```scheme
  (capability-grant (id program-input)  (domain port) (operations read close)        (scope (backing stdin))  (expires never))
  (capability-grant (id program-output) (domain port) (operations write flush close) (scope (backing stdout)) (expires never))
  (capability-grant (id program-error)  (domain port) (operations write flush close) (scope (backing stderr)) (expires never))
  ```

- **Devices.** The host supplies the stream devices as evaluator options:
  `program-input-reader` (`:program-input-reader` on Emacs), a zero-argument
  thunk returning the next input chunk as a string or an end-of-stream
  indication; and `program-output-writer` / `program-error-writer`, procedures of
  one string that flush it to the real stream. A buffer is a stream with its time
  dimension collapsed — all input available at once, then immediate end — so a
  caller with genuinely finite, in-memory input (a fixture, a captured-transcript
  replay) builds its reader with `consent-program-input-from-string`. There is
  deliberately **no raw-string option**: the finite case is a constructor into the
  stream type, stated explicitly, not a stdin-shaped shortcut that would invite
  modelling a live stream as a buffer.

- **Binary devices.** A byte filter offers the binary peers instead (#528):
  `program-input-byte-reader` (`:program-input-byte-reader` on Emacs), a thunk
  returning the next chunk as a *bytevector* or an end-of-stream indication; and
  `program-output-byte-writer` / `program-error-byte-writer`, procedures of one
  byte chunk that flush it to the real stream. The finite in-memory constructor is
  `consent-program-input-from-bytevector`, the byte twin of
  `consent-program-input-from-string`. A stream is textual or binary, not both
  within a run: a binary device connects only when the same stream's textual
  device is absent, so the textual path takes precedence and the binary peer is
  purely additive (different streams may still mix — a binary stdin alongside a
  textual stdout).

- **Input refills on demand.** A connected `stdio`-backed input port grows its
  buffer by pulling from the reader only as reads need more: `read-char`/
  `peek-char` pull one character, `read-line` to the next newline, `read-string`
  to the count, and `read` until the recovery-aware reader sees a complete datum
  (then reads it through the ordinary validating reader). The binary port refills
  the same way by bytes: `read-u8`/`peek-u8` pull one byte and `read-bytevector`
  (and `read-bytevector!`) to its count. So a `(read-line)` or `(read-u8 …)`
  filter over a live, slow, or unbounded pipe processes input incrementally and
  never blocks draining all of stdin first; an unbounded stream does not hang a
  bounded read.

- **Output flushes through (write-through).** A connected `stdio`-backed output
  port flushes each write through the host writer immediately rather than
  buffering — each textual write on a textual port, each `write-u8`/
  `write-bytevector` on a binary port — so a single-form filter loop streams its
  output as it runs. `current-error-port` is connected the same way under the
  `stderr` grant.

- **Gated and bounded.** Every read and write revalidates its grant and audits
  the operation exactly like a host file port, and each input refill and output
  flush is charged against the host-callback budget, so even an unbounded stream
  stays budget-bounded and fail-closed. Offering a device without its grant denies
  and records the denial; without a device the stream is left untouched. The
  default — no device, no grant — is reads/writes deny.

This is realized identically on both hosts in the shared evaluator (`(consent
eval)` and the `consent-eval.el` twin), so a `--script` / shebang filter and a
`--eval` program behave the same on the portable and Emacs hosts.

#### Interactive multiplexing: one shared stdin cursor

In a REPL session the form reader and `program-input` share **one stdin cursor**
in time order, so a submitted form can read its stdin without corrupting the
loop. The REPL session authorizes its own stdin by invocation, so program input
is connected by default (symmetric with the session's already-connected program
output). Each turn:

1. The loop reads one complete form from the cursor.
2. The submission's terminating newline is consumed as the **submission
   boundary** — the Enter that submits a line is not program data. (Precisely:
   after the form, horizontal whitespace then exactly one newline is consumed;
   text remaining on the form's own line stays program input.)
3. Evaluation runs; any `read`/`read-line`/`read-char` consumes the input that
   follows, refilling from stdin as needed.
4. Whatever the form did not read is threaded back as the next form-reading
   buffer.

So `(display (read-line))` ⏎ then `hello` ⏎ reads `"hello"`, and a following
`(+ 1 2)` ⏎ is still read as its own submission, not stolen. "No character
stealing" is structural: there is exactly one monotonic cursor, the loop never
re-reads bytes a program already consumed, and a program read never grabs a
half-read form. (#392 pins this cross-host with the `repl-program-input-no-steal`
case.) Putting a reading form and more text on a single line is the one corner:
the read consumes that trailing text as program data.

#### Remaining work

The model above is complete for piped and `--script`/`--eval`/`--repl` use, for
textual and binary streams alike. Two extensions are deliberately out of scope
here and tracked for their own issues:

- **Promptable runtime stdio grants.** Requesting a stdio grant *at runtime*
  (rather than by invocation) — a script that asks for stdin/stdout mid-run — is
  part of the non-interactive script authority posture (#400). The mechanism here
  is the substrate it builds on.
- **TTY line editing.** Cooked-mode echo, history, and completion on a live
  terminal (the in-editor comint surface, #514) ride above this cursor and are
  not part of the contract.

(Binary stdio — `read-u8`/`peek-u8`/`read-bytevector` and `write-u8`/
`write-bytevector` over a `stdio`-backed byte port — was the third extension and
is now connected as of #528, described in the Program Stream Model above.)

## Record Vocabulary

All records are Scheme-readable data. They are the shared surface #391, #360, and
the #392 conformance fixtures reference. Field order is not significant; fields
marked optional may be omitted. Hosts must not expose raw host objects (buffers,
ports, processes, continuations, live environments) inside these datums — only
the stable renderings already defined by `(consent result)` and the session and
handle vocabulary.

### Contract identity

Fixtures pin the contract version so a host can declare which revision it
implements.

```scheme
(repl-interaction-contract
  (version 1)
  (session-scopes (named project))
  (interaction-environment (scheme repl)))
```

### `repl-prompt`

Emitted on the `repl-prompt` stream before the loop reads a form.

```scheme
(repl-prompt
  (session project-main)
  (ordinal 3)            ; one-based count of the next submission
  (state ready)          ; ready | continuation
  (pending #f)           ; #t when partial input from a prior turn is buffered
  (nesting 2)            ; continuation only: count of still-open constructs
  (pending-kind list))   ; continuation only: innermost open construct kind
```

- `state ready` is the primary prompt for a new submission. `state continuation`
  is re-emitted when the reader reported an incomplete form and the loop is
  waiting for the rest of the same submission; `pending` is then `#t`.
- `ordinal` counts submissions in the session, not physical lines. A multi-line
  form that needs several continuation prompts keeps the same `ordinal` until it
  is submitted.
- A continuation prompt carries the reader's **pending-nesting indicator**,
  derived from the recovery-aware reader's incomplete-form state (#418) rather
  than re-derived by the loop: `nesting` counts the constructs still open at the
  end of the buffered input, and `pending-kind` names the innermost one —
  `list`, `vector`, `bytevector`, `string`, `symbol` (a vertical-bar symbol),
  `comment` (a block comment), or `datum` when only a datum prefix (such as a
  quote or `#;`) awaits its datum with no construct open. Both fields are
  omitted on `state ready` prompts. A chrome may render the depth as a
  continuation gutter; the fields themselves stay host-neutral and are
  parity-asserted by #392.

### `repl-submission`

One reading attempt. A complete read produces a submission with the form's
external text and a `complete` flag; an incomplete read produces a submission
that requests more input.

```scheme
(repl-submission
  (id sub-3)
  (session project-main)
  (ordinal 3)
  (source "(define (double x) (* x 2))")  ; external text the reader consumed
  (complete #t)          ; #t when a whole datum was read
  (eof #f))              ; #t when reading hit end of file
```

- When `complete` is `#t`, the submission named a single whole form and the loop
  proceeds to evaluation. The submission records external `source` text rather
  than a live datum so the record stays portable and redactable, consistent with
  `transcript-event` `form`.
- When `complete` is `#f` and `eof` is `#f`, the reader saw an incomplete prefix;
  the loop emits a continuation `repl-prompt` and keeps the buffered text for the
  same `ordinal`. No `repl-result` is produced for an incomplete submission.
- When `eof` is `#t`, input ended. If `complete` is also `#f` while bytes were
  buffered, the trailing partial form is a reader condition (see below) before
  the session closes; an `eof` with no buffered partial form closes cleanly.

### `repl-result`

The rendered outcome of evaluating a complete submission. It wraps, without
reshaping, the existing `evaluation-result` datum.

```scheme
(repl-result
  (id res-3)
  (submission sub-3)
  (session project-main)
  (ordinal 3)                   ; the submission's one-based count, mirroring repl-prompt
  (evaluation-result
    (evaluation-result
      (status ok)
      (value (procedure (kind compound)))
      (events ())
      (budget ...)))
  (display "#<procedure>"))     ; optional human-readable rendering
```

- `evaluation-result` is exactly the datum produced by `(consent result)`
  `ok-result-datum` — `status ok` with a single rendered `value`, or
  `status values` with a rendered `values` list (the empty list for zero
  values). The REPL adds no fields to it.
- `ordinal` is the submission's one-based count, the same value the correlated
  `repl-prompt` carries. It lets a pure per-record chrome align the result
  marker to the prompt-gutter width without parsing the `submission` id. (A
  chrome may also derive it from the `(submission sub-N)` id; the field makes
  that a contract guarantee rather than a coupling to the id format.)
- `display` is an optional convenience string for terminal/buffer presentation,
  derived from `consent-value->external`. It is never the canonical result; the
  embedded `evaluation-result` datum is.
- `display` is **bounded** so a deep, long, or cyclic value — such as one an
  agent loop's untrusted code produces — renders in bounded time and space
  instead of wedging the loop or flooding the stream (#508). Each interactive
  session renders the value within a depth, length (element count), and total
  character-size ceiling, eliding at every limit with the canonical, parseable
  truncation marker `...`; shared or circular structure is detected and broken
  with the same marker, so rendering always terminates. The bound applies to the
  human `display` only — the embedded `evaluation-result` keeps full fidelity, so
  capture and replay round-trip unchanged. The default ceiling is depth 8, length
  64, and size 4096 characters, identical on both hosts (`cli-repl-default-render-limits`
  in `(cli repl-shell)` and `consent-repl-stream-default-render-limits` in
  `consent-repl-stream.el`); a session overrides it with a `render-limits`
  evaluator option, `((depth . D) (length . L) (size . S))`, where any component
  may be `#f` for no ceiling. The shared corpus pins the marker and each bound on
  both hosts.
- A `repl-result` is written to the `repl-result` stream. Anything the form
  itself printed went to `program-output` during evaluation and is not duplicated
  here.

### `repl-condition`

A reader or evaluator condition. This single record covers both recoverable
reader conditions (incomplete input, malformed input) and evaluation errors, so
fixtures can assert that a session keeps running after a recoverable condition.

```scheme
(repl-condition
  (id cond-4)
  (submission sub-4)
  (session project-main)
  (ordinal 4)            ; the submission's one-based count, mirroring repl-prompt
  (phase eval)           ; read | eval
  (recoverable #t)       ; #t when the session continues; #f when it must close
  (condition
    (debugger-condition ...))  ; exactly condition-result-datum's condition field
  (display "unbound variable: undefined-name"))
```

- `phase read` covers reader conditions. An *incomplete* prefix is normally
  surfaced as a continuation prompt, not a `repl-condition`; a `repl-condition`
  with `phase read` is used for a malformed datum, or for a partial form left
  unterminated at EOF. Recoverable reader conditions skip the rest of the current
  line/buffer to the next form boundary and keep the session open.
- `phase eval` covers evaluation errors and raised exceptions. The `condition`
  field is the same debugger condition datum `(consent result)`
  `condition-result-datum` / `debugger-exception-datum` produce, including its
  restart options. The session's interaction environment is unchanged by a failed
  submission (a failed `define` does not partially mutate it) and remains
  available for the next submission.
- `recoverable #t` means the loop renders the condition on `repl-diagnostic` and
  continues. `recoverable #f` is reserved for conditions that force the session to
  close (for example, loss of the interaction environment); it is immediately
  followed by a `repl-exit`.
- `ordinal` is the submission's one-based count, as on `repl-result`, so a chrome
  aligns the condition marker the same way.
- `display` is the optional human-readable diagnostic. An evaluator/budget error
  renders with the host-neutral canonical prefix both twins build —
  `consent eval error: <message>` / `consent budget error: <message>` — so the
  diagnostic is byte-identical across hosts wherever the inner `<message>`
  wording agrees. Converging that inner wording across the two interpreters (for
  example `unbound identifier` vs `unbound identifier: NAME`) is tracked
  separately as a runtime-parity follow-up; until then a fixture pins the marker
  and prefix, not the full message, for conditions whose wording still differs.

### `repl-exit`

The terminal record of a session. Every conforming session ends with exactly one
`repl-exit`, carrying a documented close status.

```scheme
(repl-exit
  (session project-main)
  (reason eof)           ; eof | explicit | host-close | fatal
  (status closed-ok)     ; closed-ok | closed-error
  (count 7)              ; submissions evaluated in the session
  (detail #f))           ; optional condition or message explaining a fatal close
```

Close `reason` values:

- `eof` — interaction input reached end of file with no buffered partial form.
  Status `closed-ok`.
- `explicit` — the user or driver requested exit (for example, the standard
  `(exit)` request routed through the session, or a host close command). Status
  is `closed-ok` for an ordinary exit; an exit carrying a nonzero object renders
  `closed-error` with that object in `detail`.
- `host-close` — the host tore the session down (buffer killed, daemon client
  disconnected, controlling terminal lost). Status reflects whether durable state
  was preserved.
- `fatal` — a non-recoverable condition (such as loss of the authorized
  interaction environment) closed the session. Status `closed-error`, with the
  condition in `detail`.

The close status is the portable signal #360 maps to a process exit code and #391
maps to a buffer/session disposition; the contract fixes the status vocabulary,
not the host's encoding of it.

## EOF and Explicit Exit

- **EOF.** When the interaction input is exhausted between forms, the loop stops
  reading and emits `(repl-exit (reason eof) (status closed-ok) ...)`. EOF is the
  normal close for a scripted, piped, or `--script`-style session.
- **EOF mid-form.** If input ends while a partial form is buffered, the loop first
  emits a `repl-condition` with `phase read` and `recoverable #f` describing the
  unterminated form, then `(repl-exit (reason eof) (status closed-error) ...)`.
- **Explicit exit.** A request to end the session (the standard process-context
  `exit`/`emergency-exit` request observed inside the session, or a host-level
  close command) ends the loop after the current submission and emits
  `(repl-exit (reason explicit) ...)`. The exit request is observed as a session
  control signal; it does not bypass the close record.
- A session emits its `repl-exit` exactly once. After close, the session does not
  read further input, and a durable (`named`/`project`) session transitions per
  [Session Lifecycle and Snapshots](session-lifecycle.md) (`idle`, `suspended`,
  or `retired`) rather than vanishing.

## Policy-Gated Host Effects

The REPL is a driver over the capability/policy boundary; it grants no new
authority of its own.

- Acquiring the session interaction environment requires the `repl` capability.
  Its standard manifest entry sets `(required-capability repl)` with
  `(policy session)`, so it is authorized only inside an active session and fails
  closed otherwise. A loop with no authorized interaction environment never opens;
  it reports the denial as a `repl-condition`/`repl-exit` rather than evaluating
  in an ambient environment.
- Effects performed *by* evaluated forms — file, process, model, editor,
  persistence, clock — flow through the same capability requests, decisions,
  grants, and audit records defined in
  [Capability Environment and Effect Lowering](capability-environment.md). The
  REPL adds no implicit grants; an unauthorized effect fails closed with its
  normal capability condition, surfaced as a `repl-condition`.
- Approval prompts use the prompt posture in the
  [Native CLI and Daemon Adapter Contract](native-cli-daemon-adapter.md): they are
  rendered on the `repl-approval` interaction stream, never by consuming
  `program-input`, and the resulting `approval-decision`/`capability-decision`
  datums still pass through the capability environment. In a noninteractive
  (piped/batch) session, a `confirm` action with no covering grant fails closed
  with `noninteractive-confirmation-unavailable`.
- No record in this contract exposes a raw host object. Live environments,
  buffers, ports, processes, and continuations appear only through the stable
  renderings of `(consent result)` (for example `(environment)`,
  `(port ...)`, `(procedure (kind continuation))`) and through session/handle
  records, so a scripted consumer of the REPL never receives unwrapped host
  authority.

## Capture and Replay

Because the entire interaction surface is Scheme-readable records, a captured
session is, in principle, a replayable program. This section makes that
round-trip a defined capability: a capture format and a replay driver on both
hosts, with an explicit statement of what replay reproduces, what it cannot, and
how a divergence is reported. A captured transcript therefore doubles as a
reproducible bug report and a test-fixture capture.

### Capture format

The canonical capture format is the `datum` chrome's record stream: every
contract record (`repl-prompt`, `repl-submission`, `repl-result`,
`repl-condition`, `repl-exit`) written by the consent writer, one datum per line.
This is the same canonical surface the parity corpus asserts against, so capture
introduces no new vocabulary — it is the record stream, persisted. On the
portable host:

```sh
printf '(+ 1 2)\n(define base 7)\n(* base 3)\n(exit)\n' \
  | tools/consent-repl --chrome datum 2>session.scm
```

The stream is plain Scheme data, so it reloads with an ordinary reader. Binary
and non-record transcript formats are deliberately out of scope; the record
stream is the only capture format.

### Replay model

Replay reconstructs the interaction input from the captured **complete
submissions** — each `repl-submission` with `(complete #t)` contributes its
`source`, in order — and re-feeds that input to a **fresh session**. The loop
re-reads and re-evaluates each form exactly as if it had been typed; replay adds
no new evaluation path. The capture's own results and conditions are *not*
re-applied: replay re-derives them, which is what makes a divergence meaningful.

The driver is exposed as library procedures on both hosts and as a terminal
mode:

- Portable: `cli-repl-records-from-datum-stream`, `cli-repl-submissions-from-records`,
  `cli-repl-replay-records`, and `cli-repl-replay-report` in `(cli repl-shell)`;
  `tools/consent-repl --replay FILE` (or `consent --repl --replay FILE` on a
  compiled binary) reloads `FILE`, replays it, and emits the replayed stream
  through the selected chrome.
- Emacs: `consent-repl-stream-records-from-datum-stream`,
  `consent-repl-stream-submissions-from-records`,
  `consent-repl-stream-replay-records`, and `consent-repl-stream-replay-report`
  in `consent-repl-stream.el`; `consent-repl-stream-replay-main` is the batch
  twin of `--replay FILE`.

### What replay reproduces

For a transcript whose every input chunk became a complete submission and whose
forms are deterministic, replay re-emits an **equal record stream**: the same
submissions in the same order, the same prompts (including continuation prompts
and their pending-nesting indicator), the same results and recoverable
conditions, and the same close record. The `repl-submission` `source` preserves
each form's external text, including the internal newlines of a continued form,
so a multi-line or multiple-forms-per-line transcript reproduces the same
submission boundaries.

### What replay cannot reproduce

Replay is **not** a recording of effects; it is a re-evaluation. Two classes of
content do not round-trip, and the contract requires that they fail closed
rather than silently:

- **Input that produced no replayable submission.** A bare reader condition (a
  malformed datum) emits a `repl-condition` but no `repl-submission`, and an
  EOF-truncated form is a submission with `(complete #f)`. Neither is a
  replayable source, so for such a transcript replay is a strict subset: it
  carries the complete submissions forward and drops the unreplayable artifact.
- **Live host effects.** A replay session carries only the authority it is
  granted (see [Policy-Gated Host Effects](#policy-gated-host-effects)). A form
  whose captured `repl-result` depended on a capability grant is re-evaluated
  under the replay posture; without the same grant it **fails closed** with its
  normal capability condition, surfaced as a `repl-condition`. Replay never
  re-performs a recorded effect from the transcript and never fabricates the
  recorded value. A non-deterministic effect (clock, randomness, external state)
  may also differ even when the grant is present.

### Reporting divergence

A replay report compares the captured and replayed streams **per submission** by
outcome `kind` (`result`, `condition`, or `none`) and `display` rendering, and
records each mismatch:

```scheme
(repl-replay-report
  (status diverged)        ; reproduced | diverged
  (submissions 1)          ; complete submissions compared
  (divergences
    ((repl-replay-divergence
       (index 1)
       (source "(begin (import (scheme file)) (open-output-file \"out\"))")
       (captured (kind result) (display "(port (kind output))"))
       (replayed (kind condition) (display "... file capability denied ..."))))))
```

A captured `result` that replays as a `condition` is the canonical fail-closed
signal: the effect could not be reproduced under the replay posture, and the
report says so rather than letting the divergence pass. The `--replay FILE`
terminal mode (and the Emacs batch twin) emit the replayed record stream, append
the `repl-replay-report` datum, and exit non-zero when the report is `diverged`,
so a scripted consumer gets the same fail-closed signal as an exit code. Because
capture and replay run on the **same host**, a reproduced transcript replays to
a byte-identical record stream; the comparison is over the serialized stream, so
value-equal canonical numbers compare equal across hosts.

### Live-state restore is separate

Replay-of-records needs nothing beyond the contract: it re-feeds submissions and
re-evaluates. Restoring a session's *live* interaction environment — its
already-bound definitions, imports, and macros — without re-evaluating the
submissions that built them is a distinct capability that coordinates with
[Scheme-callable session management](session-lifecycle.md) and is **not** part of
this round-trip. Replay reconstructs state by re-running the forms; live-state
restore would snapshot and reload it.

### Conformance

The [#392 corpus](../fixtures/repl/parity-cases.scm) marks each case with a
`replay` field — `(replay reproduced)` for a transcript that round-trips to an
equal stream, or `(replay (partial (reason R)))` for one whose input includes an
unreplayable artifact — and both parity runners assert the round-trip in both
directions on both hosts, so the reproduces-versus-cannot split is itself
parity-checked.

## Parity Versus Host-Specific Obligations

The contract is meaningful only if it is clear which obligations both hosts must
satisfy identically and which each host may realize in its own way.

### Host-neutral obligations (parity-required)

Both the Emacs and portable hosts MUST satisfy these identically; #392 asserts
them against both:

- one-complete-form-at-a-time incremental reading, including continuation of an
  incomplete form and ordered evaluation of multiple forms in one input chunk;
- evaluation in a durable session interaction environment with definitions,
  imports, and macros persisting across submissions in the same session;
- the record vocabulary above (`repl-prompt`, `repl-submission`, `repl-result`,
  `repl-condition`, `repl-exit`) with equivalent fields and the same ordering of
  records for the same input;
- value, multiple-value, and zero-value rendering through the existing
  `evaluation-result` datum, with no REPL-added result fields;
- recoverable reader/evaluator conditions that keep the session open, rendered
  through the existing debugger condition datum;
- separation of interaction streams from program stdin/stdout/stderr, so program
  output is uncorrupted by prompts, results, diagnostics, or approval prompts;
- EOF and explicit-exit handling, with exactly one `repl-exit` and the documented
  close-status vocabulary;
- policy-gated host effects that fail closed without explicit grants and expose no
  raw host objects.

### Host-specific obligations (realization may differ)

Each host MAY realize these as fits its environment, as long as the host-neutral
records and behavior above are unchanged:

- **Input source and editing.** The portable host draws interaction input from a
  terminal/stdin byte stream (the `(cli repl-shell)` shell, `tools/consent-repl`,
  `make repl`); Emacs draws it from batch stdin or a submitted buffer/region (the
  `consent-repl-stream` adapter — `consent-repl-stream-main` for a scripted
  `emacs --batch` session and the `consent-repl-stream` command interactively).
  Both read one complete form at a time over the shared recovery-aware reader.
  Line editing, history, completion, and key bindings are explicitly out of scope
  here (#360, #391, and later issues) and are not part of the contract.
- **Physical stream multiplexing.** A terminal may render prompts/results/
  diagnostics inline on one TTY; the Emacs batch entry writes the canonical
  record stream to the error/control channel and program output to stdout, while
  the in-editor surface renders across its native session buffers
  (`*Consent Scheme: PROJECT*`, `*Consent Events: PROJECT*`,
  `*Consent Approvals: PROJECT*`). Both must preserve the logical channel
  separation.
- **Close-status encoding.** The portable terminal maps `repl-exit` status to a
  process exit code; the Emacs batch entry maps it to the `emacs --batch` exit
  code (`closed-ok` → 0, `closed-error` → 1), and the in-editor surface to a
  session disposition and buffer state. The status vocabulary is shared; its
  encoding is host-specific.
- **Prompt presentation and approval UX.** The exact prompt strings, redaction
  rendering, and approval interaction belong to each host, within the prompt
  posture and audit obligations of the capability and CLI/daemon contracts.
- **Presentation chrome.** The everyday human view rides above the records as a
  *chrome*: a pure function from each record to readable output, with styling
  expressed as named **semantic roles** (`furniture`, `prompt-session`,
  `prompt-ordinal`, `prompt-nesting`, `result-marker`, `result-value`,
  `error-marker`, `error-text`, `exit-marker`, `exit-status`, `output-marker`,
  `output-text`). The chrome *model* — the named set
  (`comment` default, `datum`, `classic`, `quiet`, `silent`) and the
  record-to-role mapping — is host-neutral and shared; the *substrate* is
  host-specific. The portable terminal renders roles as ANSI SGR
  (`(cli repl-chrome)`); Emacs renders the same roles as faces in the session
  buffer (`consent-repl-chrome.el`). This is familiarity, not byte-identity:
  forcing ANSI into a buffer (or faces onto a TTY) would fight both hosts. The
  `datum` chrome reproduces the canonical record stream and is always reachable
  on every host, so no chrome can suppress the parity surface. The chromes treat
  `program-output` by a per-chrome policy carried by an **output formatter**
  (`cli-repl-chrome-output-formatter` / `consent-repl-chrome-output-formatter`):
  the replayable `comment` chrome *owns* it, rendering each line as an aligned
  `;;   :: ` comment on the control channel (so the transcript replays the output
  and stdout stays clean), while `classic`, `quiet`, `silent`, and `datum` leave
  it raw on stdout. The formatter is presentation, not a record; the engine stays
  chrome-agnostic (see [Stream Separation](#stream-separation)).
- **Scheduling.** Foreground versus background/job-driven evaluation and any
  buffer or daemon bookkeeping are host concerns, provided submissions are
  evaluated in order and each produces its contract records.

Where a future host slice can only implement one side first, the remaining parity
work must be recorded in the issue, commit, or PR per the repository agent
instructions, rather than treating the divergence as complete.

## Forward Compatibility

The v1 contract above is deliberately minimal: synchronous turns and a flat error
model. Its extension model is the `version` field plus additive, optional record
fields, so most later features arrive without a breaking change. This section
names the extension points that are *not* cheap to retrofit — and one deliberate
non-goal — so the #392 corpus does not harden v1 assumptions a later revision must
break. Each maps onto substrate this project already has; none is implemented
here.

Conformance guidance for #392: v1 fixtures assert synchronous, positional record
ordering for a single foreground turn. They MUST treat the `(submission sub-N)`
correlation — not record position — as the durable join between a submission and
its result or condition, and MUST NOT assert that a reader/evaluator condition
always continues at the same interaction level. Those two assumptions are
revision-scoped, not contract-permanent.

### 1. Asynchronous evaluation and cancellation

Given the cadence of agent prompting (the Chunk 0.17 agent harness, #397), a
submission will often run in the background and stream rather than block the loop.
A later revision adds:

- a submission lifecycle observable as
  `(state pending | running | done | cancelled)`, so a turn can be in flight while
  the loop reads the next submission;
- result and condition correlation strictly by `(submission sub-N)` id, since
  submissions may complete out of order;
- a contract-level cancel/interrupt signal that maps onto the existing job
  cancellation path in [`jobs.md`](jobs.md) (the `agent-yield` streaming workflow
  and the `(locked-by-job j-N)` session lock), rather than a host keystroke.
  Cancelling a running submission yields a `repl-result`/`repl-condition` with a
  cancelled disposition, never a silently dropped turn.

This is the one place v1's "same ordering of records" parity property is
explicitly synchronous-only.

### 2. Nested interaction levels (the debugger is the REPL)

v1 renders a recoverable condition and continues to the next submission — a flat
model. The Lisp-tradition paradigm the project wants is a *nested break loop*: at
an error, drop into a new interaction level whose environment is the failed frame,
inspect it, choose a restart, and pop back. A later revision adds:

- a `(level N)` field on `repl-prompt`, and a session interaction-level stack
  rather than a single loop;
- entry into a nested level on an evaluator condition, exposing the restart
  options already carried in the debugger condition datum
  (`debugger-default-restarts`, restart ids — see [`debugger.md`](debugger.md)) as
  selectable actions;
- level-pop, abort-to-top, and restart-selection as level transitions, each
  emitting the same `repl-prompt`/`repl-result`/`repl-condition`/`repl-exit`
  records at the active level.

The nested environment and frames are exposed only through the existing
Scheme-readable debugger datums; no raw frame or continuation object is exposed.

### 3. Prompting and control stay ordinary forms; no meta-command syntax (non-goal)

Submissions are Scheme forms, and they remain so. Agent prompting (the Chunk 0.17
`(agent prompt)` verbs, #397) is reached the same way as any other behavior —
`(prompt "Why is the sky blue?")`, an ordinary procedure call lowered through the
provider/agent capability boundary. The contract deliberately declines special
reader syntax, raw unquoted-text input, or a bare-string prompt mode for this:

- the procedure call is already ergonomic, and it keeps prompting scriptable in
  `--script` and shebang runs rather than confined to an interactive surface;
- auto-routing a bare top-level string to the harness would steal
  self-evaluation — a submitted `"hi"` should keep echoing as its own value, not
  prompt a model;
- raw unquoted text is the only one of these that would require a reader mode at
  all, and declining it keeps the v1 reader a pure R7RS reader.

No meta-command syntax (`,backtrace`, `:doc`, `%time`, …) is introduced or
reserved. Such a sigil buys nothing a namespaced procedure does not buy more
cheaply: brevity, discoverability, don't-evaluate-the-argument, and raw-text
capture are all covered by ordinary procedures and macros in a `(repl …)` /
`(agent …)` library — which additionally stay scriptable in `--script`/shebang
runs, deterministic, capability-introspectable, and parity-testable, where a
meta-command would not. Introspection and control are therefore ordinary
procedures (the Clojure stance: `apropos`, `doc`, `describe`, `trace` are
bindings, not commands).

The one thing a meta-command can do that a procedure cannot is run when normal
evaluation is untrustworthy — the debugger break loop. The contract handles that
case without inventing a syntax: at a nested interaction level (point 2) the only
non-form input is **restart selection** over the restart options already carried
as data in the debugger condition datum (`debugger-default-restarts`, restart
ids). Selecting a restart by id is eval-independent and renders identically on
both hosts, so it needs neither a sigil nor a submission-`kind` discriminator. No
meta-command lexicon is left open for a later revision.

### Resolved: last-value bindings (neither host)

Whether a REPL session binds recent results to convenience identifiers
(`*1`/`*2`/`*3`, or `it` for the last value) was left open until the two host
implementations settled it. It is small, but it is a **parity decision, not a
per-host accident**: if one host binds `*1` and the other does not, #392 fails.
Both the portable terminal REPL (#360) and the Emacs incremental entry (#391)
ship **without** last-value bindings, so the decision is settled as *neither
host binds*, and it is now a host-neutral obligation: a future revision that
introduces them must do so on both hosts together. The contract continues to
decline meta-command syntax for the same reasons given above; a last-value
binding, if added, is an ordinary identifier, not a sigil.

## Conformance

The shared cross-host REPL parity conformance fixtures (#392) encode this
contract as a `consent-fixture-suite` corpus,
[`fixtures/repl/parity-cases.scm`](../fixtures/repl/parity-cases.scm), whose
cases drive a scripted interaction input and assert the emitted sequence of
`repl-prompt`, `repl-submission`, `repl-result`, `repl-condition`, and
`repl-exit` records against both hosts. Two parallel runners read that one
corpus: `tests/scheme/consent-repl-parity-test.scm` drives the portable terminal
REPL shell `(cli repl-shell)`, and `tests/consent-repl-parity-test.el` drives the
Emacs incremental entry `consent-repl-stream`. Each case enumerates every record
its turn produces; the runners assert per-kind record counts and the
contract-meaningful fields of each record, correlating a
`repl-result`/`repl-condition` to its submission by the `(submission sub-N)`
field rather than by record position (see [Forward
Compatibility](#forward-compatibility)). Host-specific text — condition
`message`/`display` strings and the opaque `value`/`budget` payloads — is
deliberately not pinned, so the corpus fixes the record shape, not a host's exact
rendering.

Because a REPL session is a host-effecting `(scheme repl)` surface, those cases
are not reference-oracle eligible; they are parity checks between the Emacs and
portable hosts, feeding the parity CI gate (#374). The portable terminal REPL
(#360) and the Emacs incremental entry (#391) each implement this contract on
their respective host and are validated against the #392 corpus. The portable
runner runs on every full-suite R7RS host shard (and, like the other portable
test files, under Chibi through the shared host suite in
`make test-portable-chibi`); the Emacs runner runs under `make test`. A host
prerequisite that is unavailable skips with an actionable message rather than
failing.
