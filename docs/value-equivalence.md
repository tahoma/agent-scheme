# Consent Value Equivalence

**Issue:** #348

**Roadmap version:** 0.18.48

**Status:** Implemented

## Summary

Consent Scheme defines `eq?`, `eqv?`, and `equal?` over Consent-owned values.
The portable interpreter does not delegate Scheme-visible identity or
structural comparison to the R7RS implementation that hosts it. This keeps the
result stable across Gambit, Guile, Gauche, Racket, and a future native
runtime, even when those hosts make different permitted R7RS choices.

Host identity remains valid only for private bootstrap metadata and values at
an explicit host adapter boundary. Such values must be converted to a
Consent-owned representation before Scheme code can observe them.

## Identity Categories

The central portable dispatcher applies these rules:

| Value category | `eq?` and `eqv?` rule | `equal?` rule |
| --- | --- | --- |
| Boolean and empty list | Same singleton value | Same as `eqv?` |
| Symbol | Same immutable name | Same as `eqv?` |
| Character | Same Unicode scalar value | Same as `eqv?` |
| Number | Same canonical numeric representation | Same as `eqv?` |
| Pair and vector | Same owned heap and object ordinal | Graph-structural comparison |
| String and bytevector | Same owned heap and object ordinal | Indexed-content comparison |
| Record and record type | Same explicit location tag | Same as `eqv?` |
| Procedure, parameter, continuation | Same explicit location tag | Same as `eqv?` |
| Port and error object | Same explicit location tag | Same as `eqv?` |
| Environment specifier | Same explicit location tag | Same as `eqv?` |
| EOF and unspecified value | Same runtime singleton category | Same as `eqv?` |

The datum heap supplies compound identity as `(heap-id, object-id)`. Runtime
records that do not live in that heap receive monotonically allocated,
process-local location tags. Tags are compared only inside their value kind or
inside a shared tag domain, so an unrelated runtime record cannot alias a
record, record type, or compound datum accidentally.

`equal?` traverses only Consent-owned pairs and vectors, and treats owned
strings and bytevectors as indexed leaves. Its congruence algorithm terminates
for cyclic graphs and preserves sharing-sensitive work bounds without asking
the borrowed host to identify a Scheme-visible node. Records and opaque
runtime values remain identity leaves; record field contents do not make two
fresh records equal.

## Fixed R7RS Choices

R7RS-small deliberately leaves some `eq?` and `eqv?` results
implementation-dependent. Consent fixes them as follows:

- `eq?` and `eqv?` use the same rule for every supported value category.
- Numbers are equivalent only when kind, exactness, and canonical stored value
  agree. Exact and inexact numbers with the same mathematical value are not
  equivalent.
- Both signs of inexact zero normalize to positive zero and are equivalent.
- All input NaNs normalize to one quiet NaN representation and are equivalent
  under `eq?` and `eqv?`.
- Characters with the same Unicode scalar value are equivalent.
- Fresh pairs, strings, vectors, and bytevectors are not identical even when
  their contents are equal. Empty compounds are not special-cased.
- Symbols with the same immutable name are equivalent, including symbols
  interned through isolated symbol-table roots.

These are language semantics, not observations about the current bootstrap
records or the host's allocation and interning behavior.

## Membership and Association

The list procedures use the named equivalence predicate consistently:

- `memq` and `assq` use `eq?`;
- `memv` and `assv` use `eqv?`; and
- `member` and `assoc` use `equal?`.

They therefore inherit Consent-owned identity, numeric representation, and
cyclic structural semantics rather than calling host membership or association
procedures on visible values.

## Fork and Checkpoint Compatibility

Read-only values shared from a frozen runtime image retain their identity in
every context that observes the image. A future checkpoint fork may likewise
retain identity while a value is inherited without materialization.

Issue #721's copy-on-write work must assign a fresh branch-owned identity when
it materializes a writable descendant. Aborting the branch discards that
identity. Committing selects the surviving object and its identity; it must not
make two independently materialized descendants identical. `equal?` remains a
structural relation across branches and may report true for distinct
identities.

Issue #716 owns the fuller branch-isolation fixture matrix. Until those branch
operations exist, the shared conformance corpus covers the stable prerequisites:
same-object identity, fresh-object distinction, graph equality, opaque runtime
location tags, and membership and association behavior.

## Bootstrap Boundary

The portable reader, macro expander, library loader, and native-call bridge may
use host pairs, vectors, symbols, procedures, or identity tables as private
implementation data. Those paths are explicitly named and bounded. The
interpreter's Scheme-visible equivalence dispatcher has no host `eq?`, `eqv?`,
or `equal?` fallback, and structural comparison does not keep a host-node map.

The Emacs bootstrap continues to own its representation through the parallel
runtime kernel. Shared conformance fixtures exercise both bootstraps; the
portable implementation additionally has an architectural guard against
reintroducing borrowed-host fallbacks.
