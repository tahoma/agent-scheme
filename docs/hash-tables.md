# Standard Hash-Table Family

Consent Scheme treats the standard mutable hash-table APIs as one family with
several public facades. The family shares portable storage where its semantics
agree, but it does not force incompatible standards into one public procedure
set.

## Ownership

| Layer | Responsibility |
| --- | --- |
| `(stdlib hash-table implementation)` | Portable buckets, key policy, mutability, insertion links, copies, and mutation revisions; internal only. |
| `(stdlib hash-table)` | SRFI 125 behavior and the `(scheme hash-table)`, `(srfi 125)`, and `(srfi srfi-125)` imports. |
| `(stdlib hash-table basic)` | Planned SRFI 69 compatibility facade for `(srfi 69)`, `(srfi srfi-69)`, `(srfi :69)`, and `(srfi :69 basic-hash-tables)`. |
| `(stdlib hash-table r6rs)` | Planned SRFI 126 facade for `(srfi 126)` and `(srfi srfi-126)`, with R6RS-style constructors, vectors, capacity, and introspection. |
| `(stdlib hash-table insertion-ordered)` | Planned SRFI 250 facade for `(srfi 250)` and `(srfi srfi-250)`, with cursors and order-sensitive traversal. |

The internal engine uses separate chaining for lookup and a doubly linked entry
chain for stable insertion order. SRFI 125 deliberately continues to describe
whole-table order as unspecified. Keeping the links now avoids a representation
migration when the SRFI 250 facade adds first, last, next, previous, and cursor
operations. Updating an existing association preserves its position; deleting
and reinserting it appends a new entry.

The source-owning `(stdlib hash-table ...)` hierarchy makes the shared family
visible without merging incompatible standards. No umbrella library exports a
union of every facade. The chunk does not add an `(rnrs hashtables (6))` alias
or another `(scheme ...)` spelling; those names require their own explicit
library-surface decision.

The engine records two revisions. Its structural revision changes when entries
are inserted or removed, which is the invalidation boundary needed by future
cursors. Its mutation revision also changes when an existing value is replaced,
which lets SRFI 125 reject callbacks that mutate a table being traversed.

## Primitive Runtime Boundary

The standard family does not reuse the representation of `(consent
identity-table)` or import `(consent identity-table primitive)`. Those private
runtime libraries have a deliberately different contract: fixed identity
policies, no user callbacks, explicit lifetime and release, bounded fallback
behavior when host identity hashing is unavailable, runtime accounting, and
separate owned and host namespaces. Their primitive overlay exposes only the
irreducible host identity operations.

The two layers share Consent Scheme's owned `eq?`, `eqv?`, and `equal?`
semantics. Standard hash tables package those semantics through SRFI 128
comparators and portable hash procedures. Comparator type tests, equivalence,
and hash callbacks remain above the primitive boundary. A future native
provider may accelerate the stdlib engine only if it preserves the same public
policy, order, mutability, and revision contracts; it must not expose bridge
identity or private table lifetime through a standard import.

This separation also prevents a dependency cycle. A direct R7RS host may use
SRFI 69 to supply private host identity hashing, while Consent's SRFI 69 surface
is itself a later facade over the standard hash-table engine.

## SRFI 125 Surface

`(stdlib hash-table)` is the source-owning library. `(scheme hash-table)` is the
canonical R7RS-large spelling and `(srfi 125)` is the secondary SRFI spelling.
The library supports comparator-based construction, the deprecated SRFI 69
constructor form, immutable literals and copies, mutation, traversal, copying,
conversion, and destructive set operations.

The implementation follows the official SRFI 125 specification directly. The
official sample source is recorded but not vendored because it is implemented
on top of SRFI 126, which is scheduled after SRFI 125 in Consent's facade
sequence. Adapted upstream tests retain their MIT license; the local portable
implementation remains Apache-2.0.

Expected lookup, insertion, update, and deletion cost is amortized constant time
when the supplied hash function distributes keys satisfactorily. Whole-table
operations allocate or traverse in proportion to the number of associations.
