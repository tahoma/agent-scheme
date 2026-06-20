# Jobs, Cancellation, and Streaming Yields

Consent Scheme represents long-running or concurrent work as Scheme-readable
`job` datums.  The Emacs host adapter owns the live thread and session lock;
the public record stays printable and inspectable:

```scheme
(job
  (id j-1)
  (session project-main)
  (kind eval)
  (status running)
  (can-cancel #t)
  (started-at "2026-05-24T16:00:00-0700")
  (budget (max-steps 100000)
          (max-host-callbacks 10000)
          (max-events 1000)
          (max-value-nodes 10000000)
          (max-interned-symbols 1000000)
          (max-output-bytes 10485760)
          (max-wall-time-ms #f))
  (yields ((yield (phase ready)))))
```

The `budget` field is the job's declared ceilings across every comprehensive
budget dimension (see [budgets.md](budgets.md)); `max-wall-time-ms` is `#f` when
wall time is unbounded.  A completed job reports the consumed counters in its
result's own `budget` field, so a consumer reads remaining headroom as the
declared ceiling minus the used count per dimension.

## Foreground Evaluation

Foreground REPL evaluation still uses the session APIs described in
[`session-lifecycle.md`](session-lifecycle.md).  A call such as
`consent-session-eval-source` runs to completion before the caller regains
control.  During that evaluation the session moves through `active` and then
back to `idle`, `failed`, or another terminal lifecycle state.  This mode is
best for short forms where the caller wants the value immediately.

Foreground evaluation is refused while a background job owns the session lock.
That rule prevents two evaluations from mutating the same lexical environment,
macro environment, capability grants, handles, and transcript at the same time.

## Background Jobs

Background evaluation starts with `(job-start! session form options)` from
`(agent job)` or `consent-job-start!` from Emacs Lisp.  The job begins in
`queued`, then moves to `running` when the host thread starts evaluating.  The
same session environment is used, but the session records `(locked-by-job j-N)`
until the job finishes and cleanup releases the lock.

The core procedures are:

```scheme
(job-start! 'project-main "(import (scheme base) (agent io)) (agent-yield '(ready)) 'done" '())
(job-ref 'j-1)
(job-list 'project-main)
(job-status 'j-1)
(job-yields 'j-1 '((after . 0)))
(job-cancel! 'j-1)
(job-interrupt! 'j-1 'debug-break)
```

`job-yields` returns the ordered stream of `(agent io)` events recorded so far:
`yield`, `progress`, `warn`, `log`, and `request` records.  Use the `after`
option to skip events already displayed in a REPL buffer.

## Cancellation And Interrupts

Cancellation is cooperative at evaluator step boundaries.  The evaluator checks
the active job context while it records step budgets, so tail-recursive loops
and normal expression evaluation stop cleanly without corrupting the session
environment.  A cancelled job records `cancel-requested` first, then
`cancelled` after the evaluator unwinds.  The transcript and audit log record
the cancellation message and any events emitted before cancellation.

`job-interrupt!` records the supplied reason and asks the evaluator to stop at
the same control point.  Interrupts finish the job as `failed` with a clear
`job interrupted: REASON` error so debugger and REPL code can distinguish them
from ordinary budget failures.

Host primitives that do not return to the evaluator cannot be preempted by the
portable model alone.  Host adapters should keep long host effects behind
capability-specific cancellation or process supervision and then reflect the
result back into the same job record shape.
