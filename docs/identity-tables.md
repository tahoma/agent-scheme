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

All hash-table policy and storage remain portable. Host-only fast tables use
separate chaining, with one compact vector node per association. Each node
holds its next link, complete host hash, key, and value. This keeps the common
identity-map path out of the evaluator-heavy offset arithmetic and general
entry accessors required by open addressing.

Owned and mixed-policy tables use portable open addressing with linear
probing. Empty buckets contain `#f`; deletion writes a private tombstone. Each
open entry contains only its namespace, fixed identity fields, retained key or
object, value, and precomputed hash. No callback is stored or invoked by
lookup, insertion, deletion, clear, snapshot, or release in either
representation.

Owned hashes are computed from heap and object identifiers. Host hashing and
raw host identity comparison form the irreducible adapter boundary. The
adapter reports whether hashing is available and, when it is, supplies a hash
for borrowed host identities. The Emacs bootstrap uses `sxhash-eq`; direct
R7RS hosts select Gambit's `eq?-hash`, Gauche's `eq-hash`, or SRFI 69
`hash-by-identity` in that order. A host without any of those operations uses
the fixed compatibility envelope below.

Portable `eq?` compares compound host keys such as pairs and vectors because
its result for those objects already reflects outer-host identity. Numbers,
characters, and symbols use the adapter's raw comparison instead: Consent gives
those atomic categories language-level `eq?` semantics that may differ from
outer-host identity. Pairing those semantics with a raw identity hash would
violate the table's hash/equality invariant on equal-but-distinct host objects.

This replaces the old opaque native table constructor, lookup, and mutation
operations. The host boundary therefore shrinks from implementing table policy
to three operations: reporting availability and supplying the two identity
facts portable Scheme cannot derive. Hash buckets, entries, growth, limits,
lifetime, and consumer policy remain portable Scheme.

The existing host-hash adapter normalizes every raw identity hash through a
fixed modular multiplicative mix. Some valid host identity hashes are stable
allocation serials. Using those serials directly would let a long-lived table's
insertion bursts overlap after unrelated short-lived maps advance the host
sequence by one capacity interval. The mix preserves same-object hash stability
while preventing that allocation pattern from turning linear probing
quadratic. Keeping normalization inside the existing hash operation also lets
evaluator hosts perform it before converting the result into an owned number;
it does not add another host-boundary operation.

Each entry retains that complete normalized hash. Probing compares complete
hashes first, so bucket collisions with different hashes stay entirely in
portable Scheme. When complete hashes agree, portable `eq?` compares compound
host keys directly. Raw adapter comparison remains necessary only for numbers,
characters, and symbols, whose Consent `eq?` semantics deliberately differ
from outer-host identity.

Open addressing reuses the first tombstone seen during a probe. It may rebuild
the same capacity when tombstones would otherwise make the next occupied load
reach two thirds. Host-only deletion unlinks its chain node and therefore does
not create tombstones. Chained tables grow only when the next association
would exceed one live entry per bucket; empty probe space is not required. If
live entries require more room, `allow-growth` chooses the smaller of the
configured maximum and `2 * capacity + 1` while satisfying the
representation's load threshold.

Open-table rebuilds populate replacement storage before publication.
Host-chain growth likewise allocates all replacement buckets first, then
relinks the existing nodes with fixed non-callback operations instead of
allocating a duplicate node set. The table publishes the replacement vector
after every node has moved. This bounds chain growth to one new bucket vector
rather than a vector plus one temporary node for every live association.

Growable tables defer their initial bucket allocation until the first insertion
or explicit reserve; the constructor's initial capacity remains the minimum
first allocation. `pre-reserved` tables allocate their initial buckets eagerly
and reject an insertion that would require a larger vector. `reserve!` remains
available before entering a no-allocation phase. Host-only compatibility tables
have no hash buckets, so reserve validates the requested bound without
allocating unused storage. The maximum capacity is an inclusive bucket-count
and association ceiling. Open tables admit fewer associations because their
load threshold reserves empty probe space; chained tables can use the full
ceiling.

## Host-hash availability

Availability is a property of the execution host, selected once when each map
or table is constructed. It is not an intermittent runtime condition.

| Execution path | Hash source | Automatic backend |
| --- | --- | --- |
| Emacs-hosted evaluator | Emacs `sxhash-eq` primitive overlay | Hashed |
| Direct or compiled Gambit | Gambit `eq?-hash` | Hashed |
| Direct Gauche | Gauche `eq-hash` | Hashed |
| Other configured R7RS hosts | SRFI 69 `hash-by-identity` | Hashed |
| Minimal R7RS without the operations above | None | Compatibility |
| Any host with forced `compatibility` policy | Deliberately bypassed | Compatibility |

The normal Emacs, direct-host, and compiled-host configurations therefore use
hash-backed maps. The compatibility backend is exercised when bringing Consent
up on a minimal R7RS implementation that lacks an identity hash, and when tests
force it to verify the portable correctness floor.

R7RS-small specifies identity comparison through `eq?`, but it does not expose
an object address, stable object identifier, or identity hash. Portable Scheme
therefore cannot derive an expected-O(1) bucket index for a borrowed host object
without first maintaining another identity index, which would merely move the
same problem. Consent relies on the host only for this irreducible fact. Owned
Consent objects do not need it: their heap and object identifiers provide
portable hashes, and call-scoped owned traversals normally use intrusive object
headers instead.

## No-hash compatibility envelope

When a constructed map selects compatibility mode, its host entries use one
identity alist with an exact 64-entry ceiling. Each operation scans at most 64
associations. Multiple simultaneously active maps have separate alists and
separate limits; there is no shared process-wide scan. The sixty-fifth distinct
host insertion into one map fails before mutation, so this path is a fixed
bounded compatibility mechanism rather than a silently quadratic general
table.

Consumers that cannot tolerate that bound do not silently fall back. Native
graph borrowing and general native-result import require the hashed backend and
fail closed without it. Source-library copying reparses the rare labelled
source form instead of exhausting the compatibility map. Other compatibility
consumers remain explicitly subject to the 64-identity limit.

The optional internal constructor policy `compatibility` forces that path on a
hash-capable host. It exists for deterministic conformance testing and does not
widen the public runtime surface. Owned entries continue to use open addressing
because their stable identifiers always provide a portable hash.

## Operations and complexity

Host and owned namespaces have separate `contains?`, `ref`, `set!`, and
`delete!` operations. Host identities additionally provide `adjoin!`, which
inserts only when absent and reports whether it inserted; graph traversals can
therefore combine cycle membership and marking in one probe. A stored `#f`
value is distinct from absence: `ref` returns its caller-supplied default only
when the identity is absent, and `contains?` reports membership independently
of the value.

| Operation | Hash-backed bound | Compatibility bound |
| --- | --- | --- |
| `contains?`, `ref`, `set!`, `adjoin!`, `delete!` | Expected O(1) | At most 64 steps. |
| Growth or open-table tombstone rebuild | O(capacity) | Not applicable. |
| `clear!` | O(capacity) | At most 64 entries. |
| `release!` | O(1) | O(1). |
| `entries` | O(capacity) | At most 64 entries. |
| `stats` | O(1) | O(1). |

Entry snapshot order is explicitly unspecified. Rehash, chain insertion, and
tombstone reuse may change it. Consumers that need stable order own that order
separately instead of deriving semantics from bucket placement.

Statistics record logical operations, misses, identity tests, hash calls,
inspected open buckets or chain nodes, compatibility scan steps, tombstones,
capacity changes, rehashed entries, clear and release accounting, and
snapshots. The
`release-clear-slots` field records the detached capacity whose roots were
removed; it does not imply a slot-by-slot release scan. These deterministic
counters support additive O(N) gates without treating elapsed time as an API.

## Root and lifetime contract

Every live entry is an explicit strong root for its value and for the key or
owned object needed to represent identity. `delete!` removes those roots before
reporting success. `clear!` removes every root while retaining bucket capacity,
so it overwrites the retained slots and is intended for reuse. `release!`
replaces the table's sole reference to its encapsulated bucket vector, drops
the compatibility list, and terminally marks the table inactive. That
constant-work detach makes every entry unreachable without first scanning
storage that is about to be discarded. Repeated release is idempotent.

After release, the predicate, active-state query, statistics, and idempotent
release remain valid. All other operations reject the inactive table. Code
that owns nonlocal control transfer pairs a call-scoped table with
`dynamic-wind`, so exceptions and continuation escapes release it. Re-entering
the continuation observes an inactive table and fails before using stale
roots.

This version deliberately excludes weak keys, ephemerons, finalizers, and
collector notification. Those semantics belong to #666 and require a distinct
collector-owned contract rather than a mode flag on a strong identity table.

## Related work

Ghuloum and Dybvig's
[Generation-Friendly Eq Hash Tables](https://www.schemeworkshop.org/2007/procPaper3.pdf)
is the closest Scheme-specific collector reference. It uses transport link cells
to repair only entries whose keys move during a generational collection. The
current Consent implementation instead avoids address-derived owned hashes by
using stable heap and object identifiers. The paper is prior art for a future
standalone moving collector, not part of the present host adapter contract.

The [MIT/GNU Scheme hash-table design](https://www.gnu.org/software/mit-scheme/documentation/stable/mit-scheme-ref/Hash-Tables.html)
shows the contrasting whole-table repair strategy: address-hashed tables opt
into rehashing after collection. [SRFI 125](https://srfi.schemers.org/srfi-125/)
and [SRFI 126](https://srfi.schemers.org/srfi-126/) explain why public Scheme
interfaces generally use dedicated identity-table constructors or permit an
implementation-selected identity hash rather than promising a portable raw
address hash. Those public callback-bearing APIs remain owned by #178 and #790,
not this private fixed-policy structure.

Hayes's [Ephemerons](https://doi.org/10.1145/263698.263733) and
[SRFI 254](https://srfi.schemers.org/srfi-254/) explain why weak-key tables need
collector-aware reachability when a retained value points back to its key. They
support the separate-issue boundary above. The broader bibliography, including
persistent HAMTs and hash-flooding defenses, lives in
[the broader hash-table references](references.md#hash-tables-identity-and-persistent-map-references).

## Lean host-map specialization and consumers

`(consent identity-map)` is a lean fixed-policy host-key specialization. It
preserves the existing constructor, lookup, mutation, and fast-backend query
while adding delete, clear, release, and structural statistics. Both evaluator
bootstraps load the same Scheme source above the same three-operation adapter
as the generic table. A seven-slot control vector and four-slot chained nodes
replace the generic table's configurable record, tombstone policy, entry
snapshots, and 19-slot operation-counter vector. This keeps hot graph walks
from paying for policy and accounting they do not consume without adding a
native host boundary.

The specialization and generic table import `(consent identity-policy)`, so
the no-hash envelope and maximum hot-map capacity remain single-sourced rather
than drifting between implementations. Identity-map statistics report current
structure and lifecycle only; deterministic operation accounting remains the
generic table's responsibility.

Its fixed fast-backend bucket ceiling is 16,777,215 associations. This covers
the runtime's ten-million-node default evaluation envelope without
preallocating that ceiling. Its four-bucket initial floor limits small-map
slack while keeping geometric rehash work linear. The constructor accepts an
optional symbolic ownership-domain
label so failures and lifecycle accounting identify the responsible runtime
scope.

Datum import and export, result projection, syntax ownership, reader graph
traversals, memory-key normalization, runtime graph comparison, native graph
bridges, and bootstrap-symbol equality preserve their topology and allocation
behavior while releasing call-scoped host tables alongside their intrusive
owned maps. Native bridges release both per-walk indexes and every index owned
by the outer call during dynamic unwind. Canonical heap-owned reading continues
to use intrusive object headers and does not touch host identity tables.
Host datum conversion classifies acyclic flat proper lists with constant-space
cycle checkpoints and copies them forward without building per-node graph
records or an identity table. Branching, nested, shared, and cyclic host graphs
retain the general identity-table-backed topology algorithm.
Memory redaction and equality consumers scan unary graph spines with
constant-space cycle detection, allocating an identity table only when a graph
branches or unequal cycle periods require general congruence closure.

Redaction predicates now mark visited pair and vector identities, and redaction
copies memoize source-to-output identities before descending. Cycles therefore
terminate, shared subgraphs remain shared, and repeated shared secrets log one
decision. Helper and artifact copies use the same shell-first memoization so
their documented Scheme-readable payloads preserve cycles and sharing instead
of duplicating or looping. Both use `(consent identity-map)` directly; scalar
roots bypass table allocation.

The JSON writer uses graph identities as an active path rather than a global
visited set. Object spines receive constant-space proper-list and cycle
validation; the map retains only active container roots and compound entry
edges. Atomic adjoin avoids a separate lookup and insertion, and scalar entry
values bypass identity hashing. Shared acyclic values remain legal and are
emitted at every occurrence; an ancestor back edge raises a deterministic JSON
error. Memory-key sessions now use the identity-map specialization directly on
both fast and compatibility hosts, removing their duplicate 64-entry alist
while preserving their consumer-specific fail-closed diagnostic.

## Verification

`tests/scheme/consent-identity-table-test.scm` covers equal-but-distinct host
keys, cycles, shared values, mixed namespaces, stable owned identifiers,
stored false values, updates, chained deletion, open-table tombstone reuse,
bounded growth, pre-reserved failure, clear and release, and deterministic
accounting. A
forced compatibility case fills exactly 64 identities and proves the next
insertion fails without hashing or mutation. Counted 128- and 256-entry runs
guard additive expected O(N) work.

Redaction, helper, evaluator, and JSON suites cover cyclic and shared consumer
graphs. The identity-table suite pins the 64-key no-hash envelope inherited by
these compatibility consumers.

Exception and continuation fixtures verify release on every dynamic exit and
re-entry failure. The portable plan runs the same program on direct and
compiled hosts. ERT imports the internal library through the Emacs source
loader and asserts that its adapter overlay contains only host-backend
availability, identity hash, and raw identity comparison.
