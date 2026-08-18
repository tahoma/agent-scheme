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

The internal engine uses intrusive separate chaining for lookup and a doubly
linked entry chain for stable insertion order. Each entry carries its bucket
link directly, so insertion and growth do not allocate a separate bucket-list
pair. SRFI 125 deliberately continues to describe whole-table order as
unspecified. Keeping the order links now avoids a representation migration when
the SRFI 250 facade adds first, last, next, previous, and cursor operations.
Updating an existing association preserves its position; deleting and
reinserting it appends a new entry.

The source-owning `(stdlib hash-table ...)` hierarchy makes the shared family
visible without merging incompatible standards. No umbrella library exports a
union of every facade. The chunk does not add an `(rnrs hashtables (6))` alias
or another `(scheme ...)` spelling; those names require their own explicit
library-surface decision.

The engine records two revisions. Its structural revision changes when entries
are inserted or removed, which is the invalidation boundary needed by future
cursors. Its mutation revision also changes when an existing value is replaced,
which lets SRFI 125 reject callbacks that mutate a table being traversed. A
removed entry clears its owner reference; that owner also serves as the stale
entry marker instead of retaining a separate liveness field.

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
sequence. The complete upstream test program is vendored verbatim under
`fixtures/srfi-125/` and retains its MIT license. Its executable adaptation
retains all 88 upstream test forms. The executable adaptation replaces
unavailable import helpers, spells three bytevector-containing data forms with
R7RS constructors for the configured Racket reader, and replaces the test-runner
epilogue. The local portable implementation remains Apache-2.0.

## SRFI 125 Test Coverage

Coverage is split deliberately between upstream compatibility and independent
conformance tests. The upstream program exercises 44 of the 46 exported
identifiers; it does not call `hash-table-values` or `hash-table-entries`. The
local suite covers both, so every public export is exercised by at least one
portable test.

| Contract | Upstream | Independent | Combined |
| --- | ---: | ---: | ---: |
| Public exported identifiers | 44/46 | 46/46 | 46/46 |
| Traversal callbacks forbidden to mutate their table | 0/8 | 8/8 | 8/8 |
| Public mutators rejected by immutable tables | 0/14 | 14/14 | 14/14 |
| Upstream test forms retained by the executable port | 88/88 | n/a | 88/88 |

The independent suite also covers adversarial collisions and growth, fresh
entry result lists, comparator type rejection, unsupported weak-table options,
empty-pop and arity errors, cross-policy set behavior, capacity/load bounds,
stale-entry liveness, destructive self-set operations, and the shared engine's
insertion links and revision boundaries. Emacs-hosted tests separately cover
resolver aliases, missing-export diagnostics, and manifest provenance.

Weak or ephemeral storage, thread safety, and hash-distribution performance are
not claimed as conformance coverage. The portable provider rejects those
optional storage requests, and timing or statistical hash-quality tests would
not establish SRFI semantics. Public traversal order also remains unspecified;
stable order is tested only as an internal engine contract for the future SRFI
250 facade.

Expected lookup, insertion, update, and deletion cost is amortized constant time
when the supplied hash function distributes keys satisfactorily. Whole-table
operations traverse the insertion chain directly. Procedures returning lists
allocate their required result lists; callback-only traversals do not first
allocate an entry snapshot or per-callback argument lists.

The provider grows before its occupied load exceeds three quarters. An explicit
capacity request reserves the smallest power-of-two bucket vector that admits
that many associations at the same load, rather than reserving two buckets per
requested association. Growth allocates only the replacement bucket vector and
relinks the existing entries.

Arbitrary user hash procedures can deliberately return the same value for every
key, so no generic provider can promise constant time for that case without
changing its equality contract. Such a table degrades to linear lookup and
quadratic bulk construction. The local stress suite retains a constant-hash
comparator to cover correctness through that path; hash-flood resistance is not
claimed for attacker-selected user hash procedures.

`tools/benchmark-hash-table.scm` reports raw same-host jiffy samples for growing
and pre-sized insertion, successful and missing lookup, callback traversal, and
constant-hash scaling. Run it through `tools/run-portable-tests.sh` with
`CONSENT_PORTABLE_PROGRAM` set to that file. Compare three-run medians from the
same machine and host; the benchmark is intentionally not a correctness gate.
