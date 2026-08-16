# Bootstrap-Safe Runtime Storage

**Issues:** #968, #969, #980, #971, #982, and #983

**Roadmap versions:** 0.18.39, 0.18.41, 0.18.43, 0.18.44, 0.18.45, and
0.18.46

**Status:** Implemented

## Summary

Five private, portable foundation libraries provide storage for
allocation-sensitive runtime and graph algorithms:

- `(consent growable-vector)` owns bounded indexed storage and imports only
  `(scheme base)`;
- `(consent scratch-arena)` layers reusable, phase-owned lifetimes over that
  storage and imports `(consent growable-vector)`; and
- `(consent worklist)` owns one bounded FIFO and deque ring directly;
- `(consent dense-set)` provides generation-stamped membership and colors over
  one direct dense integer vector; and
- `(consent identity-table)` provides fixed-policy owned and host identity
  associations with bounded growth and explicit release.

The smaller portable `(consent identity-map)` specialization fixes policy to
hot host-key graph walks. It shares the identity adapter and fixed limits while
omitting the generic table's configurable policy and detailed accounting.

None of the libraries imports a public SRFI, calls user code, or depends on an
initialized standard-library shelf. The Emacs bootstrap source loader and
direct or compiled R7RS routes execute the same Scheme sources. A future native
runtime may accelerate the backing storage, but it must preserve the bounds,
clearing, counters, ownership, and failure behavior described here.

The library boundary follows the behavior each abstraction owns:

```mermaid
flowchart TB
  reader["Reader builders"]
  memory["Memory-key graph capture"] --> grow
  grow["(consent growable-vector)<br/>bounded indexed storage"]
  scratch["(consent scratch-arena)<br/>owners, marks, reuse policy"]
  worklist["(consent worklist)<br/>bounded FIFO and deque ring"]
  dense["(consent dense-set)<br/>generation-stamped membership"]
  identity["(consent identity-table)<br/>fixed identity associations"]
  srfi["(srfi 214)<br/>public flexvectors"]
  reader --> grow
  scratch --> grow
  collectors["Collector phases"] --> scratch
  srfi -. "may reuse compatible storage" .-> grow
```

## Choosing the Storage Layer

Use a growable vector when one algorithm directly owns its storage and lifetime.
Use a scratch arena when storage is reused across calls or runtime phases and a
stale operation must be rejected after cleanup.
Use a worklist when logical insertion or removal order, rather than indexed
storage, is the abstraction the algorithm needs.
Use a dense set for membership over bounded integer identifiers, and an
identity table for key-value associations over stable owned or borrowed-host
identity.

| Need | Layer | Why |
| --- | --- | --- |
| Indexed storage with a permanent bound | Growable vector | Smallest API. |
| Reuse with explicit phase ownership | Scratch arena | Stale owners fail. |
| Collector without heap growth | `pre-reserved` arena | Fails full. |
| Temporary safe growth | `allow-growth` arena | Grows boundedly. |
| FIFO graph traversal | Worklist | Ring ordering without list reversal. |
| Double-ended phase work | Worklist | O(1) front and back operations. |
| Dense identifier membership | Dense set | O(1) generation-stamped marks. |
| Identity-keyed values | Identity table | Fixed equality and hash policy. |

None of these layers is a general sequence abstraction. All five libraries are
private, mutable, callback-free, and deliberately narrower than public SRFIs.

Programs that need the public sequence abstraction import `(stdlib
flexvectors)` or one of its SRFI 214 aliases. That library wraps growable
storage in a distinct public record and owns SRFI validation, callbacks,
conversion, search, and mutation semantics without widening the private
storage API.

## Storage Shape and Invariants

The logical prefix and the allocated backing vector are different bounds. The
configured maximum is a budget, not storage allocated in advance.

```mermaid
flowchart LR
  subgraph backing["Allocated backing vector"]
    used["Populated prefix<br/>0 through length - 1<br/>may retain values"]
    spare["Reserved suffix<br/>length through capacity - 1<br/>must contain #f"]
  end

  budget["Unallocated capacity budget<br/>capacity through maximum - 1"]

  used ---|"length boundary"| spare
  spare ---|"capacity boundary"| budget
```

At every active-vector boundary:

- `0 <= length <= capacity <= maximum-capacity`;
- only indexes below `length` are populated and addressable;
- every reserved slot at or above `length` contains `#f`;
- clear replaces the backing vector at the immutable initial capacity;
- reset moves `length` to zero without reducing `capacity`; and
- release clears the prefix, drops the backing vector, and permanently makes
  the growable vector inactive.

The high-water and cumulative counters remain available after release. They
describe the object's history, not its current logical contents.

### Compact control-state inventory

The 0.18.46 audit classifies state by ownership instead of keeping convenient
copies in every wrapper. "Fields" below are portable record slots; a host may
pack them differently. A lazy sidecar is one vector allocated only when an
operation first needs to change a historical counter.

| Layer | Base record fields | Compact record fields |
| --- | ---: | ---: |
| Growable vector | 10 | 6 |
| Scratch arena | 7 | 5 |
| Scratch owner | 4 | 3 |
| Worklist and backing | 18 + 10 | 7 |
| Dense set and backing | 27 + 10 | 10 |
| Flexvector and backing | 1 + 10 | 1 + 6 |

- Growable vectors keep hot length and backing plus initial, maximum, and
  growth-factor policy. Capacity and active state are derived. Four historical
  counters are cold.
- Scratch arenas keep storage, initial floor, policy, and current owner. Owners
  keep arena, lifetime token, and phase. Capacity and owner activity are
  derived. Four arena counters are cold.
- Worklists keep backing, size, front, and three capacity-policy values.
  Capacity and active state are derived. Ten exact counters are cold.
- Dense sets keep backing, initial and maximum capacity, generation bounds,
  color count, policy, domain, current generation, and size. Capacity and
  active state are derived. Seventeen exact counters are cold.
- Flexvectors keep the nominal public wrapper and compact growable storage.
  Public length is delegated to that storage; its four counters are cold.

Worklists and dense sets no longer pay for a wrapper record around a second
growable-vector record. Their direct vectors remain private and portable.
Flexvectors retain one wrapper because SRFI 214 requires a distinct nominal
type; removing it would weaken `flexvector?` and expose private storage.

An `allow-growth` worklist, dense set, or scratch arena records its initial
capacity as a first-allocation floor but starts at capacity zero. Growable
vectors whose initial capacity is zero, and therefore empty flexvectors, also
use a shared non-vector sentinel instead of allocating backing. The first
positive reserve or insertion materializes at least the floor. `pre-reserved`
constructors allocate eagerly, preserving no-allocation phase guarantees.

The empty representation removes one backing-vector header everywhere lazy
storage applies. Direct worklist and dense-set storage also removes one record
header. Gambit's portable record ABI does not expose header bytes separately,
so the benchmark below measures complete host allocation rather than guessing
an ABI size.

### Compact representation evidence

`tools/benchmark-private-storage.scm` reports three raw timing samples for one
selected kind, shape, and lifecycle phase. The following same-machine Gambit
measurements compare base commit `308f056a` with the compact representation.
Each construction timing retains 30,000 objects; times are median seconds and
positive changes are improvements.

| Kind and shape | Base | Compact | Change |
| --- | ---: | ---: | ---: |
| Worklist, empty | 0.346 | 0.049 | +85.8% |
| Worklist, one | 0.410 | 0.210 | +48.8% |
| Worklist, small | 0.813 | 0.669 | +17.8% |
| Worklist, high-water | 9.023 | 5.383 | +40.3% |
| Dense set, empty | 0.388 | 0.078 | +79.8% |
| Dense set, one | 0.498 | 0.255 | +48.8% |
| Dense set, small | 1.119 | 0.926 | +17.3% |
| Dense set, high-water | 8.354 | 6.653 | +20.4% |

Gambit's `time` form measures host bytes allocated inside the construction
body. Empty and small runs use 30,000 retained objects; one and high-water runs
use 10,000. These totals include backing and transient control allocation.

| Kind and shape | Base bytes | Compact bytes | Reduction |
| --- | ---: | ---: | ---: |
| Worklist, empty | 835,004,448 | 98,597,736 | 88.2% |
| Worklist, one | 315,760,944 | 134,917,864 | 57.3% |
| Worklist, small | 1,726,561,008 | 1,123,680,720 | 34.9% |
| Worklist, high-water | 5,753,600,720 | 2,905,120,448 | 49.5% |
| Dense set, empty | 963,121,984 | 168,195,632 | 82.5% |
| Dense set, one | 370,641,232 | 164,195,664 | 55.7% |
| Dense set, small | 2,013,984,608 | 1,433,280,672 | 28.8% |
| Dense set, high-water | 4,866,401,136 | 3,167,201,296 | 34.9% |

Three fresh processes under `/usr/bin/time -l` give these median maximum
resident-set sizes for 30,000-object construction runs:

| Kind and shape | Base bytes | Compact bytes | Reduction |
| --- | ---: | ---: | ---: |
| Worklist, empty | 105,611,264 | 33,210,368 | 68.6% |
| Worklist, small | 104,464,384 | 78,839,808 | 24.5% |
| Dense set, empty | 123,518,976 | 40,239,104 | 67.4% |
| Dense set, small | 125,566,976 | 100,384,768 | 20.1% |

Small-shape residency includes the live payload vectors and host heap
granularity. Its control-allocation reductions, 34.9% for worklists and 28.8%
for dense sets, satisfy the 25% compactness threshold independently. Empty
allocation and residency exceed that threshold for both structures.

The phase benchmark uses 30,000 balanced steady operations or 30,000
pre-populated eight-element objects. Dense-set reset is its explicit full
clear; scratch clear and release both release an owner; flexvectors expose
clear but no private reset or release. Times are three-run median seconds.

| Layer and phase | Base | Compact | Change |
| --- | ---: | ---: | ---: |
| Growable, steady | 0.067 | 0.085 | -27.4% |
| Growable, clear | 0.038 | 0.047 | -23.7% |
| Growable, reset | 0.032 | 0.039 | -24.2% |
| Growable, release | 0.045 | 0.049 | -8.5% |
| Scratch, steady | 0.169 | 0.213 | -25.9% |
| Scratch, clear | 0.063 | 0.066 | -5.3% |
| Scratch, reset | 0.080 | 0.093 | -16.1% |
| Scratch, release | 0.063 | 0.067 | -5.9% |
| Worklist, steady | 0.128 | 0.132 | -3.3% |
| Worklist, clear | 0.371 | 0.044 | +88.1% |
| Worklist, reset | 0.165 | 0.160 | +2.8% |
| Worklist, release | 0.204 | 0.146 | +28.6% |
| Dense set, steady | 0.166 | 0.176 | -5.7% |
| Dense set, clear | 0.043 | 0.046 | -5.9% |
| Dense set, full clear | 0.067 | 0.054 | +19.7% |
| Dense set, release | 0.082 | 0.044 | +45.9% |
| Flexvector, steady | 0.366 | 0.416 | -13.8% |
| Flexvector, clear | 0.048 | 0.045 | +5.6% |
| Flexvector, reset analogue | 0.047 | 0.046 | +3.2% |
| Flexvector, release analogue | 0.049 | 0.045 | +8.0% |

The largest relative slowdown is 27.4%, but its absolute median delta is only
0.018 seconds for 30,000 operations. No phase has both a 20% and three-second
regression.

## Growable Vectors

`(consent growable-vector)` exports the storage operations in this section.
`consent-make-growable-vector` takes an initial capacity, a maximum capacity,
and an optional growth factor that defaults to 2. Capacity bounds are exact
nonnegative integers, the initial capacity must not exceed the maximum, and
the growth factor must be an exact real greater than one. All three policy
values are immutable for that storage object.

Initial capacity zero is lazy: the object is active with capacity zero but
owns no backing vector. Its first positive reserve, grow, or append allocates
backing. A positive initial capacity remains eager.

The populated prefix is separate from reserved capacity:

- append returns the new element's zero-based index;
- indexed ref and set accept only populated indexes;
- reserve allocates an exact requested capacity when it is larger;
- grow takes the floor of current capacity times the object's growth factor,
  advances by at least one slot, or uses the requested minimum when that is
  larger, without crossing the configured maximum;
- copy performs an overlap-safe populated-prefix move between growable vectors
  and extends the destination prefix when required;
- fill replaces a populated slice without exposing the backing vector;
- snapshot returns a fresh fixed vector containing only the populated prefix;
- truncate clears a populated suffix and publishes the requested shorter
  prefix; scratch arenas use this operation to reset to an owner mark;
- clear atomically replaces the backing vector at the initial capacity;
- reset clears every populated slot to `#f` and retains the capacity; and
- release clears every populated slot, drops the backing vector, and makes the
  growable vector permanently inactive.

The private growable-vector library also exposes unchecked slot access for
trusted runtime substrates that have already validated their own bounds.
Ordinary consumers use the checked `ref` and `set!` operations.

These operations are distinct primitive-backend lifetime signals. A native or
collector-aware backend must not collapse them into aliases: clear abandons the
high-water allocation and restores either positive initial backing or lazy
capacity zero, reset retains the allocation for reuse after removing live
references, and release relinquishes the backing and invalidates the object.
This contract lets a future Consent collector apply different heap policies
without changing callers.

Append uses geometric growth. With the default factor of 2 and one initial
slot, appending `n` elements copies fewer than `2n` existing elements across
all growths. Every fixed factor greater than one preserves amortized constant
append time; smaller factors trade more copying for less spare capacity.
`consent-growable-vector-stats` exposes logical length, reserved capacity,
maximum capacity, growth factor, high-water length, growth count,
copied-element count, reset count, and released state as Scheme-readable data.

`consent-growable-vector-unused-slots-cleared?` is a private diagnostic for the
garbage-collector root invariant. It scans reserved slots outside the logical
prefix and confirms that none retains a stale value.

### Complexity and Allocation

The table abbreviates the common `consent-growable-vector-` prefix.

| Operation | Time | Backing allocation |
| --- | --- | --- |
| `length`, `capacity`, `ref`, `set!` | O(1) | None. |
| `append!` | Amortized O(1) | Only when full. |
| `reserve!`, `grow!` | O(length) when larger | Only when larger. |
| `copy!` | O(copied slice) | Only when extending past capacity. |
| `fill!` | O(filled slice) | None. |
| `snapshot` | O(length) | Always; returns a copy. |
| `truncate!` | O(removed suffix) | None. |
| `clear!` | O(initial capacity) | When initial capacity is positive. |
| `reset!`, `release!` | O(length) | None. |
| `unused-slots-cleared?` | O(capacity) | None. |
| `stats` | O(1) | Allocates the result datum. |

For example, repeated append from initial capacity zero and maximum capacity ten
uses capacities `0, 1, 2, 4, 8, 10`. The next append fails before allocation.
`reserve!` instead requests an exact larger capacity; `grow!` treats its
argument as a minimum and may choose the larger geometric capacity.

## FIFO and Deque Worklists

`(consent worklist)` stores its logical sequence in one private circular
vector. It owns capacity and copying directly, so there is no second growable
record holding mirrored capacity, maximum, growth, or active state. Callers
never receive the backing vector or a physical index.

The constructor fixes an initial capacity, exact maximum capacity, and one of
two growth policies:

- `allow-growth` begins without backing, then allocates at least the initial
  floor and doubles full storage up to the exact maximum; and
- `pre-reserved` rejects a push whenever the currently reserved ring is full.

`reserve!` can establish collector scratch capacity before a no-allocation
phase. It preserves logical order even when the current sequence wraps around.
Push-front, push-back, front, back, pop-front, and pop-back are constant-time
when no growth occurs. Automatic growth copies the current logical sequence
once into a larger ring with its front at physical slot zero, so geometric
growth preserves amortized constant-time insertion.

Every successful push or pop charges exactly one work unit. Peeks, snapshots,
capacity changes, clear, reset, and release do not charge work units. Statistics
report the four directional operation counts, aggregate pushes and pops, total
work units, capacity changes, automatic growths, copied elements, high-water
size, clear count, and reset count. Incremental collectors can therefore budget
logical work independently of elapsed time and backing-store growth.

A pop clears its vacated physical slot before publishing the shorter size.
Reset clears all active slots while retaining capacity. Clear returns an
`allow-growth` ring to lazy capacity zero, but eagerly restores a
`pre-reserved` ring's initial capacity. Release clears active slots, drops
backing storage, and permanently rejects further queue operations. The
diagnostic
`consent-worklist-unused-slots-cleared?` verifies that no inactive ring slot
retains a heap root, including across a wrapped logical range.

Rejected constructor arguments fail before allocating a worklist. Rejected
reservations, empty-boundary operations, and capacity-exhausted pushes preserve
logical contents, capacity, and statistics. Failed pushes do not charge work
units. Clear and reset empty the ring but retain its lifetime counters; release
also preserves those counters so `consent-worklist-stats` can report the
completed lifetime. After release, `consent-worklist?`,
`consent-worklist-active?`, statistics, the cleared-slot diagnostic, and
idempotent release remain available. All other API operations reject the
inactive worklist.

### Collector Lifecycle

Reserve storage before entering a no-allocation phase, and keep the worklist in
explicit phase state so successive slices share the same ring and counters.
Arrange terminal cleanup with `dynamic-wind`:

```scheme
(define (call-with-trace-state maximum-capacity roots use-state)
  (let ((worklist
         (consent-make-worklist
          0 maximum-capacity 'pre-reserved)))
    (consent-worklist-reserve! worklist maximum-capacity)
    (for-each
     (lambda (root)
       (consent-worklist-push-back! worklist root))
     roots)
    (let ((state (vector 'trace worklist)))
      (dynamic-wind
       (lambda () #t)
       (lambda () (use-state state))
       (lambda ()
         (consent-worklist-release! worklist))))))
```

A resumable slice can compare the lifetime work counter before and after each
algorithm step instead of consulting elapsed time:

```scheme
(define (run-trace-slice! state budget step!)
  (let* ((worklist (vector-ref state 1))
         (start (consent-worklist-work-units worklist)))
    (let loop ()
      (cond
       ((consent-worklist-empty? worklist) 'complete)
       ((>= (- (consent-worklist-work-units worklist) start)
            budget)
        'suspended)
       (else
        (step! worklist
               (consent-worklist-pop-front! worklist))
        (loop))))))
```

`step!` may enqueue discovered values with `push-back!`; those pushes and the
pop are all charged. The check occurs between steps, so an algorithm that needs
a strict ceiling must also bound one step's fan-out or suspend a partially
enumerated node explicitly. Suspension leaves the worklist active in phase
state. Normal completion, an exception, or a continuation exit runs the cleanup
thunk and releases it. Because release is terminal and idempotent, later
continuation re-entry cannot resume queue operations on the released ring; they
fail closed instead.

### Worklist Complexity and Allocation

The table abbreviates the common `consent-worklist-` prefix.

| Operation | Time | Backing allocation |
| --- | --- | --- |
| `empty?`, `size`, `capacity`, `front`, `back` | O(1) | None. |
| `push-front!`, `push-back!` | Amortized O(1) | Only when full and allowed. |
| `pop-front!`, `pop-back!` | O(1) | None. |
| `reserve!` | O(size) when larger | Only when larger. |
| `snapshot` | O(size) | Always; returns a copy. |
| `reset!`, `release!` | O(size) | None. |
| `clear!` | O(size) | Only for a positive pre-reserved floor. |
| `unused-slots-cleared?` | O(capacity) | None. |
| `work-units` | O(1) | None. |
| `stats` | O(1) | Allocates the result datum. |

## Scratch Arenas

`(consent scratch-arena)` imports `(consent growable-vector)`, owns one such
vector, and issues at most one active owner at a time.
`consent-scratch-arena-acquire!` requires a symbolic phase and returns a fresh
owner lifetime. Every append, ref, set, mark, and reset operation takes that
owner. Release clears the complete logical prefix before the arena can issue
another owner.

Marks are ownership-stamped exact integers. Each owner receives a library-wide
monotonic lifetime token, so a mark from another arena or a released lifetime
is rejected even when the arenas share a capacity and acquisition ordinal.
Reset clears the suffix back to the marked length before publishing the shorter
prefix. A mark beyond the current prefix cannot extend storage after an earlier
reset.

Arena statistics distinguish:

- current logical elements and reserved capacity;
- configured maximum capacity and growth policy;
- high-water logical usage across all lifetimes;
- acquisitions, mark resets, and owner releases; and
- backing-storage growths and copied elements.

The arena has two growth policies:

- `allow-growth` starts without backing. Its first append or positive reserve
  allocates at least the configured initial floor, then active append grows
  geometrically up to the maximum. It is suitable only when allocation from
  the current runtime heap is allowed or the backing store is an external
  adapter.
- `pre-reserved` forbids growth while an owner is active. Reserve the arena
  while it is idle, before entering a collector or no-allocation phase. An
  exhausted owner fails closed instead of recursively allocating from the heap
  being collected.

Owner acquisition creates its lifetime token, so a collector must acquire the
owner before entering the portion of a phase in which ordinary allocation is
forbidden. Marks do not allocate compound storage. A compiled adapter may make
the owner token and exact marks immediate values, but cannot weaken their
lifetime checks.

Although a mark is represented by an exact integer, callers must treat it as
opaque. It must not be decoded, adjusted, transferred to another owner, or used
after its owner is released.

### Arena Lifecycle

The arena retains its backing capacity while owner lifetimes come and go. The
owner, not the arena alone, is the capability required for active operations.

```mermaid
stateDiagram-v2
    state "Idle arena" as idle
    state "Active owner" as owned

    [*] --> idle
    idle --> idle: reserve! may allocate
    idle --> owned: acquire!(phase) creates owner
    owned --> owned: append!, ref, set!, mark, reset!
    owned --> idle: release! clears populated prefix

    note right of idle
      No current owner
      length is zero
      capacity is retained
    end note

    note right of owned
      Only the current owner is valid
      Nested acquire and reserve fail
      Invalid operations leave state unchanged
    end note
```

Allocation-sensitive code must order the lifecycle deliberately:

1. Reserve the needed capacity while the arena is idle.
2. Acquire the owner before entering the no-allocation section; acquisition
   creates the owner record and lifetime token.
3. Use only owner operations within the reserved capacity.
4. Leave the no-allocation section and release the owner, clearing all roots.

Do not call `snapshot`, either statistics procedure, or other result-building
diagnostics inside a strict no-allocation section. A `pre-reserved` append does
not allocate backing storage, but it fails without changing state when capacity
is exhausted.

### Worked Mark and Reset Trace

This trace keeps one root, discards later temporary work, and then releases the
whole lifetime:

```scheme
(define arena
  (consent-make-scratch-arena 2 8 'pre-reserved))

(consent-scratch-arena-reserve! arena 6)

(let ((owner (consent-scratch-arena-acquire! arena 'trace)))
  (consent-scratch-owner-append! owner 'root-a)
  (let ((mark (consent-scratch-owner-mark owner)))
    (consent-scratch-owner-append! owner 'root-b)
    (consent-scratch-owner-reset! owner mark))
  (consent-scratch-owner-release! owner))
```

The state changes are:

| Point | Active | Length | Capacity | Retained values |
| --- | --- | ---: | ---: | --- |
| After reserve | No | 0 | 6 | None. |
| After acquire | Yes | 0 | 6 | None. |
| At mark | Yes | 1 | 6 | `root-a`. |
| Before reset | Yes | 2 | 6 | `root-a`, `root-b`. |
| After reset | Yes | 1 | 6 | `root-a`; later slots are `#f`. |
| After release | No | 0 | 6 | None; all reserved slots are `#f`. |

The reset increments the arena reset count. Release increments its release
count and invalidates `owner`, while the arena keeps six slots for its next
lifetime.

### Concurrency Boundary

The portable records and the library-wide owner-token counter are not
synchronized. An arena and its growable vector belong to one serialized runtime
execution context at a time. A host that shares them across native threads must
serialize access or provide an adapter with equivalent atomic ownership and
publication behavior. Owner checks prevent stale-lifetime use; they are not a
data-race primitive.

## Dynamic Extent and Re-entry

The storage API accepts no procedure, comparator, hash function, or element
callback. A caller that needs dynamic cleanup acquires an owner first and pairs
it with `dynamic-wind`:

```scheme
(let ((owner (consent-scratch-arena-acquire! arena 'trace))
      (reentered? #f))
  (dynamic-wind
   (lambda ()
     (if (not (consent-scratch-owner-active? owner))
         (set! reentered? #t)))
   (lambda ()
     (if reentered?
         (error "scratch owner cannot be re-entered")
         (begin
           ;; Perform the trace using OWNER.
           ...)))
   (lambda ()
     (if (consent-scratch-owner-active? owner)
         (consent-scratch-owner-release! owner)))))
```

Normal return, an exception, or a continuation escape runs the release thunk
and clears retained roots. Re-entering a continuation captured inside the body
runs the before thunk against the same released owner, records re-entry, and
fails closed from the body after surrounding dynamic state is restored. The
before thunk deliberately does not raise: Scheme hosts differ in how much
dynamic state they restore before a failing before thunk. An escaped owner also
remains invalid after the arena is acquired for a later phase.

The explicit pattern keeps callback invocation out of the storage primitive.
Collector and runtime code own their control transfer, while the arena owns
storage lifetime and validation.

## Failure Contract

Capacity, index, ownership, and phase failures raise Scheme errors with stable
messages and Scheme-readable irritants. Exact Scheme arithmetic determines
growth requests, so capacity calculation cannot wrap into a smaller positive
allocation. A request above the configured maximum fails before allocation.

Host `make-vector` failure is caught and normalized to a storage-allocation
error containing the requested capacity. New backing storage is published only
after allocation and prefix copying complete. Failed growth therefore leaves
the previous backing vector and its logical prefix authoritative.

The following cases fail closed:

- malformed or inverted capacities;
- malformed, negative, or unpopulated indexes;
- reserve or growth beyond the configured maximum;
- active growth in a `pre-reserved` arena;
- nested acquisition or reserve while an owner is active;
- a released or non-current owner operation; and
- a reset mark from another owner lifetime or beyond the current prefix.

## Scheme Corpus Audit

The repository-wide audit used three questions for each apparent accumulator:

1. Is the final value vector-like, or is a list, string, bytevector, queue, or
   hash table the actual abstraction?
2. Is the final length unknown during the one pass that produces elements?
3. Must the code run before optional standard libraries are realized, and can
   it remain bounded and callback-free?

Passing all three questions is a strong primitive-storage fit. Code that calls
user procedures or implements an optional public sequence belongs above the
bootstrap boundary and should use SRFI 214 instead.

### Primitive Refactors

The memory-key graph capture already uses private growable vectors for dense
labels, edges, and canonical descriptors. That remains the highest-value use:
the final shape is a vector, graph size is not known before traversal, and the
algorithm runs on a bootstrap path.

The reader now uses the same primitive in two further places:

- source-location indexing appends line starts while its existing exact-size
  offset-to-line vector is filled; and
- vector and bytevector literal parsing appends elements under the reader's
  configured length ceiling, snapshots once, and then either returns the host
  vector or fills an exact-size owned vector or bytevector.

Both builders know a permanent maximum before appending, invoke no user code,
and discard their private capacity after producing a detached result. They
remove intermediate cons cells and reverse passes without changing reader
limits, element order, source metadata, or owned-datum construction.

### Public Flexvector Collector Refactors

Two optional standard-library modules now use the public flexvector surface:

- SRFI 42 `vector-ec` and `string-ec` collect unknown comprehension output
  with `flexvector-add-back!`, then use `flexvector->vector` or
  `flexvector->string`; and
- SRFI 158 `generator->vector`, `vector-accumulator`, and
  `reverse-vector-accumulator` avoid intermediate lists through
  `generator->flexvector`, back insertion, conversion, and reversal.

These paths execute user expressions or generator procedures and expose
standard-library behavior. They therefore must not depend directly on the
callback-free primitive, even if the SRFI 214 implementation internally reuses
compatible primitive storage.

### Worklist Candidate Decisions

The worklist audit first distinguished true queue ordering from code that only
used a variable named `pending` or `work`. A migration also needed a permanent
bound, bootstrap-safe dependencies, and a lifecycle in which clearing retained
slots was useful. The resulting decisions are:

| Candidate | Decision |
| --- | --- |
| Memory-key partition refinement | Migrate. |
| Memory-key canonical quotient | Migrate. |
| Memory-query automaton completion | Migrate. |
| Memory-query bounded record walk | Keep. |
| Datum import/export traversals | Keep. |
| Interpreter ownership/equality traversals | Keep. |
| Result graph rendering traversals | Keep. |
| Symbol-boundary graph equality | Keep. |
| Library egress scan and dirty propagation | Keep. |
| Test finite-graph bisimulation oracle | Keep. |

- `(agent memory-key)` partition splitters are a deduplicated FIFO bounded by
  graph state count. The local two-list queue duplicated exactly the worklist
  contract.
- Its canonical quotient uses first-discovery BFS order to assign identifiers.
  A FIFO bounded by quotient block count makes that ordering explicit.
- `(agent memory-query)` Aho-Corasick failure links require breadth-first parent
  completion. The call-scoped two-list FIFO retained automaton nodes and
  duplicated reversal logic.
- The separate memory-query record walk is a depth-first compatibility guard
  capped at 64 compound nodes. A preallocated ring would add fixed overhead
  without adding queue semantics.
- `(consent datum)` uses vector continuation frames as LIFO stacks. Finish and
  child order, not FIFO discovery, are the abstraction.
- `(consent interpreter)` uses LIFO task or comparison stacks charged by
  evaluator budgets. A deque would not simplify the continuation protocol.
- `(consent result)` uses lazy LIFO finish/visit stacks. Lists preserve the
  allocation-free scalar hot path; every call should not allocate a ring.
- `(consent symbol-boundary)` uses a LIFO pair-comparison stack with no
  observable FIFO order or deque operation.
- `(consent library)` uses deduplicated LIFO scan and dirty stacks. Node flags
  own scheduling, order is unobservable, and no queue duplication is removed.
- The test-only finite-graph bisimulation oracle stays independent and
  list-based instead of depending on the runtime abstraction it helps verify.

The three migrated queues now use `push-back!` and `pop-front!`, release their
ring storage through `dynamic-wind`, and retain their existing algorithm-owned
bounds and ordering. No stack was migrated merely to reduce consing; a future
stack abstraction should be justified on its own contract and measurements.

The first memory-key migration exposed validation amplification in the
interpreted bootstrap: each queue operation revalidated both the worklist and
its growable-vector slot. Letting the already-validated worklist use trusted
growable-vector slot operations removes that repeated validation. The backing
vector remains hidden, checked growable-vector callers retain their original
contract, and the counted scale gate confirms linear total work.

Absolute wall-clock evidence remains mixed. Successive CI runs of the same
optimized runtime code took 141.912 and 154.938 seconds in memory-key
refinement, while the unchanged paired memory-query shard moved in the opposite
direction from 135.185 to 102.112 seconds. The memory-key results bracketed the
149.011-second unoptimized worklist run and both remained above the
117.407-second pre-migration list-queue run. These separate runs do not
establish a speedup. A trustworthy comparison requires equivalently prepared
worktrees, identical generated artifacts, and repeated runs summarized by their
median.

### Candidates Rejected or Deferred

- `(data transient-map)` grows an open-addressed hash table. Its sparse slots,
  probing, deletion markers, and rehash threshold are not a growable sequence;
  replacing its backing vector with this primitive would hide rather than
  simplify the table invariants.
- Fixed-size vector operations in the evaluator, datum heap, numeric backend,
  base prelude, and native bridge already know their result length. Exact
  allocation and direct indexed filling are cheaper and clearer than geometric
  growth.
- Reader string and escaped-symbol accumulators are already linear and usually
  small. Promoting every token to a record plus backing vector would add fixed
  overhead; a future character or string builder should be justified by
  profiles rather than by sequence resemblance alone.
- Writer fragments and interpreter string or bytevector port refills ultimately
  need contiguous text or bytes, not object slots. The refill paths deserve a
  chunked byte/string buffer review because repeated concatenation can copy
  quadratically, but an object growable vector would complicate cursor access
  and unread-remainder semantics instead of solving that representation need.
- Ordinary `cons` plus `reverse` loops that intentionally return lists should
  stay lists. Avoiding lists is not itself a reason to cross the storage-layer
  boundary.

## Layering and Consumers

The memory-key canonicalizer uses `(consent growable-vector)` for its dense
label, edge, and descriptor vectors and `(consent worklist)` for partition and
canonical-BFS queues. Its graph semantics and asymptotic gates remain owned by
`(agent memory-key)`; only compatible storage and queue machinery moved.

The memory-query text automaton uses a call-scoped worklist while completing
failure links breadth-first. It releases the ring after completion; the durable
automaton owns the nodes and links, not the temporary traversal container.

The reader uses per-call growable vectors for line-start and literal-element
builders. It snapshots before publishing a result and releases the private
storage during dynamic cleanup, so capacity and lifecycle policy cannot escape
through the reader API.

SRFI 214 flexvectors reuse the private storage where the semantics agree. The
public layer does not expose collector phase, reserve, reset, release,
maximum-capacity, or allocation-policy details as SRFI behavior. SRFI 158
vector collectors and SRFI 42 vector and string comprehensions use that public
layer so long collections avoid intermediate reversed lists.

The backing policy intentionally differs from the official SRFI 214 sample in
one non-semantic detail: `flexvector-copy` right-sizes new storage to the copied
length, subject to the four-slot minimum, instead of preserving spare source
capacity. Flexvector storage selects the sample's 3/2 growth factor through the
private per-object policy, while other primitive consumers retain the private
constructor's default factor of 2. These are implementation policies, not SRFI
guarantees, and may be retuned from benchmark evidence.

An empty flexvector wraps compact growable storage with initial capacity zero,
so it owns no backing vector. The first insertion reserves at least four slots;
constructors for positive sizes reserve at least that floor immediately.
`flexvector-clear!` invokes private clear and returns to lazy capacity zero. On
success, the high-water backing vector becomes unreachable and eligible for
collection, so repeated grow-and-clear cycles do not permanently retain their
largest historical allocation. Explicit `consent-growable-vector-reset!`
instead retains capacity for scratch storage whose caller intends reuse.

Bulk flexvector insertion, removal, copying, and filling use private
`vector-copy!` and `vector-fill!` operations owned by `(consent
growable-vector)`. Copying is overlap-safe, including self-copy, while the raw
backing vector remains outside both the SRFI and internal-library interfaces.

The baseline and incremental collectors in #335 and #966 consume
`pre-reserved` arenas. They must reserve and acquire outside the no-allocation
trace section and treat capacity exhaustion as a Scheme-readable collection
failure, not as permission to allocate from the heap under collection.

Generation-stamped membership and small-color state belong to
`(consent dense-set)`, not to the arena's positional reset marks or the
worklist's ordering state. Dense-set slots contain only encoded exact integers;
ordinary clear advances an epoch without scanning capacity. See
[Generation-Stamped Dense Sets and Epoch Marks](dense-sets.md) for wraparound,
ownership-domain, accounting, and memory-key migration details.

The compound datum heap uses stable object ordinals as its sidecar index. Four
optional two-level page tables own mutation revisions, traversal or
collector state, call-scoped graph-map entries, and source provenance. A
sidecar is `#f` until its first non-default entry. Its outer page vector grows
geometrically; fixed 256-ordinal pages allocate independently and disappear
when empty; the whole sidecar returns to `#f` when its last entry clears. A
page is one vector whose first slot is its live-entry count. These are
heap-private property columns, not a new public table: ordinary pairs carry
only heap, ordinal, `car`, and `cdr`, and an active algorithm pays only for the
column and pages it uses. Two arithmetic indexes preserve constant lookup
without an identity hash, a high-water-sized sparse vector, or one empty
property field per object.

Reader shell construction is already one dense dynamic extent, so it uses a
scope-local vector indexed relative to the heap's starting ordinal. That
vector covers only allocations made while the capability is active and is
dropped when the scope seals or sanitizes its shells. It does not share the
longer-lived heap traversal property column.

Frozen runtime-image membership is a different shape. Seal validation knows
the heap's exact ordinal high-water bound, so it allocates one pre-reserved
`(consent dense-set)` and records only certified reachable public compounds.
The set never grows after publication. A failed seal releases it; a successful
seal retains it with the frozen heap so cross-context import can decide in
constant time whether an object is safe to reuse read-only. Identity-table
storage remains reserved for associations that need values, mixed owned and
host namespaces, or lifetimes not representable as one heap-local property
column.

Identity-keyed values belong to `(consent identity-table)`, not to dense
identifier membership or public comparator-configurable hash tables. Owned and
host identities occupy separate namespaces; the latter is the only namespace
that crosses a three-operation host adapter. See
[Fixed-Policy Identity Tables](identity-tables.md) for load, tombstone,
host-hash normalization, lazy growable allocation, node-reusing chained
rehash, no-hash, root, release, and lean-specialization details.
Call-scoped redaction, JSON writing, and helper copying use `(consent
identity-map)` directly because their public language values are not private
`(consent datum)` heap objects. This avoids loading the compound-datum
implementation merely to route every key back to the host namespace. The
memory-key session cache uses the same specialization instead of retaining a
second no-hash alist implementation.

## Verification

`tools/benchmark-private-storage.scm` is the reproducible representation and
lifecycle benchmark used for the 0.18.46 evidence above. Its environment
selectors cover all five storage kinds, four construction shapes, and the
construction, steady, clear, reset, and release analogues without introducing
a timing gate into ordinary tests.

`tests/scheme/consent-growable-vector-test.scm` covers zero and maximum capacity
boundaries, a deterministic capacity/model sweep, no-op transitions, copy
counters, overlap-safe bulk copy and fill, state preservation after failed
operations, reset and release clearing, idempotent release, and stable
representative errors.
`tests/scheme/consent-scratch-arena-test.scm` covers both growth policies,
lazy first-allocation floors, active and idle statistics, cross-arena and stale
marks, escaped owners, exception cleanup, dynamic-wind, continuation re-entry,
and a pre-reserved synthetic collector workload. Worklist and dense-set tests
likewise assert lazy allow-growth capacity, eager pre-reservation, exact
counters, failure atomicity, root clearing, and lifecycle behavior. The
portable plan runs the programs on direct and compiled routes. ERT imports each
internal library independently through the Emacs source-library loader,
proving that both bootstrap surfaces use their portable source implementations.
`tests/scheme/consent-identity-table-test.scm` covers fixed namespaces,
hash-backed probing, allocation-serial burst distribution, forced bounded
compatibility, roots, lifecycle, and counted scale behavior. ERT also proves
that the Emacs bootstrap loads the portable table above only three host
identity primitives.
`tests/scheme/consent-agent-memory-test.scm` retains the consumer equivalence
corpus: bounded arbitrary-key quotient oracles and cyclic-key lifecycle cases
cover both memory-key FIFOs, while overlapping multi-pattern relevance covers
the memory-query breadth-first failure links. Existing additive scale gates
continue to guard partition refinement and text-query construction.
The official SRFI 214 repository provides `implementation/tests.scm`. Consent
pins that file at the manifest's upstream revision and SHA-256 and carries its
111 assertions in
`tests/scheme/stdlib-flexvectors-upstream-test.scm`, adapted only to use the
local library imports, SRFI 64 implementation, and fail-closed runner. The
upstream assertions mention 64 of the 66 exported procedures; they omit
`list->flexvector` and `reverse-list->flexvector`. They also do not exercise
every optional argument, specified error boundary, mutator return contract, or
short-circuit rule.

`tests/scheme/stdlib-flexvectors-test.scm` closes those gaps with 17 registered
cases and 35 assertions for list and sliced conversions, clamping,
multiple-seed unfolds, every mutator return category, append-at-length
`flexvector-set!`, the optional
`flexvector-remove-range!` end, empty and reversed-range errors, shortest-input
parallel iteration, strict short-circuiting, self-aliasing, overlapping edits,
searches, and long inputs. Together, the two portable programs exercise all 66
exports. The exact 66-name manifest export list and all four import aliases are
asserted through the Emacs source loader. Both portable programs run on every
direct and compiled host route selected by the portable test plan.

The portable layer cannot safely force a host `make-vector` out-of-memory
condition or observe garbage-collector reachability. The suite therefore checks
every deterministic pre-allocation failure for state preservation and uses the
unused-slot diagnostics as its root-clearing oracle. A future native allocator
adapter must provide deterministic fault injection for its allocation-failure
normalization path rather than attempting a process-level exhaustion test.
