# Macro Expansion Introspection

Consent Scheme exposes macro expansion as Scheme-readable data through
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
            (output (if #f #f (begin 42)))
            (source (source
                      (origin source)
                      (source-id #f)
                      (line 10)
                      (column 17)
                      (offset 159)
                      (span 24)
                      (phase read))))))
  (macros (my-unless))
  (source (source
            (origin source)
            (source-id #f)
            (line 10)
            (column 17)
            (offset 159)
            (span 24)
            (phase read)))
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

`(syntax-source datum)` returns source metadata when the datum came from an
Consent Scheme reader call with source metadata enabled, and `#f` when no source
is attached. Ordinary read/eval and macro expansion source paths enable source
metadata by default so diagnostic records can point back to the syntax that
produced them. Source metadata is ordinary Scheme-readable data and does not
affect datum equality:

```scheme
(syntax-source '(twice 21))
;; => (source
;;      (origin source)
;;      (source-id #f)
;;      (line 1)
;;      (column 16)
;;      (offset 15)
;;      (span 10)
;;      (phase read))
```

The current source record fields are `origin`, `source-id`, `line`, `column`,
`offset`, `span`, and `phase`. Line and column numbers are one-based, offsets
and spans count characters in the reader's source snapshot, and `source-id` is
`#f` unless the caller provides a host-neutral source identifier such as a
buffer or session name. Host callers can disable source metadata for a specific
read/eval path with the `source-metadata` option, such as `:source-metadata nil`
in the Emacs Lisp host or `(source-metadata . #f)` in the portable Scheme
option alist.

`(macroexpand-yield form options)` returns the same expansion record as
`macroexpand` and also records a `macroexpand` event in the current evaluation
event stream, making expansion debugging visible through `(recent-yields)` and
native session event buffers.

## Emacs Buffer View

From a native REPL session, `M-x consent-repl-macroexpand-source` reads the
selected region or a prompted form, expands it in the current session, and opens
an `*Consent Macroexpand: SESSION*` buffer. The buffer shows the original form,
expanded form, individual expansion steps, and the complete record for direct
comparison.
