# Docstring Metadata Convention

Agent Scheme source can carry documentation metadata as ordinary R7RS data in
procedure bodies. The convention supports simple string docstrings and richer
property records without adding reader syntax or changing standard Scheme
evaluation.

Comments remain source-only contributor notes. A standard R7RS reader does not
return comments as datums, so comments are not visible to runtime reflection,
reference generation, logs, yields, or compiled metadata unless a separate
source tool reads the original text.

## R7RS Compatibility

The convention uses literal body expressions that R7RS-small already accepts.
A literal expression in a non-final body position is evaluated and discarded by
ordinary Scheme semantics. Agent Scheme treats selected non-final literals as
metadata while preserving the same runtime result.

Documentation metadata is recognized only in the leading non-tail metadata
position of a body:

1. Internal definitions come first, as R7RS requires.
2. Zero or more leading metadata literals may follow those definitions.
3. At least one non-metadata body expression must remain after the metadata.
4. The first non-metadata expression ends metadata recognition for that body.

A string or rich property record in final position is an ordinary return value,
not metadata. This rule avoids changing the meaning of procedures such as
`(lambda () "value")`.

```scheme
(define (fact n)
  "Return the factorial of exact non-negative integer N."
  (if (= n 0)
      1
      (* n (fact (- n 1)))))
```

Internal definitions still precede documentation metadata:

```scheme
(define (twice x)
  (define factor 2)
  "Return X multiplied by the local factor."
  (* x factor))
```

Metadata after executable body expressions is ignored as metadata and remains
ordinary Scheme code:

```scheme
(define (not-a-docstring x)
  (display x)
  "This string is an ordinary expression, not metadata."
  x)
```

## Simple String Form

A simple string in metadata position is shorthand for the `documentation` field.
Adjacent simple strings in metadata position form one documentation string, with
one newline inserted at each string boundary. The reader annotates the shortcut
into the same rich field record shape that an explicit
`#((documentation . "..."))` property record would produce.

```scheme
(define (sum xs)
  "Return the arithmetic sum of XS."
  "XS must be a list of numbers."
  (let loop ((rest xs) (total 0))
    (if (null? rest)
        total
        (loop (cdr rest) (+ total (car rest))))))
```

The documentation field for `sum` is:

```scheme
"Return the arithmetic sum of XS.\nXS must be a list of numbers."
```

The live reflection surface exposes the same simple string through
`(documentation subject)` in `(agent reflect)`. `subject` can be a binding
symbol, binding name string, or procedure value:

```scheme
(import (scheme base) (agent reflect))

(define (sum xs)
  "Return the arithmetic sum of XS."
  (let loop ((rest xs) (total 0))
    (if (null? rest)
        total
        (loop (cdr rest) (+ total (car rest))))))

(documentation 'sum)
;; =>
(documentation-metadata
  (subject (binding sum))
  (kind procedure)
  (library #f)
  (source #f)
  (origin (body-literal string))
  (fields
    ((arguments (xs))
     (documentation "Return the arithmetic sum of XS."))))
```

Procedures with no body-literal documentation still expose their signature
metadata:

```scheme
(define (identity x)
  x)

(documentation 'identity)
;; =>
(documentation-metadata
  (subject (binding identity))
  (kind procedure)
  (library #f)
  (source #f)
  (origin (signature))
  (fields ((arguments (x)))))
```

## Rich Property Records

Rich documentation metadata uses a literal vector of pairs in the same leading
non-tail metadata position. This follows Guile's procedure-property style as an
influence, but the fields and reflection shape below are Agent Scheme public
behavior.

```scheme
(define (open-agent-log path)
  #((documentation . "Open PATH as an Agent Scheme log input port.")
    (parameters . ((path . "Path to a readable log file.")))
    (returns . "An input port.")
    (effects . (file-read)))
  (open-input-file path))
```

The simple string form and rich property form may appear together:

```scheme
(define (normalize-name name)
  "Return NAME in canonical Agent Scheme identifier form."
  #((parameters . ((name . "A string or symbol.")))
    (returns . "A symbol."))
  (if (symbol? name)
      name
      (string->symbol name)))
```

When reflected through `(documentation subject)`, the string contributes the
`documentation` field and rich properties preserve their Scheme-readable values:

```scheme
(documentation 'normalize-name)
;; =>
(documentation-metadata
  (subject (binding normalize-name))
  (kind procedure)
  (library #f)
  (source #f)
  (origin (body-literal string vector))
  (fields
    ((arguments (name))
     (documentation "Return NAME in canonical Agent Scheme identifier form.")
     (parameters ((name . "A string or symbol.")))
     (returns "A symbol."))))
```

## Applies To

The body convention applies independently to every procedure body:

- procedure shorthand `define`, such as `(define (name args ...) body ...)`
- `lambda` expressions
- each `case-lambda` clause body
- top-level or internal bindings whose initializer is a `lambda` or
  `case-lambda` expression

For a binding such as `(define name (lambda (...) ...))`, metadata belongs to
the procedure value and may also be associated with the binding name by the
frontend or reference generator. If the same procedure value is stored in
multiple bindings, binding-specific documentation remains a separate metadata
subject from procedure-value documentation.

Primitive bindings are not read as ordinary procedure bodies. Kernel
primitives, standard host-effecting bindings, Agent primitive libraries, and
host capability primitives therefore use the primitive manifest as their
runtime documentation source. When a manifest record carries explicit
`documentation` metadata, reflection uses that metadata first. When the
manifest lacks explicit documentation, the bootstrap may derive a documentation
field from the registered implementation procedure's own docstring. Reflected
fallback metadata reports `(origin (implementation-procedure string))` instead
of `(origin (body-literal string))` so tools can distinguish source body
docstrings from host or bootstrap implementation docs.

This convention does not make simple string docstrings for these surfaces:

- `define-syntax` and macro exports
- `define-record-type` and record fields
- `define-library` forms
- re-exported or renamed bindings

Those surfaces need explicit binding, syntax, record, library, or export
metadata records so static reference tools can describe the exported API
without pretending a transformer procedure body documents the macro it creates.
Later metadata work may add such subject-specific records while still using
ordinary R7RS datums.

## Metadata Records

Runtime reflection, static reference generation, logs, yields, and compiled
runtimes should expose one Scheme-readable record shape:

```scheme
(documentation-metadata
  (subject (binding fact))
  (kind procedure)
  (library (example math))
  (source (file "example/math.sld") (line 12) (column 3))
  (origin (body-literal string))
  (fields
    ((arguments (n))
     (documentation "Return the factorial of exact non-negative integer N.")
     (parameters ((n "Exact non-negative integer.")))
     (returns "Exact integer.")
     (effects (pure)))))
```

Manifest-backed primitive documentation uses the same record shape:

```scheme
(documentation '+)
;; =>
(documentation-metadata
  (subject (binding +))
  (kind procedure)
  (library (scheme base))
  (source kernel)
  (origin (implementation-procedure string))
  (fields
    ((documentation "Primitive + over ARGUMENTS."))))
```

Field values are ordinary Scheme-readable data. The initial field set is:

- `arguments`: the procedure formals as Scheme-readable data using the
  procedure's symbolic bindings; proper, dotted, variadic, and empty formals
  reflect as `(x y)`, `(x . rest)`, `rest`, and `()`
- `documentation`: string documentation for humans and agents
- `summary`: short string suitable for indexes
- `parameters`: association list from parameter symbol to string
- `returns`: string or Scheme-readable result shape
- `effects`: list of effect symbols, such as `(pure)` or `(file-read)`
- `examples`: list of source/result example records
- `see-also`: list of related binding, library, issue, or document references
- `since`: version datum such as `(agent-scheme-version 0 14 10)`
- `deprecated`: `#f` or a string explaining the replacement
- `stability`: symbol such as `experimental`, `stable`, or `internal`

Implementations may preserve unknown fields as Scheme-readable data for tools
that understand them, but public documentation should prefer the field names
above until a later issue extends the convention.

## Merge and Malformed Rules

The metadata prefix is processed in source order.

- The generated `arguments` field is derived from the procedure formals before
  body-literal metadata is merged.
- Adjacent simple strings are joined with newline separators.
- A simple string is equivalent to a `documentation` field.
- Multiple `documentation` string values from simple strings and rich records
  are joined in source order with newline separators.
- `examples` and `see-also` values append in source order when each value is a
  list.
- `parameters` values merge by parameter name; duplicate parameter names are
  malformed.
- Every `parameters` key must be present in the generated `arguments` datum;
  documenting an unbound parameter name is malformed.
- Other duplicate scalar fields are malformed instead of silently replacing an
  earlier value.

A malformed rich metadata literal does not change evaluation semantics.
Metadata-aware passes keep executing the program according to ordinary R7RS
rules, attach no partial fields from the malformed literal, and report a
`malformed-documentation-metadata` diagnostic with source information when that
information is available. Valid earlier metadata for the same subject remains
valid.

Source locations are best-effort metadata. When source information is available,
records should identify both the documented subject and the metadata literal
span by file, line, and column. When source information is unavailable, use
`#f` or omit the source field rather than inventing a location.

## Implementation Status

Simple string docstrings and rich property records are implemented for the
Emacs Lisp bootstrap and the portable R7RS path. A leading non-final metadata
prefix after internal definitions attaches a normalized field record to
compound procedures and can be queried through `(documentation subject)` from
`(agent reflect)`. Compound procedures also receive generated `arguments`
metadata from their lambda formals, so simple docstrings and rich property
records share one field record with the signature metadata. Procedure shorthand
`define`, explicit `lambda`, top-level bindings whose initializer is a
`lambda`, and internal bindings with lambda initializers share the same
body-literal extraction rule.

Primitive bindings can also be queried through the same reflection procedure.
Explicit manifest documentation wins when present; otherwise the bootstrap
falls back to registered implementation procedure docstrings where the host can
provide them. The portable R7RS path records equivalent implementation
documentation for representative primitive hooks because standard R7RS does not
provide a procedure-docstring reflection API for implementation procedures.

The current `(scheme case-lambda)` library is a portable macro that lowers each
clause through an internal `lambda`, so ordinary evaluation still preserves the
body string semantics, but the runtime does not yet expose durable
clause-level documentation metadata for a `case-lambda` procedure value. That
representation work is left to a later reflection/metadata slice.

- #300 defines the public convention.
- #301 implements simple string docstrings for the initial runtime and
  reflection slice.
- #302 adopts simple docstrings in checked-in libraries after extraction works.
- #303 implements rich documentation property records.
- #344 adds manifest-backed primitive documentation with implementation
  procedure fallback.
- #304 preserves documentation metadata across compiled and reference runtimes.
- #338 supplies syntax datum source metadata that can improve doc metadata
  source locations.
