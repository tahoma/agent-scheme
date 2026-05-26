# Macro Expansion Introspection

Agent Scheme exposes macro expansion as Scheme-readable data through
`(agent reflect)`. The introspection procedures expand forms in the current
session's syntax environment and return records; they do not evaluate the
expanded expression.

## REPL Session Use

Start or switch to a native REPL session, define a macro, then inspect a use:

```scheme
(import (scheme base)
        (agent reflect))

(define-syntax my-unless
  (syntax-rules ()
    ((my-unless test body ...)
     (if test #f (begin body ...)))))

(macroexpand-1 '(my-unless #f 42))
```

The result is a `macro-expansion` datum with stable fields:

```scheme
(macro-expansion
  (status ok)
  (mode one-step)
  (original (my-unless #f 42))
  (expanded (if #f #f (begin 42)))
  (steps ((step
            (index 1)
            (macro my-unless)
            (input (my-unless #f 42))
            (output (if #f #f (begin 42))))))
  (macros (my-unless))
  (source #f)
  (warnings ())
  (errors ()))
```

Use `(macroexpand form)` for full expansion and `(macroexpand-1 form)` for one
top-level expansion step. Both accept an optional options alist with expansion
budgets:

```scheme
(macroexpand
 '(let loop ((n 1)) (loop n))
 '((max-steps 1)))
```

Budget or syntax failures are returned as `(status error)` macro-expansion
records with debugger condition data in the `errors` field. The condition phase
is reported as `macro-expansion`.

## Related Introspection

`(macro-binding-info identifier)` reports active syntax binding metadata, or
`#f` when the identifier is not a macro binding.

`(macroexpand-library library-name)` reports syntax exports for an imported or
available library:

```scheme
(macroexpand-library '(scheme base))
```

`(syntax-source datum)` currently returns `#f`; it is reserved for future source
location metadata without changing the macro-expansion record shape.

`(macroexpand-yield form options)` returns the same expansion record as
`macroexpand` and also records a `macroexpand` event in the current evaluation
event stream, making expansion debugging visible through `(recent-yields)` and
native session event buffers.

## Emacs Buffer View

From a native REPL session, `M-x agent-scheme-repl-macroexpand-source` reads the
selected region or a prompted form, expands it in the current session, and opens
an `*Agent Macroexpand: SESSION*` buffer. The buffer shows the original form,
expanded form, individual expansion steps, and the complete record for direct
comparison.
