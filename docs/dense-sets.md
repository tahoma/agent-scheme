# Generation-Stamped Dense Sets and Epoch Marks

`(consent dense-set)` is private bootstrap-safe storage for membership and
small-color state over nonnegative dense integer identifiers. It supports
collector marks, remembered-set membership, graph visitation, and query
generations before optional standard libraries are realized.

It is not the public SRFI 178 bitvector surface. A bitvector represents
publicly observable bits and ordinary mutation. A dense set additionally owns
an epoch, bounded generation wrap, allocation policy, lifetime release,
deterministic work counters, and an explicit private ownership domain.

## Contract

A dense set is constructed with:

- an initial reserved capacity;
- an exclusive maximum identifier capacity;
- a positive maximum generation;
- a positive finite color count;
- either `allow-growth` or `pre-reserved`; and
- a symbolic ownership-domain label.

Identifiers are exact nonnegative integers below maximum capacity. Colors are
exact nonnegative integers below the color count. A one-color set is an
ordinary membership set. A multi-color set can represent a small collector or
algorithm state such as white, gray, and black without retaining the marked
object itself.

The public procedures of this internal library use the `consent-` prefix, but
the manifest marks the library `internal-runtime`. It accepts no comparator,
hash procedure, allocator callback, element callback, or public library
object.

## Representation and root safety

The backing store is one `(consent growable-vector)` whose populated prefix
equals reserved capacity. Each slot contains one exact nonnegative integer:

```text
0                         physically clear
1 + color + generation*C current or stale encoded mark
```

`C` is the immutable color count. Decoding uses quotient and remainder by
`C`. A slot is live only when its decoded generation equals the set's current
generation. All encoded integer widths are bounded by the constructor's
maximum generation and color count.

This representation is deliberately incapable of retaining a marked object.
An old epoch may leave a nonzero integer in a slot, but it cannot leave an
object, handle, pair, vector, callback, or host reference there. The diagnostic
`consent-dense-set-integral-storage?` checks that invariant without exposing
the backing vector.

The integer encoding is a portable semantic choice, not an ABI promise. A
future compiled runtime may pack stamps and colors into fixed-width native
storage when it preserves the same bounds, wrap behavior, accounting, and
failure contract. SRFI 178 storage may be reused only when O(1) epoch changes
and the private lifetime contract remain intact.

## Membership and color operations

`consent-dense-set-member?` checks the addressed slot's generation.
`consent-dense-set-color` returns its current finite color or `#f` when the
identifier is unmarked. Color zero is distinct from `#f`.

`consent-dense-set-mark!` accepts an optional color, defaulting to zero. It
returns the previous current color, or `#f` for a newly marked identifier.
Marking an already-current identifier does not change logical size. Repeating
the same color and changing colors have separate counters.

`consent-dense-set-unmark!` physically writes zero only to the addressed slot.
It returns the prior current color or `#f` when the identifier was already
unmarked. Unmark is useful for pending-work membership and similar structures
whose entries leave the live set before the whole epoch ends.

All successful membership, color, mark, and unmark operations take O(1) work
independent of capacity. The contract assumes arithmetic values bounded by the
configured generation and color limits; callers must not choose limits whose
integer width defeats their runtime profile.

## Logical clear and generation wrap

`consent-dense-set-clear!` normally increments the current generation and sets
logical size to zero. It does not scan, rewrite, or allocate backing slots.
The ordinary clear cost is therefore O(1) independent of current or maximum
capacity.

When current generation already equals maximum generation, the next clear
fills every reserved slot with zero and restarts at generation one. This is one
explicit O(capacity) wrap event. A stale mark cannot become current again
because every slot is cleared before the generation number is reused.

`consent-dense-set-full-clear!` exposes the same physical reset directly for
phase boundaries that require it. Both wrap and explicit full clear increment
`physical-clears` and add reserved capacity to `physical-clear-slots`.
Ordinary clears increment `generation-advances` instead. Tests can therefore
prove that N ordinary clears did not perform N capacity scans.

The initial generation is one. Generation zero is reserved for no live epoch
in the physical encoding and is never reported as current.

## Capacity and allocation policy

`consent-dense-set-reserve!` grows to an exact requested capacity without
changing existing marks. A no-op reserve leaves statistics unchanged. Requests
above maximum capacity fail before mutation.

Under `allow-growth`, marking an identifier beyond current capacity grows
geometrically through `(consent growable-vector)` to address that identifier,
then appends zero slots without further allocation. The statistics distinguish
explicit capacity changes, automatic growths, and copied elements.

Under `pre-reserved`, a mark outside current capacity fails without changing
the set. Collector code reserves before entering a no-allocation phase, then
uses only identifiers within that capacity. Membership and color reads beyond
current capacity but within the configured maximum return false; they do not
grow storage.

Allocation failures are normalized by the growable-vector substrate. New
capacity is published only after allocation succeeds. Slot population after a
successful reserve cannot allocate because the backing vector already owns the
requested slots.

## Ownership domains and lifetime

Each dense set has an immutable symbolic domain such as:

- `collector-mark` or `collector-color`;
- `remembered-set` or `card-table`;
- `query-generation`;
- `writer-metadata`; or
- `graph-traversal`.

The domain is inspectable metadata, not an authority token. Isolation comes
from separate dense-set records and separate backing storage. The label makes
that ownership boundary reviewable in diagnostics and fixtures. A consumer
must not reuse one record for unrelated domains merely because their
identifiers currently have the same numeric range.

Nested algorithms use distinct records. Clearing or releasing an inner query,
writer, or graph set cannot change a surrounding collector epoch. This also
keeps dense-set generations separate from scratch-arena marks, intrusive datum
map headers, writer traversal tokens, and public bitvector contents.

`consent-dense-set-release!` terminally clears and releases the backing
growable vector. It records the number of release-cleared slots, drops reported
capacity to zero, and makes every later operational call fail. Releasing an
already released set is idempotent.

Code that owns control transfer pairs release with `dynamic-wind`. An exception
or continuation escape runs the release thunk. Re-entering a continuation then
observes an inactive record and fails closed before stale storage can be used.
The primitive invokes no user cleanup callback itself.

## Complexity and accounting

| Operation | Bound | Capacity work |
| --- | --- | --- |
| Membership or color read | O(1) | None. |
| Mark or unmark in capacity | O(1) | None. |
| Ordinary clear | O(1) | None. |
| Wrapped or explicit full clear | O(capacity) | One slot write each. |
| Reserve or automatic growth | O(capacity) | Copies old slots once. |
| Terminal release | O(capacity) | Clears and drops storage once. |

The statistics datum records:

- domain, growth policy, active state, size, and capacity bounds;
- generation, maximum generation, and color count;
- high-water identifier use;
- membership tests and color reads;
- mark operations, new marks, recolors, duplicate marks, and unmarks;
- clears, generation advances, physical clears, and physical-clear slots;
- capacity changes, automatic growths, and copied elements; and
- releases and release-clear slots.

The counters are semantic diagnostics, not a timing API. They make allocation
and scanning behavior deterministic across bootstrap hosts.

## Current consumer migration

The memory-key partition refinement in `(agent memory-key)` previously owned
two ad hoc vectors:

- a boolean vector for blocks already pending in the splitter FIFO; and
- a generation vector for states already seen in one predecessor split.

Both are dense integer membership sets with known capacity and no custom value
semantics. They now use separate pre-reserved, one-color dense sets with the
domains `memory-key-block-pending` and `memory-key-refinement-mark`.

Pending membership uses mark and unmark as blocks enter and leave the FIFO.
Predecessor refinement advances the state-mark epoch once per relation instead
of clearing or replacing a state-count vector. The existing arbitrary-key,
cyclic-key, quotient-oracle, and additive-work gates remain the owner of graph
semantic and performance equivalence.

The memory-query automaton still has durable generation fields embedded in its
published node and term records. Migrating those fields would change a durable
representation rather than merely replace private temporary membership. That
work should use this primitive only after the owner record and serialization
boundary are reviewed separately.

## Verification

`tests/scheme/consent-dense-set-test.scm` is canonical for membership, colors,
sparse and dense identifiers, bounded growth, generation accounting, forced
wrap, explicit full clear, malformed inputs, ownership-domain isolation,
integer-only storage, exception release, and continuation re-entry. Its model
sweep compares every identifier with an independent fixed-vector oracle.

The portable test plan runs that program on direct and compiled hosts.
`tests/consent-library-test.el` independently imports the internal library
through the Emacs source loader, proving both bootstraps execute the same
portable implementation. The memory-key consumer retains its existing
equivalence corpus and additive work checks.
