# Bootstrap-Safe Runtime Storage

**Issue:** #968

**Roadmap version:** 0.18.39

**Status:** Implemented

## Summary

`(consent runtime-storage)` is the private, portable storage substrate for
allocation-sensitive runtime and graph algorithms. It supplies bounded
growable vectors and reusable scratch arenas without importing a public SRFI,
calling user code, or depending on an initialized standard-library shelf.

The library imports only `(scheme base)`. Both the Emacs bootstrap source
loader and direct or compiled R7RS routes execute the same Scheme source. A
future native runtime may accelerate the backing storage, but it must preserve
the bounds, clearing, counters, ownership, and failure behavior described here.

## Growable Vectors

`consent-make-growable-vector` takes an initial capacity and a maximum
capacity. Both are exact nonnegative integers, and the initial capacity must
not exceed the maximum. The maximum is permanent for that storage object.

The populated prefix is separate from reserved capacity:

- append returns the new element's zero-based index;
- indexed ref and set accept only populated indexes;
- reserve allocates an exact requested capacity when it is larger;
- grow doubles the current capacity, or uses the requested minimum when that
  is larger, without crossing the configured maximum;
- snapshot returns a fresh fixed vector containing only the populated prefix;
- reset clears every populated slot to `#f` and retains the capacity; and
- release clears every populated slot, drops the backing vector, and makes the
  growable vector permanently inactive.

Append uses geometric growth. For a vector beginning with one slot, appending
`n` elements copies fewer than `2n` existing elements across all growths.
`consent-growable-vector-stats` exposes logical length, reserved capacity,
maximum capacity, high-water length, growth count, copied-element count, reset
count, and released state as Scheme-readable data.

`consent-growable-vector-unused-slots-cleared?` is a private diagnostic for the
garbage-collector root invariant. It scans reserved slots outside the logical
prefix and confirms that none retains a stale value.

## Scratch Arenas

A scratch arena owns one growable vector and issues at most one active owner at
a time. `consent-scratch-arena-acquire!` requires a symbolic phase and returns
a fresh owner lifetime. Every append, ref, set, mark, and reset operation takes
that owner. Release clears the complete logical prefix before the arena can
issue another owner.

Marks are ownership-stamped exact integers. A mark from a released lifetime is
rejected even if a later owner has a compatible logical length. Reset clears
the suffix back to the marked length before publishing the shorter prefix.

Arena statistics distinguish:

- current logical elements and reserved capacity;
- configured maximum capacity and growth policy;
- high-water logical usage across all lifetimes;
- acquisitions, mark resets, and owner releases; and
- backing-storage growths and copied elements.

The arena has two growth policies:

- `allow-growth` permits active append to allocate geometrically, bounded by
  the configured maximum. It is suitable only when allocation from the
  current runtime heap is allowed or the backing store is an external adapter.
- `pre-reserved` forbids growth while an owner is active. Reserve the arena
  while it is idle, before entering a collector or no-allocation phase. An
  exhausted owner fails closed instead of recursively allocating from the heap
  being collected.

Owner acquisition creates its lifetime token, so a collector must acquire the
owner before entering the portion of a phase in which ordinary allocation is
forbidden. Marks do not allocate compound storage. A compiled adapter may make
the owner token and exact marks immediate values, but cannot weaken their
lifetime checks.

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

## Layering and Consumers

The memory-key canonicalizer now uses this library for its dense label, edge,
and descriptor vectors. Its graph semantics and asymptotic gates remain owned
by `(agent memory-key)`; only the compatible storage machinery moved.

Issue #210 continues to own SRFI 214 names, validation, aliases, documentation,
and public flexvector semantics. It may reuse the private storage where those
semantics agree, but it must not expose collector phase, reserve, reset,
release, maximum-capacity, or allocation-policy details as SRFI behavior.

The baseline and incremental collectors in #335 and #966 consume
`pre-reserved` arenas. They must reserve and acquire outside the no-allocation
trace section and treat capacity exhaustion as a Scheme-readable collection
failure, not as permission to allocate from the heap under collection.

## Verification

`tests/scheme/consent-runtime-storage-test.scm` covers capacity boundaries,
copy counters, reset and release clearing, malformed operations, both arena
growth policies, stale marks and owners, exception cleanup, dynamic-wind,
continuation re-entry, and a pre-reserved synthetic collector workload. The
portable test plan runs that program on direct and compiled routes. ERT also
imports the internal library through the Emacs source-library loader, proving
that the bootstrap uses the same portable implementation.
