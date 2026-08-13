# Scheme Style Guidelines

Consent Scheme sources should read as portable R7RS Scheme first, with project
API documentation layered on top. These guidelines apply to checked-in `.sld`
and `.scm` files under `scheme/`, `tests/scheme/`, and `fixtures/r7rs/`.

Prefer the local style around the code being changed, and avoid formatting-only
churn outside the definitions needed for the current work.

## Width and embedded source

Use 80 columns as the soft limit and 100 as the hard limit. Break forms at
syntactic boundaries and keep identifiers intact. An atomic value between the
limits needs the classified local annotation documented in
[Narrow-Width Readability](readability.md); no source line may exceed the hard
limit.

Represent embedded Scheme as Scheme data when its lexical spelling is not
under test. Use a `form` for one datum, `forms` for a program fragment, and a
named `.scm` file for a substantial program. Keep `text` for reader-sensitive
input whose exact characters are the subject of the test. Materialize
structured data with the Consent writer only at the execution boundary.

When a string must wrap without changing its value, use an R7RS string
continuation at a word boundary:

```scheme
(define message
  "The logical value continues without gaining a newline or extra \
    indentation.")
```

## Definition Shape

Use procedure definition syntax for procedures:

```scheme
(define (list->bytevector bytes)
  ...)
```

Do not introduce value-lambda procedure definitions:

```scheme
(define list->bytevector (lambda (bytes)
  ...))
```

When a procedure value initializer is unavoidable, put the `lambda` or
`case-lambda` form on the following line. This shape is syntax-supported, but
ordinary procedures should still use procedure definition syntax whenever the
source can do so clearly:

```scheme
(define list->bytevector
  (lambda (bytes)
    ...))
```

Only simple value definitions should keep the value expression after the binding
name on the same line:

```scheme
(define consent-eof-object (make-consent-eof-object))
(define consent-eval-string consent-eval-source)
(define newline-string "\n")
```

Move compound initializers to the following line when they contain control flow,
procedure literals, multi-line calls, large literals, or anything whose shape is
not obvious at a glance:

```scheme
(define bytevector-comparators
  (list unsigned-byte-comparator
        signed-byte-comparator))
```

## Variadic Procedures

For public variadic APIs that dispatch by arity, prefer a named rest-parameter
procedure with a `case-lambda` dispatcher in the body. This keeps runtime
documentation attached to the exported binding and keeps `case-lambda` on its
own line:

```scheme
(define (read-record . maybe-port)
  "Read one record from MAYBE-PORT or the current input port."
  #((parameters
     (maybe-port (type list)
      (description "Zero or one input port.")))
    (returns (type record)
     (description "The parsed record."))
    (effects port-read))
  (apply
   (case-lambda
    (() (read-record (current-input-port)))
    ((port) ...))
   maybe-port))
```

Use a semantic rest-parameter name, such as `maybe-port`, `generators`, or
`args`, when that makes the public contract clearer than a generic `rest`.

## Docstrings and Metadata

Runtime-visible procedure documentation uses the body literal convention in
[Docstring Metadata Convention](docstring-metadata.md). A procedure docstring
belongs in metadata position, after any R7RS internal definitions and before the
first executable body expression.

Every exported runtime procedure in `scheme/` should have a simple string
docstring followed by the rich metadata vector:

```scheme
(define (gmap proc . generators)
  "Yield PROC applied to values from GENERATORS."
  #((parameters
     (proc (type procedure)
      (description "Procedure applied to generated values."))
     (generators (type list)
      (description "Generators supplying input values.")))
    (returns (type procedure)
     (description "A generator thunk."))
    (effects allocation state-write))
  ...)
```

Document every formal parameter by its binding name, including rest parameters
and dotted formals. For dispatcher procedures, the metadata must describe the
outer public signature, not only the names used in individual `case-lambda`
clauses. Every expanded public parameter and return descriptor must carry both
an explicit type and a non-empty description; a type annotation alone does not
document the API contract.

For expanded metadata descriptors, keep `(type ...)` on the same line as the
parameter or `returns` head when the line fits within the soft line limit. Put
longer type forms on their own line. Prefer a plain description string when it
fits, and use a string list only when the prose itself needs wrapping.

Do not keep a leading `;;` summary comment that merely repeats a procedure
docstring. Use source comments for invariants, policy decisions, pass
boundaries, portability notes, and surfaces that cannot carry procedure
docstrings, such as records, macros, and plain data definitions.

## Guardrails

Documentation coverage checks should be insensitive to formatting and
whitespace. They should answer whether the source carries the required
documentation, not whether it is line-wrapped in one particular way.

Style guardrails may separately enforce project layout choices, such as keeping
`lambda` and `case-lambda` off the same line as a `define` name or preferring
procedure definition syntax over value-lambda definitions.
