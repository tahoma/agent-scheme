# Fixed-Policy Identity Tables

`(consent identity-table)` is private bootstrap-safe storage for mutable
associations keyed by object identity. It gives graph algorithms, runtime
registries, and collector work a callback-free table before optional standard
libraries are realized.

It is not a public hash-table API. A constructor fixes capacity bounds, growth
policy, key namespace, and ownership domain. Callers cannot provide equality,
hash, iteration, allocator, or cleanup procedures, and Scheme-visible equality
metadata is never attached to the table.

## Key policies and namespaces

Every table enables one immutable key policy:

- `owned` accepts stable Consent heap and object identifiers;
- `host` accepts borrowed host objects compared by host identity; or
- `mixed` enables both as disjoint namespaces.

An owned association is addressed by an exact nonnegative heap identifier and
heap-local object identifier. Its insertion also retains the owned object as
the explicit root represented by that entry. The two integers select the
association; the retained object is not exposed as hash or equality policy.

A host association retains the key required for identity comparison. Host and
owned keys cannot alias in a mixed table, even if a host hash happens to equal
the portable hash derived from owned identifiers. Consumers use distinct
tables or distinct symbolic domain labels when their lifetimes or authorities
differ.

The existing intrusive datum-object map remains the preferred call-scoped
path for owned heap objects. It uses a private object header, takes one header
probe, and restores an enclosing traversal on release. An identity table is
appropriate when keys are borrowed host objects, when stable numeric owned
identifiers are already available, or when a mixed registry must keep both
namespaces in one fixed-policy object.

## Representation and probing

Fast tables use portable open addressing with linear probing. Empty buckets
contain `#f`; deletion writes a private tombstone. Each live entry contains
only its namespace, fixed identity fields, retained key or object, value, and
precomputed hash. No callback is stored or invoked by lookup, insertion,
deletion, clear, snapshot, or release.

Owned hashes are computed from heap and object identifiers. Host hashing and
host identity comparison form the entire irreducible adapter boundary:

- the Emacs bootstrap uses `sxhash-eq` and `eq`;
- configured R7RS hosts use their audited identity hash and `eq?`; and
- a host without an identity hash uses the fixed compatibility envelope below.

The table reuses the first tombstone seen during a probe. Insertion may rebuild
the same capacity when tombstones would otherwise make the next occupied load
reach two thirds. If live entries require more room, `allow-growth` chooses the
smaller of the configured maximum and `2 * capacity + 1` while still ensuring
the requested entry fits below the two-thirds threshold. Rehash allocates and
populates replacement storage before publishing it.

`pre-reserved` rejects an insertion that would require a larger bucket vector.
`reserve!` remains available before entering a no-allocation phase. The maximum
capacity is an inclusive bucket-count ceiling; usable association count can be
lower because the load threshold always reserves empty probe space.

## No-hash compatibility envelope

When host identity hashing is unavailable, host entries use an identity alist
with an exact 64-entry ceiling. Each operation scans at most 64 associations.
The sixty-fifth distinct host insertion fails before mutation, so this path is
a fixed bounded compatibility mechanism rather than a silently quadratic
general table.

The optional internal constructor policy `compatibility` forces that path on a
hash-capable host. It exists for deterministic conformance testing and does not
widen the public runtime surface. Owned entries continue to use open addressing
because their stable identifiers always provide a portable hash.

## Operations and complexity

Host and owned namespaces have separate `contains?`, `ref`, `set!`, and
`delete!` operations. A stored `#f` value is distinct from absence: `ref`
returns its caller-supplied default only when the identity is absent, and
`contains?` reports membership independently of the value.

| Operation | Hash-backed bound | Compatibility bound |
| --- | --- | --- |
| `contains?`, `ref`, `set!`, `delete!` | Expected O(1) | At most 64 steps. |
| Growth or tombstone rebuild | O(capacity) | Not applicable. |
| `clear!`, `release!` | O(capacity) | At most 64 entries. |
| `entries` | O(capacity) | At most 64 entries. |
| `stats` | O(1) | O(1). |

Entry snapshot order is explicitly unspecified. Rehash, tombstone reuse, and a
future native acceleration may change it. Consumers that need stable order own
that order separately instead of deriving semantics from bucket placement.

Statistics record logical operations, misses, identity tests, hash calls, probe
steps, compatibility scan steps, tombstones, capacity changes, rehashed
entries, clear and release work, and snapshots. These deterministic counters
support additive O(N) gates without treating elapsed time as an API.

## Root and lifetime contract

Every live entry is an explicit strong root for its value and for the key or
owned object needed to represent identity. `delete!` removes those roots before
reporting success. `clear!` removes every root while retaining bucket capacity;
it is intended for reuse. `release!` removes every root, drops the bucket
vector, and terminally marks the table inactive. Repeated release is
idempotent.

After release, the predicate, active-state query, statistics, and idempotent
release remain valid. All other operations reject the inactive table. Code
that owns nonlocal control transfer pairs a call-scoped table with
`dynamic-wind`, so exceptions and continuation escapes release it. Re-entering
the continuation observes an inactive table and fails before using stale
roots.

This version deliberately excludes weak keys, ephemerons, finalizers, and
collector notification. Those semantics belong to #666 and require a distinct
collector-owned contract rather than a mode flag on a strong identity table.

## Compatibility facade and consumers

`(consent identity-map)` is now a portable compatibility facade over a
host-policy identity table. It preserves the existing constructor, lookup,
mutation, and fast-backend query while adding delete, clear, release, and
statistics. The facade contains no host table implementation; both evaluator
bootstraps load the same Scheme source above the three-operation adapter.
Its fixed fast-backend bucket ceiling is 16,777,215, admitting at most
11,184,809 associations under the strict load threshold. This covers the
runtime's ten-million-node default evaluation envelope without preallocating
that ceiling. The constructor accepts an optional symbolic ownership-domain
label so failures and lifecycle accounting identify the responsible runtime
scope.

Datum import and export, result projection, syntax ownership, runtime graph
comparison, and bootstrap-symbol equality preserve their topology and
allocation behavior while releasing call-scoped host tables alongside their
intrusive owned maps. Canonical heap-owned reading continues to use intrusive
object headers and does not touch host identity tables.

## Verification

`tests/scheme/consent-identity-table-test.scm` covers equal-but-distinct host
keys, cycles, shared values, mixed namespaces, stable owned identifiers,
stored false values, updates, deletion and tombstone reuse, bounded growth,
pre-reserved failure, clear and release, and deterministic accounting. A
forced compatibility case fills exactly 64 identities and proves the next
insertion fails without hashing or mutation. Counted 128- and 256-entry runs
guard additive expected O(N) work.

Exception and continuation fixtures verify release on every dynamic exit and
re-entry failure. The portable plan runs the same program on direct and
compiled hosts. ERT imports the internal library through the Emacs source
loader and asserts that its adapter overlay contains only host-backend
availability, identity hash, and identity comparison.
