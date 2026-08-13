# Flexvectors (SRFI 214)

Consent Scheme provides mutable, extensible vectors through the optional
`(stdlib flexvectors)` library and its SRFI 214 compatibility aliases.
Flexvectors support indexed access, efficient back insertion, sequence
conversion, mutation, traversal, searching, and generator interoperation.
They are optional standard-library functionality, not part of the R7RS-small
conformance surface.

## Imports and Reference

The canonical project import is:

```scheme
(import (scheme base)
        (stdlib flexvectors))
```

Programs written for SRFI implementations may instead use any of these aliases:

```scheme
(import (srfi 214))
(import (srfi srfi-214))
(import (srfi :214))
(import (srfi :214 flexvectors))
```

Every spelling resolves to the same source library and 66-binding surface. The
vendored
[SRFI 214 specification](../scheme/stdlib/reference/srfi-214/srfi-214.md) is
the API authority. This guide emphasizes Consent Scheme integration and the
contracts most likely to matter in application code.

## Quick Start

```scheme
(import (scheme base)
        (stdlib flexvectors))

(define pending (flexvector 'parse 'plan))

(flexvector-add-back! pending 'execute)
;; => the same flexvector

(flexvector-remove-front! pending)
;; => parse

(flexvector->list pending)
;; => (plan execute)
```

Use `make-flexvector` for a requested length and optional fill value,
`flexvector` for literal-like construction, and the `list`, `vector`, `string`,
or generator conversion procedures at representation boundaries.

## Choosing Operations

- For indexed access, use `flexvector-length`, `flexvector-ref`, and
  `flexvector-set!`.
- For queue-like ends, use `flexvector-add-back!` and
  `flexvector-remove-front!`.
- For general editing, use `flexvector-add!`, `flexvector-remove-range!`, and
  `flexvector-copy!`.
- For a detached result, use `flexvector-copy`, `flexvector-append`, or
  `flexvector-map`.
- For in-place traversal, use `flexvector-map!`, `flexvector-filter!`, or
  `flexvector-reverse!`.
- For search or reduction, use `flexvector-index`, `flexvector-any`, or
  `flexvector-fold`.
- For representation changes, use `flexvector->list`, `vector->flexvector`, or
  `flexvector->generator`.

Procedures with a trailing `!` mutate a flexvector. Most insertion, range,
copying, filling, reversal, filtering, and mapping mutators return the mutated
destination so calls can be sequenced. The important exceptions are:

- `flexvector-remove!`, `flexvector-remove-front!`, and
  `flexvector-remove-back!` return the removed element;
- `flexvector-set!` returns the replaced element, or an unspecified value when
  its index equals the current length and the call appends; and
- `flexvector-for-each` and `flexvector-for-each/index` return an unspecified
  value.

`flexvector-clear!` returns the same, now-empty flexvector. It does not
invalidate the object.

## Indexes, Slices, and Parallel Traversal

Element indexes are zero-based exact integers. `flexvector-ref` accepts indexes
strictly below the current length. `flexvector-set!` additionally accepts the
current length and appends in that case.

Where an operation accepts optional `start` and `end` slice bounds, omitted
bounds default to the start and current source length. Supplied bounds are
clamped to the source range; an end below the start is still an error. Copying
into a destination may extend it, and overlapping self-copy behaves as though
the source slice were first saved separately.

Operations that accept multiple flexvectors, including folds, maps, counts, and
forward searches, stop at the shortest input. `flexvector-index-right` and
`flexvector-skip-right` instead require equal-length inputs. Folds preserve
their state values; `flexvector-any` and `flexvector-every` preserve predicate
result values. These procedures use their specified traversal order. Mapping
callback order is unspecified; an in-place mapping callback must not inspect or
mutate its destination flexvector.

## Storage and Memory Policy

The public SRFI surface intentionally exposes length but not capacity, reserve,
reset, release, maximum-capacity, or growth-policy controls. Programs must not
infer spare capacity or depend on the current growth ratio.

Consent's implementation currently selects the reference sample's growth
factor of 3/2. `flexvector-clear!` abandons high-water storage and returns to a
four-slot baseline so removed elements and oversized backing vectors can become
unreachable. Those facts explain current allocation behavior; they are not new
SRFI guarantees and may be retuned without changing program semantics.

Runtime code that needs explicit capacity budgets, reusable reset, terminal
release, or collector-phase ownership should use the private abstractions
described in [Bootstrap-Safe Runtime Storage](runtime-storage.md). Application
and optional-library code should stay on the public flexvector interface.

## Runtime Documentation and Tests

Every public procedure carries a simple docstring plus structured parameter,
return, and effect metadata. With `(agent reflect)` imported, inspect a binding
through `documentation` or retrieve its short prose through `docstring`:

```scheme
(documentation 'flexvector-add-back!)
(docstring 'flexvector-add-back!)
```

The adapted upstream corpus lives in
`tests/scheme/stdlib-flexvectors-upstream-test.scm`. Project tests in
`tests/scheme/stdlib-flexvectors-test.scm` cover the exports and boundary
contracts absent from that corpus. Both programs run on the direct and compiled
portable-host routes.
