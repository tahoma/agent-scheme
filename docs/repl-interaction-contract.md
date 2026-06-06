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
owned by their own issues.

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
  (pending #f))          ; #t when partial input from a prior turn is buffered
```

- `state ready` is the primary prompt for a new submission. `state continuation`
  is re-emitted when the reader reported an incomplete form and the loop is
  waiting for the rest of the same submission; `pending` is then `#t`.
- `ordinal` counts submissions in the session, not physical lines. A multi-line
  form that needs several continuation prompts keeps the same `ordinal` until it
  is submitted.

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
- `display` is an optional convenience string for terminal/buffer presentation,
  derived from `consent-value->external`. It is never the canonical result; the
  embedded `evaluation-result` datum is.
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
  (`*Consent Scheme: PROJECT*`, `*Agent Events: PROJECT*`,
  `*Agent Approvals: PROJECT*`). Both must preserve the logical channel
  separation.
- **Close-status encoding.** The portable terminal maps `repl-exit` status to a
  process exit code; the Emacs batch entry maps it to the `emacs --batch` exit
  code (`closed-ok` → 0, `closed-error` → 1), and the in-editor surface to a
  session disposition and buffer state. The status vocabulary is shared; its
  encoding is host-specific.
- **Prompt presentation and approval UX.** The exact prompt strings, redaction
  rendering, and approval interaction belong to each host, within the prompt
  posture and audit obligations of the capability and CLI/daemon contracts.
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
contract as `consent-fixture-suite` cases that drive a scripted interaction
input and assert the emitted sequence of `repl-prompt`, `repl-submission`,
`repl-result`, `repl-condition`, and `repl-exit` records against both hosts.
Because a REPL session is a host-effecting `(scheme repl)` surface, those cases
are not reference-oracle eligible; they are parity checks between the Emacs and
portable hosts, feeding the parity CI gate (#374). The portable terminal REPL
(#360) and the Emacs incremental entry (#391) each implement this contract on
their respective host and are validated against the #392 corpus.
