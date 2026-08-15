<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Tahoma Toelkes -->

# Transient Maps over Persistent Containers

Tahoma Toelkes

## Status

This document is the user specification for Consent Scheme's
`(data transient-map)` library.  It is maintained in a SRFI-like form, but it is
not a Scheme Request for Implementation and has no standing in the SRFI
process.

## Abstract

This document specifies a mutable map overlay for an arbitrary persistent map
representation.  Recent reads and staged writes occupy a hash-indexed transient
layer.  A caller-supplied adapter performs lookup, functional set, and
functional deletion on the persistent base.  The overlay may be materialized
as a new persistent value or reset to another persistent snapshot.

The library is imported as:

```scheme
(import (data transient-map))
```

## Rationale

Persistent ordered trees provide deterministic snapshots and structural
sharing, but inserting many identifiers one at a time pays a logarithmic tree
cost for every insertion.  Mutable hash tables provide fast construction, but
do not by themselves preserve an immutable checkpoint or permit cheap branches
from a shared root.

A transient map combines the two roles without fixing either one to a concrete
representation.  Reads and mutations are staged in a mutable hash overlay.
Materialization applies only staged mutations through a functional adapter and
installs the resulting persistent value as the next base.  This is useful for
symbol interners, compiler tables, transactional indexes, and other workloads
that alternate between mutation-heavy phases and persistent checkpoints.

The abstraction is intentionally a container adapter rather than an AVL-tree
extension.  A base can be an AVL tree, a red-black tree, a HAMT, an association
list, or another value that implements the specified callback protocol.

## Specification

### Terminology and mutability

A *transient map* is a mutable handle containing a persistent *base* and a
hash-indexed *overlay*.  The overlay may contain cached reads, staged sets, and
staged deletions.  Transient maps are a new type, disjoint from all other
Scheme types.  The effects of record inspection or inheritance are
unspecified.

Procedures whose names end in `!` mutate the transient-map handle.  They do not
require or permit mutation of the persistent base.  A transient map is not
safe for unsynchronized concurrent mutation.

Keys `a` and `b` are equivalent when `(equivalent a b)` returns true.  The
`equivalent` procedure must be an equivalence relation over every key used with
the map.  Equivalent keys must produce numerically equal results from `hash`.
It is an error to mutate a retained key in a way that changes either its hash
or equivalence class.

Unless stated otherwise, passing an object of the wrong type or violating a
procedure precondition is an error.

### Persistent-container adapter protocol

```scheme
(base-ref base key failure success) -> value
(base-set base key value) -> new-base
(base-delete base key) -> new-base
```

`base-ref` searches `base` for `key`.  When present, it calls `success` with
the stored value and returns the values returned by `success`.  When absent, it
calls the zero-argument `failure` procedure and returns its values.

`base-set` functionally returns a persistent base in which `key` is associated
with `value`.  `base-delete` functionally returns a persistent base without an
association for `key`.  Neither procedure may mutate the base supplied to it.

Applying sets and deletions for distinct keys in any order must produce
equivalent persistent maps.  The transient map does not specify the order in
which staged mutations are applied during materialization.

```scheme
(hash key) -> exact-integer
(equivalent left right) -> boolean
(key-copy key) -> stable-key
```

`hash` may return a negative or non-negative exact integer.  `key-copy` is
optional and defaults to the identity procedure.  When supplied, it is called
before a key is retained in the overlay, including when a successful base read
is cached.  The returned key must remain equivalent to the input key and must
have the same hash.  A copier such as `string-copy` lets the map own mutable
caller-supplied keys.

### Constructor and predicate

```scheme
(make-transient-map base hash equivalent
                    base-ref base-set base-delete [key-copy])
    -> transient-map
```

Returns a fresh transient map with `base` as its persistent value and an empty
overlay.  The remaining arguments implement the protocols above.  The
constructor places no type restriction on `base`.

```scheme
(transient-map? object) -> boolean
```

Returns true if `object` is a transient map and false otherwise.

### Lookup

```scheme
(transient-map-ref transient key [failure [success]]) -> value
```

Searches the overlay before the persistent base.  A staged deletion behaves as
an absent key.  A staged set or cached read behaves as a present key.  If the
overlay has no entry, the persistent adapter is consulted; a successful base
read is cached in the overlay.

For a present key, `success` is called with the stored value and its values are
returned.  The default `success` procedure is the identity procedure.  For an
absent key, the zero-argument `failure` procedure is called and its values are
returned.  Omitting `failure` supplies a procedure that raises an error.

A lookup may mutate the overlay by caching a successful base read, but does not
change the map's persistent meaning and does not increase its pending count.

```scheme
(transient-map-ref/default transient key default) -> value
```

Returns the associated value when `key` is present and `default` otherwise.
This procedure distinguishes an absent key from a key associated with `#f`.

```scheme
(transient-map-contains? transient key) -> boolean
```

Returns true if `key` is present in the effective map.  Like
`transient-map-ref`, it may cache a successful persistent-base read.

### Staging mutations

```scheme
(transient-map-set! transient key value) -> transient
```

Stages an association from `key` to `value`, replacing any cached read, staged
set, or staged deletion for an equivalent key.  The effective map reflects the
new value immediately.  The returned object is `transient`.

```scheme
(transient-map-delete! transient key) -> transient
```

Stages deletion of `key`, replacing any cached read, staged set, or staged
deletion for an equivalent key.  The effective map treats `key` as absent
immediately, whether or not it exists in the persistent base.  The returned
object is `transient`.

```scheme
(transient-map-pending-count transient) -> exact-non-negative-integer
```

Returns the number of distinct overlay equivalence classes containing a staged
set or staged deletion.  Cached reads are excluded.  Repeated sets and
deletions of the same equivalence class do not increase the count.

### Materialization and reset

```scheme
(transient-map-persistent! transient) -> persistent-base
```

Applies every staged set and deletion to the persistent base through
`base-set` and `base-delete`, installs the result as the new base, clears all
overlay entries including cached reads, sets the pending count to zero, and
returns the installed persistent base.

Calling this procedure when there are no staged mutations is permitted.  The
returned base is then equivalent to the existing base, and cached reads are
still cleared.  If a functional adapter operation raises an exception before
materialization completes, the transient map retains its previously installed
base and overlay.

```scheme
(transient-map-reset! transient base) -> transient
```

Replaces the installed persistent base with `base`, discards every cached read
and staged mutation, sets the pending count to zero, and returns `transient`.
The new base must be accepted by the adapter procedures supplied at
construction time.

## Examples

An AVL tree can supply the persistent-container protocol directly:

```scheme
(import (scheme base)
        (data avl-tree)
        (data transient-map))

(define overlay
  (make-transient-map
   (make-avl-tree string<?)
   (lambda (text)
     (let loop ((index 0) (hash 0))
       (if (= index (string-length text))
           hash
           (loop (+ index 1)
                 (+ (* hash 33)
                    (char->integer (string-ref text index)))))))
   string=?
   avl-tree-ref
   avl-tree-set
   avl-tree-delete
   string-copy))

(transient-map-set! overlay "alpha" 1)
(transient-map-set! overlay "beta" #f)
(transient-map-contains? overlay "beta") ; => #t
(transient-map-pending-count overlay)     ; => 2

(define checkpoint (transient-map-persistent! overlay))
(avl-tree->alist checkpoint)              ; => (("alpha" . 1)
                                             ;     ("beta" . #f))
(transient-map-pending-count overlay)     ; => 0
```

A simple association-list adapter demonstrates that the base need not be a
tree:

```scheme
(define (alist-ref base key failure success)
  (let ((entry (assv key base)))
    (if entry (success (cdr entry)) (failure))))

(define (alist-set base key value)
  (cons (cons key value)
        (let loop ((rest base))
          (cond ((null? rest) '())
                ((eqv? key (caar rest)) (cdr rest))
                (else (cons (car rest) (loop (cdr rest))))))))

(define (alist-delete base key)
  (let loop ((rest base))
    (cond ((null? rest) '())
          ((eqv? key (caar rest)) (cdr rest))
          (else (cons (car rest) (loop (cdr rest)))))))

(define small
  (make-transient-map '() (lambda (key) key) eqv?
                      alist-ref alist-set alist-delete))
```

Reset makes branching from a persistent checkpoint explicit:

```scheme
(transient-map-set! overlay "gamma" 3)
(transient-map-reset! overlay checkpoint)
(transient-map-contains? overlay "gamma") ; => #f
```

## Complexity

Let `p` be the number of entries retained in the overlay.  With a suitable hash
function, lookup, contains, set, and delete take expected `O(1)` overlay time.
A cache miss additionally pays the cost of `base-ref`.  The overlay may resize
and rehash, so an individual mutation can take `O(p)` time while a sequence of
mutations has expected amortized constant overlay cost per operation.

Materialization scans the overlay and invokes one persistent adapter operation
for each staged set or deletion.  Its cost is `O(p)` plus the costs of those
adapter calls, plus any unused overlay capacity that must be inspected.  Reset
clears the allocated overlay in time proportional to its capacity.  The library
does not specify an initial capacity, load factor, probing strategy, or growth
schedule.

## Implementation notes

Consent Scheme uses an open-addressed vector for the overlay and distinguishes
cached, set, and deleted entries.  The persistent adapter is stored in each
transient handle, so no global registry or backend type test is required.

The portable conformance suite exercises lookup and handler behavior, stored
`#f`, pending-count transitions, deletion tombstones, repeated materialization,
reset, key copying, exact hash collisions, resizing, an association-list
backend, adapter and hash contract failures, and a model-driven stress sequence
across the supported R7RS hosts.

## References

- [SRFI 125: Intermediate hash tables](https://srfi.schemers.org/srfi-125/)
  specifies a general mutable hash-table interface and motivates the expected
  lookup behavior of the transient overlay.
- [SRFI 146: Mappings](https://srfi.schemers.org/srfi-146/) specifies persistent
  mapping operations that can be adapted as a transient map's base protocol.
- Chris Okasaki, *Purely Functional Data Structures*, Cambridge University
  Press, 1998, describes the persistent-container techniques that make shared
  bases and inexpensive snapshots practical.
- The project bibliography's
  [persistent hash-mapping references](../../../docs/references.md#persistent-hash-mappings)
  cover HAMT base representations that can implement this adapter without
  changing the transient-map contract.

## Copyright

Copyright 2026 Tahoma Toelkes.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this document except in compliance with the License.  You may obtain a copy of
the License at <https://www.apache.org/licenses/LICENSE-2.0>.

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied.  See the License for the
specific language governing permissions and limitations under the License.
