# Portable Compound Datum Heap Design

**Issues:** #347 and #982

**Roadmap versions:** 0.18.38 and 0.18.45

**Status:** Implemented

## Summary

Consent Scheme owns the identity and mutation semantics of portable pairs,
strings, vectors, and bytevectors. Scheme-visible values of those kinds are
opaque objects allocated in an explicit `(consent datum)` heap, rather than raw
containers borrowed from the R7RS implementation that happens to host the
portable runtime.

The owned representation is also the native-compiler destination. A compiler
may change the private storage layout or accelerate access, but it must retain
the heap's explicit identity, metadata, graph, and mutation contracts. Host
containers remain useful inside the bootstrap implementation and at real host
ABI edges; they are not a second language-visible compound-value domain.

## Goals

- Give every portable pair except the empty list, and every string, vector, and
  bytevector, an owned identity independent of host `eq?`.
- Preserve R7RS mutation and aliasing for the representative compound
  operations implemented by `(scheme base)`.
- Preserve arbitrary cycles and sharing across reader, evaluator, writer, and
  borrowed-host boundaries.
- Route visible mutation through one heap-owned gateway with revision and
  observer metadata that later checkpoint work can consume.
- Keep parser syntax, evaluator control records, and borrowed-host containers
  private and explicitly named at their boundaries.
- Exercise the same mutation, equality, and writer cases through the portable
  and Emacs fixture consumers.

## Non-goals

- Implement garbage collection, compaction, or a compiled object layout.
- Own ports, process handles, filesystem handles, or other host-effect values.
- Rework symbol identity or interning, which belongs to #346.
- Complete the systematic `eq?`, `eqv?`, `equal?`, membership, and association
  cleanup owned by #348.
- Implement checkpoint fork, commit, abort, or branch-local copy-on-write.
  Issue #721 owns that work.

## Owned Representation

`(consent datum)` defines one heap type, kind-specific public compound record
types, and private sidecar and runtime-slot records.

A datum heap carries:

- a process-local heap id;
- an allocation generation;
- an owner tag reserved for a checkpoint branch or delta;
- the next object ordinal;
- one mutation observer;
- a frozen flag and optional certified-image membership set; and
- optional revision, traversal, graph-map, and source-provenance sidecars.

Every owned object carries only its allocating heap reference and stable object
ordinal as its common identity header. The remaining physical fields are
kind-specific:

- a pair stores `car` and `cdr` inline in that same record;
- a string or vector stores one private indexed host-vector payload;
- a bytevector stores one private host-bytevector payload; and
- a private runtime-slot object stores its open-ended kind and one indexed
  payload.

Heap id, generation, owner, and mutability are derived from the heap rather
than copied into every object. Public kind is derived from the specialized
record type; only open-ended private runtime slots store a kind. Revisions,
source notes, traversal marks, and intrusive graph-map entries live in
heap-owned two-level pages indexed by object ordinal. A fixed 256-ordinal page
amortizes dense traversal setup while bounding the cost of one sparse late
property; the outer page index grows geometrically. Each page is one vector
whose first slot counts live entries. Each sidecar is absent until its first
non-default value, empty pages are released, and the sidecar is dropped when
its final entry clears. Ordinary pairs therefore pay for none of those cold
fields.

The semantic identity key is `(heap-id, object-id)`. Compound-value code
compares that key through `consent-datum-same?`; it does not infer language
identity from the host record or its private storage. Fresh allocations
therefore have fresh identity even when their contents are equal.

The compact pair calls one record constructor and performs no payload-container
allocation. The portable implementation still uses a host vector for vector
slots and indexed string characters, and a host bytevector for byte storage.
The character vector makes owned string length, reference, and mutation
independent of a host string's variable-width or rope layout. Those containers
never escape `(consent datum)` directly. Accessors return language values or
scalar adapter values, and host projection always returns a graph copy.

The empty list remains the unique immutable host sentinel. It has no mutable
payload or allocation identity, so wrapping it would add no owned semantics.

Owned provenance is keyed by the ordinal of the object it describes.
Heap-taking reader entry points attach the newest note to the lazy source
sidecar while constructing the owned object; they create neither a private host
compound graph nor a provenance identity arena. The stored note is compact and
immutable; propagation keeps that note opaque, and the public source record is
materialized only at an observing boundary. Legacy syntax-only reader entry
points retain their separate bootstrap metadata table because host containers
have no owned ordinal.

The per-reader `max-source-metadata` ceiling still bounds attachments made by
one read. Persistent context source-table counts include only retained host
keys. Owned slots follow normal heap reachability and do not enter that count:
plain R7RS has no weak-key notification or object-death hook with which to
decrement it honestly.

`consent-call-with-datum-construction` grants a dynamic, one-shot capability to
allocate exact-size pair, string, vector, and bytevector shells. Each slot is
filled exactly once; a separate single fixup is available for datum-label
resolution. Markers occupy one scope-local vector indexed from the heap's
starting ordinal; gaps cover only allocations made during that same dynamic
scope. Normal return verifies completeness, seals every shell, and drops the
vector, without a mutation event or revision change. Exceptional exit makes
the capabilities unusable and sanitizes any shell a trusted producer
side-effected out of the scope, so no uninitialized sentinel becomes
observable. Bytevectors allocate their final payload immediately instead of
copying a temporary payload at seal.

## Mutation Gateway

Every public pair, string, vector, and bytevector setter validates the active
heap, object kind, heap ownership, index, and mutability before changing
storage. It then:

1. calls the heap observer with the heap, object, operation, slot, old value,
   and new value;
2. performs the storage mutation; and
3. advances the object's revision in the ordinal sidecar.

Fresh graph shells have a private initialization path. Reader label repair and
graph import can therefore construct a cycle without reporting partially built
objects as user mutations. Record constructors likewise install their initial
field graph before publication; generated record mutators use the ordinary
owned vector gateway.

Mutable lexical cells use private `cell` slot objects in the same heap. Initial
binding installation records revision zero without reporting a write; `set!`,
definition initialization, and record-binding replacement use distinct
observer operation tags. Bootstrap and imported binding cells that Scheme code
cannot mutate may remain private host records until they enter an active
evaluation context.

R7RS permits mutation of a literal to raise an error. A context-local mutable
literal remains isolated. Repository-trusted parsed forms or literal
aggregates may instead enter the frozen runtime-image boundary described below;
the two policies are explicit and never inferred from source spelling.

## Frozen Runtime Images

`consent-datum-heap-freeze!` accepts a heap and a proper list of intended image
roots. It first rejects an active construction scope, then validates the graph
iteratively. Same-heap pairs and vectors contribute edges; strings and
bytevectors are leaves. Raw host compounds, mutable foreign owned values, and
private runtime-slot kinds fail closed. An edge to an already certified object
in another frozen heap is permitted.

Validation records reachable same-heap ordinals in a pre-reserved `(consent
dense-set)`. A failed validation releases that temporary set and leaves the
heap mutable. A successful validation installs the membership set and seals the
whole heap. Allocation, content mutation, owner and observer replacement, and
source-provenance replacement then fail. The operation is idempotent; later
calls cannot widen the original root set silently.

`consent-datum-object-shareable?` is true only for certified reachable objects,
not every allocation that happens to precede the seal. Import into another heap
reuses a certified object directly and read-only, so a cached parsed library
form or literal aggregate can retain its Consent identity and graph topology
without a per-context copy. An unreachable object in the frozen heap is still
immutable, but import copies it into the target and gives the copy a mutable
target identity. This distinction prevents the seal from publishing accidental
heap history.

The frozen boundary supplies the immutable base later copy-on-write work may
reference. It does not define writable descendants, fork commits, or rollback;
those remain #721. Nor does it freeze #120's compiled ABI layout: a native
runtime may encode the same heap/ordinal/image contract in different headers.

## Graph Import and Export

The owned boundary uses an explicit memoized graph worklist, not recursive tree
copying. For pairs and vectors it allocates a shell, records the
source-to-target association, fills edges, and then publishes the completed
object. Strings and bytevectors are memoized too, so repeated references retain
aliasing even though they cannot contain graph edges.

Import accepts either a host graph or an object from another datum heap. A
cross-heap import creates fresh destination identities while preserving every
cycle and shared edge inside the imported graph. A leaf callback owns symbols,
numbers, characters, procedures, and other noncompound values at the relevant
runtime boundary. A second callback copies source provenance without making
its return value part of graph conversion.

Export uses the reverse shell-first algorithm. It is an adapter snapshot, not
an alternate representation that Scheme code may retain. Textual write/read
round trips preserve graph topology through datum labels, but ordinary text
does not promise to preserve heap or object ids. Context-free host projection
also leaves provenance on the owned graph: attaching it to an ephemeral host
copy would retain that copy in process-global metadata. A context-aware
caller may transfer immutable provenance into its own bounded overlay.

## Syntax and Value Domains

The frontend deliberately distinguishes private syntax from public values.

- `consent-read`, `consent-read-all`, recovery, macro expansion, and library
  loading may build host compounds as private bootstrap syntax containers.
- `consent-read-datum`, its incremental counterpart, and the standard `read`
  primitive construct compounds directly in the active datum heap before
  publishing them.
- Repeated incremental reads use `consent-make-reader-source` to decode source
  characters and build the line index once. Textual ports cache one current
  snapshot and replace it whenever their source changes.
- Passing a raw string to an incremental entry retains stateless, one-shot
  compatibility semantics and preprocesses that string for the call. It is not
  the repeated-read performance interface.
- Quote, quasiquote, self-evaluating compound literals, constructor results,
  rest arguments, host results, and callback arguments enter the heap before
  Scheme code observes them.
- Macro expansion, library resolution, and evaluator control paths explicitly
  project an owned form back to private syntax when they need to inspect its
  structure.

This split avoids turning implementation argument lists, environment frames,
manifest records, and trampoline state into Scheme-visible heap objects while
still preventing raw host compounds from leaking through value-producing
paths.

Each evaluation context owns a datum heap beside its symbol table. A persistent
interaction context reuses both handles across submissions so values retained
by one REPL interaction preserve identity and mutation in later interactions.
Reusable public environments retain their heap too. A later evaluation adopts
that heap before reading source, so binding and compound mutation continue to
address the original owned objects instead of creating a mismatched heap view.

## Equality and Writing

Compound identity predicates use the explicit identity key. Structural
equality traverses owned pair and vector edges and tracks pairs of compared
object identities, so it terminates for cyclic graphs, including cycles with
different periods. String and bytevector equality reads owned scalar contents.

Writers count and label pair and vector graph nodes by owned identity.
`write` labels cycles, `write-shared` also labels acyclic sharing, and
`write-simple` renders an acyclic expansion without exposing the private
representation. Source metadata and bounded rendering use the same owned graph
accessors rather than host `assq`, `memq`, or storage identity. Owned writer
registries use scoped ordinal-sidecar marks, cycle discovery uses an explicit
worklist, and output is assembled from fragments once. The sidecar is absent
outside an active traversal. Work is proportional to the visited graph plus
emitted text rather than repeated identity-list searches or prefix copying.

## Borrowed-host Bridge

A native library compiled against the borrowed R7RS host cannot consume an
opaque Consent compound directly. The borrowed-host bridge is therefore one
outer-call borrow scope, not heap state. It creates graph shells for the values
reachable from that call's arguments, shares one identity registry across
arguments, results, and raised conditions, then drops the registry when the
outer call unwinds. Native mutations copy back through the datum mutation
gateway before the scope ends.

This lifetime and mutation model follows the established local-handle,
explicit-promotion, and remembered-set designs collected in the
[runtime references](references.md#runtime-heap-and-native-boundary-references).
In particular, a borrowed mirror is analogous to a local native handle, never
an implicit global reference.

Repeated arguments retain one identity inside the call. Returning or raising a
current argument or subobject recovers the original owned object. A fresh
compound result or condition enters the heap with sharing and cycles intact.
Host error-object irritants cross while the same scope is active, so an
irritant naming a borrowed argument also recovers that argument's identity.

Callbacks and re-entrant native calls are scalar-only under the borrowed ABI.
They fail closed when the active transition already contains compound mirrors,
or when their arguments or results would introduce one. Without instrumenting
every host mutator, reconciling a mutable graph before each nested transition
would require O(B) discovery each time and O(M * B) work across M callbacks.
Higher-order libraries therefore use the portable source realization. #120 or
#662 may later provide direct owned values or barriered native mutators without
weakening this bound.

Raw host mirrors and callback shims may not escape the outer call. A general
compiled library whose exports can retain a borrowed compound in a closure,
record, parameter, or module state is not registered as an interpreted native
realization; its canonical portable source realization is used instead. The
directly linked core ABI preserves designated owner values. Its default
conversion refuses to allocate a borrowed mirror or callback shim for an
unclassified binding. That authorization is part of the one graph walk, before
cache reuse, shell allocation, or leaf conversion; it is not a second scan.
Opaque private records remain unchanged leaves and therefore create no borrowed
bridge state. Expanding the call-scoped allowlist requires an exact
non-retention audit. Direct compiled use of owned values or explicit promoted
handles belongs to #120 and #662 rather than turning borrowed host containers
into a durable second heap.

### Selective stateless native kernels

Portable source realization remains the default for agent libraries. A
performance-sensitive slice may use the borrowed native bridge only as a
bounded stateless kernel: it must be pure, callback-free, non-retaining, and
free of module mutation or host effects. Registration names every exported
procedure and data binding in an exact fail-closed inventory; a missing,
additional, or wrongly typed binding rejects the entire library before any
binding is exposed.

The source facade remains the behavior-owning layer. It projects inputs for the
narrow kernel and retains mutable state, policy decisions, callbacks, effectful
adapters, error orchestration, and result publication. The kernel may compute a
query, codec projection, or fixed predicate, but it may neither retain a
borrowed mirror nor turn native registration into authority for the surrounding
facade. This rule permits measured acceleration without creating a second
compound heap or making native registration the default for portable code.

Call-scoped owned traversals use one intrusive heap sidecar keyed by ordinal;
one lookup performs one ordinal-slot probe and scope release restores any outer
mark. While an inner map is current, an outer map lookup is intentionally
absent; releasing the inner map restores the outer entry's visibility. No
ordinary object reserves a map field while the sidecar is inactive.
The borrowed host's identity adapter is reserved for host objects. Gambit uses
its native `eq?-hash`; other configured performance hosts provide SRFI 69
identity hashing. Table storage and policy remain portable Scheme. The plain
R7RS identity-alist fallback preserves correctness for legacy private reader
syntax and other bounded compatibility paths only.
Foreign datum import and export reserve at most 64 distinct host identities on
that fallback and fail closed before a 65th identity could make association-list
lookup quadratic. It carries no unbounded owned-heap asymptotic claim.
Canonical heap-taking reads never call it.
Cached source libraries with shared-datum labels use the fast identity adapter;
on a compatibility host without one, realization reparses that source instead
of routing the graph copy through the identity alist.
Borrowed native transitions therefore fail closed when their required fast
adapter is absent, while the portable source realization remains available.
Private host storage accelerators remain behind `(consent datum)`; none becomes
a public datum representation.

### Complexity contract

- Heap allocation, identity lookup, access, and mutation are amortized O(1).
- A pair performs one object-record allocation and stores both semantic fields
  inline. Cold sidecars allocate only on the first non-default entry and use
  direct ordinal indexing.
- Direct owned reading is O(source + V + E), allocates one heap object per
  compound datum, and performs no host identity-map operation.
- Ordinary parser-produced, unlabelled private syntax uses one iterative
  host-tree validation pass with no identity map. Labelled syntax, recovery,
  active metadata sinks, owned datums, and arbitrary public inputs retain the
  general graph validator.
- Preparing an incremental source is O(source); any number of reads over that
  immutable snapshot totals O(source + published graphs).
- Copying an owned string range is O(output length) and does not project or
  index the unselected prefix and suffix through a host string.
- Owned-to-owned import and export are O(V + E) in the visited graph and
  allocate O(V); foreign-host import and export have that bound with the hash
  adapter. Without it, the 64-identity compatibility envelope fails closed.
- Runtime-image certification is O(V + E) with O(H) dense storage for a heap
  high-water ordinal H. Importing a certified root is O(1) and allocates no
  replacement graph.
- A scalar native call with no compound arguments performs no historical-heap
  synchronization.
- Fresh native result, condition, and writeback compounds are charged once at
  the source-equivalent value-node cost when import and reconciliation finish.
  Reused borrowed identities are not allocated or charged again. Reconciliation
  publishes native mutations before an aggregate budget stop, avoiding a
  half-applied boundary transaction.
- A no-bridge native result may return scalars and compounds already owned by
  the active context without an identity map. Importing any fresh host or
  cross-heap compound requires the hash-backed adapter and otherwise fails
  closed.
- Borrowed-host reconciliation is O(B) in the active call's graph, independent
  of heap age, earlier calls, and unrelated values.
- Scalar callbacks and re-entrant calls are O(1) boundary work and cannot add a
  compound borrow; one outer compound call is reconciled once.
- A mutation-aware compiled backend may reduce O(B) to changed-object work;
  uninstrumented raw host mutation cannot be discovered without inspecting the
  active borrowed graph.

## Compact Representation Evidence

The issue benchmark is `tools/benchmark-compact-owned-datum.scm`. It reports
setup separately from three operation samples. The following same-machine
Gambit medians compare base commit `212df2d` (version 0.18.44) with the compact
0.18.45 representation. Times are milliseconds unless marked otherwise;
positive changes are improvements.

| Workload | Size | Base | Compact | Change |
| --- | ---: | ---: | ---: | ---: |
| Pair construction | 250,000 | 481.645 | 367.231 | +23.8% |
| Pair traversal | 250,000 | 68.089 | 53.366 | +21.6% |
| Deep equality | 4,096 | 63.479 | 59.700 | +6.0% |
| List copy | 32,768 | 114.518 | 81.598 | +28.7% |
| Reader list | 4,096 | 240.552 | 309.695 | -28.7% |
| Cyclic import/export | 4,096 | 60.771 | 76.893 | -26.5% |
| Vector allocation | 100,000 | 183.902 | 103.875 | +43.5% |
| String allocation | 100,000 | 181.747 | 101.434 | +44.2% |
| Bytevector allocation | 100,000 | 187.166 | 101.744 | +45.6% |

Three fresh-process pair-construction runs under `/usr/bin/time -l` reduced
median peak RSS from 372,031,488 to 195,100,672 bytes (47.6%) and median
end-to-end wall time from 2.08 to 1.67 seconds (19.7%). The physical source of
the allocation reduction is direct: a pair now calls one record constructor
with inline `car` and `cdr`, where the base called a generic record constructor
and allocated a second payload vector.

The compiled agent-memory program retained its 44 cases and 224 assertions in
every process. Alternating three-run medians moved from 118.40 seconds and
118,718,464 bytes peak RSS to 123.28 seconds and 196,345,856 bytes. This is a
4.1% wall-time regression, below the combined 20% and three-second regression
guard, with a reported 65.4% peak-residency cost.

The phase profile attributes the remaining reader and cyclic-boundary cost to
construction validation and transient graph-map pages, not source provenance.
Disabling reader source metadata produced similar medians: 220.198 milliseconds
on the base and 291.998 milliseconds on the compact representation. Releasing
empty pages minimized the compiled workload's peak; retaining touched pages or
flat high-water traversal vectors increased it. The retained design therefore
accepts sub-second reader and cyclic-operation deltas in exchange for removing
four always-present cold fields and the separate pair payload from every pair.
No measured non-pair allocation workload regressed.

## Emacs Parity

The Emacs bootstrap remains an irreducible host implementation rather than a
second copy of `(consent datum)`. Shared conformance fixtures are the behavioral
contract: pair and vector aliasing, string and bytevector mutation, cyclic
equality, and writer labeling must agree on Emacs and every portable host. The
portable representation tests additionally prove that borrowed R7RS containers
do not become the portable language representation.

## Checkpoint Limitation

The heap records owner, generation, lazy revision and traversal sidecars, and a
single mutation observer so #721 can install copy-on-write or delta storage
without changing primitive callers. Mutable heaps still update content in
place. A frozen image is read-only, but this implementation does not create a
writable branch when a future session fork shares one of its objects.

Therefore completion of #347 establishes owned compound identity and a
forkable mutation seam; it does **not** claim complete session-fork or
branch-local mutation isolation. That behavior remains explicitly deferred to
#721.
