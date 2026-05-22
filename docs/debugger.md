# Agent Scheme Debugger

The debugger surface turns evaluator failures and Scheme-raised exceptions into
Scheme-readable condition datums. The outer host can render those datums in a
REPL, transcript, job, or UI without receiving raw host objects.

## Condition Datums

Result-producing evaluation returns debugger condition records under the
`error` field:

```scheme
(evaluation-result
  (status error)
  (error
    (condition
      (condition
        (type unbound-variable)
        (message "unbound identifier: missing")
        (symbol missing)
        (phase evaluation)
        (stack ((frame (id f-0) (phase evaluation))))
        (environment
          ((frame f-0)
           (bindings ((binding (name +)) ...))
           (truncated #t)))
        (restarts
          ((restart
             (id abort)
             (category abort)
             (policy pure-r7rs)
             (status available))))))))
```

The current environment snapshot is intentionally shallow. It exposes binding
names, the frame id, and whether the frame was truncated. It does not expose
binding values, closures, ports, handles, or host objects.

## Library

Programs can import `(agent debugger)` beside `(scheme base)`:

```scheme
(import (scheme base)
        (agent debugger))
```

The library exports:

- `current-error`: returns the active debugger condition during exception
  handling, or `#f` otherwise.
- `condition-stack`: returns stack frame records from a debugger condition.
- `condition-environment`: takes a condition and frame id. Pass `#f` to return
  all environment frame records, or a frame id such as `'f-0` to return one.
- `condition-restarts`: returns restart records from a debugger condition.
- `restart-invoke!`: invokes restarts that the current runtime can model.
- `debugger-yield`: records a debugger event in the evaluation result event
  stream.

Example:

```scheme
(with-exception-handler
 (lambda (condition)
   (condition-restarts (current-error)))
 (lambda ()
   (raise-continuable 'boom)))
```

## Restarts

Restart records are data first. They describe what a host debugger, transcript
viewer, or REPL could offer without requiring the evaluator to perform host
work directly.

The core restart ids are:

- `abort`: stop the current evaluation.
- `retry`: retry after a host debugger prepares a new evaluation attempt.
- `provide-value`: continue by supplying a value for the failing expression.
- `define-binding`: define a missing binding and retry.
- `import-library`: import a missing library or binding and retry.
- `continue-with-warning`: continue and return a restart result record.
- `request-user-input`: ask the host or user for a recovery decision.

The current bootstrap implementation invokes `continue-with-warning` directly
and treats the other recovery restarts as host debugger policy hooks. Later
transcript, job, budget, and process integrations should consume these same
condition and restart datums instead of inventing separate error payloads.

## Host Boundary

Debugger data follows the same host boundary as other Agent Scheme state:

- Conditions, stack frames, environment summaries, restarts, and debugger
  events are ordinary Scheme-readable datums.
- Raw host conditions, closures, handles, and live environment cells stay
  private to the runtime.
- Emacs Lisp and portable R7RS implementations should keep the public datum
  shape in parity when evaluator behavior changes.
