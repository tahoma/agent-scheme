<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Tahoma Toelkes -->

# Persistent AVL Trees

Tahoma Toelkes

## Status

This document is the user specification for Consent Scheme's `(data avl-tree)`
library.  It is maintained in a SRFI-like form, but it is not a Scheme Request
for Implementation and has no standing in the SRFI process.

## Abstract

This document specifies persistent finite maps implemented as height-balanced
binary search trees.  Keys are interpreted by a caller-supplied strict ordering
predicate.  Lookup, functional update, ordered traversal, extrema, neighboring
key queries, stored-key retrieval, invariant validation, range splitting,
catenation, monotone mapping, and association-list conversion are provided
without exposing node representation.

The library is imported as:

```scheme
(import (data avl-tree))
```

## Rationale

Association lists are convenient but require linear lookup.  Hash tables offer
expected constant-time access, but do not provide key order and are normally
mutable.  A persistent balanced search tree supplies logarithmic lookup and
update, deterministic ordered traversal, and inexpensive snapshots that share
unchanged structure.

The API deliberately accepts an ordering predicate instead of requiring a
comparator object.  This keeps the data structure dependent only on R7RS-small
facilities and makes it useful beneath richer interfaces.  In particular,
`(data mapping avl)` adapts these trees to the ordered Mapping interface of SRFI
146 while leaving `(stdlib mapping)` free to retain its standard red-black
provider.

## Specification

### Terminology and invariants

An *AVL tree* is a finite set of key/value associations and has a strict key
ordering procedure.  AVL trees are a new type, disjoint from all other Scheme
types.  The effects of record inspection or inheritance are unspecified.

For an ordering procedure `ordering`, keys `a` and `b` are *equivalent* when
both `(ordering a b)` and `(ordering b a)` return false.  A tree contains at
most one association from each equivalence class.  The ordering must be a
strict total order over every key supplied to an operation on that tree.

It is an error to mutate a stored key in a way that changes its ordering with
respect to another stored key.  An implementation may retain the first key
object supplied for an equivalence class even when a later operation replaces
its value.

Every operation whose name lacks a trailing `!` is functional: it does not
mutate an AVL tree supplied as an argument.  An implementation may return an
existing tree when the requested result is unchanged.  Trees derived from a
common tree may share arbitrary immutable internal structure.

Unless stated otherwise, passing an object of the wrong type or violating a
procedure precondition is an error.

### Constructors and predicates

```scheme
(make-avl-tree ordering) -> avl-tree
```

Returns an empty AVL tree whose keys are interpreted by the procedure
`ordering`.

```scheme
(avl-tree? object) -> boolean
```

Returns true if `object` is an AVL tree and false otherwise.

```scheme
(avl-tree-valid? object) -> boolean
```

Returns true if `object` is an AVL tree whose ordering, cached heights, balance
factors, and association count satisfy every AVL invariant, and false
otherwise.  This diagnostic does not expose the tree's node representation.

```scheme
(avl-tree-ordering tree) -> procedure
```

Returns the ordering procedure supplied when `tree` was constructed.

```scheme
(avl-tree-empty? tree) -> boolean
(avl-tree-size tree) -> exact-non-negative-integer
```

Return whether `tree` has no associations and the number of associations in
`tree`, respectively.

### Lookup

```scheme
(avl-tree-contains? tree key) -> boolean
```

Returns true if `tree` contains an association whose key is equivalent to
`key`.

```scheme
(avl-tree-ref tree key [failure [success]]) -> value
```

If an association for `key` exists, calls `success` on its value and returns
the values returned by `success`.  The default `success` procedure is the
identity procedure.  If no association exists, calls the zero-argument
`failure` procedure and returns its values.  Omitting `failure` supplies a
procedure that raises an error.

```scheme
(avl-tree-ref/key tree key failure success) -> value
```

If an association equivalent to `key` exists, calls `success` on the stored key
object and its value and returns the values returned by `success`.  The stored
key can differ from `key` while remaining equivalent under the tree's ordering.
If no association exists, calls the zero-argument `failure` procedure and
returns its values.  Both handlers are required.

```scheme
(avl-tree-ref/default tree key default) -> value
```

Returns the associated value when `key` is present and `default` otherwise.
This procedure distinguishes an absent key from a key associated with `#f`.

### Functional update

```scheme
(avl-tree-adjoin tree key value) -> avl-tree
```

Returns `tree` unchanged when an equivalent key is already present.  Otherwise
returns a tree extended with the association `key` to `value`.

```scheme
(avl-tree-set tree key value) -> avl-tree
```

Returns a tree in which `key` is associated with `value`, adding the
association when absent and replacing the value when present.  Replacement
retains the key object already stored for the equivalence class.

```scheme
(avl-tree-replace tree key value) -> avl-tree
```

Returns a tree with the value for `key` replaced when an equivalent key is
present, or returns `tree` unchanged when it is absent.

```scheme
(avl-tree-delete tree key) -> avl-tree
```

Returns a tree without the association for `key`, or returns `tree` unchanged
when no equivalent key is present.

### Ordered traversal

```scheme
(avl-tree-for-each procedure tree) -> unspecified
```

Calls `procedure` as `(procedure key value)` once for each association, from
the least key to the greatest key.  The calls occur in sequence.

```scheme
(avl-tree-fold procedure seed tree) -> value
(avl-tree-fold/reverse procedure seed tree) -> value
```

Calls `procedure` as `(procedure key value accumulator)` for each association.
`avl-tree-fold` visits keys from least to greatest;
`avl-tree-fold/reverse` visits them from greatest to least.  In either case,
the accumulator begins as `seed`, and the value returned by one call becomes
the accumulator passed to the next call.

### Extrema and neighbors

```scheme
(avl-tree-min tree [failure]) -> key value
(avl-tree-max tree [failure]) -> key value
```

Return the least or greatest key and its value as two values.  If `tree` is
empty, the zero-argument `failure` procedure is called and its values are
returned.  Omitting `failure` supplies a procedure that raises an error.

```scheme
(avl-tree-key-predecessor tree key [failure]) -> predecessor-key value
(avl-tree-key-successor tree key [failure]) -> successor-key value
```

Return, as two values, the association with the greatest key strictly less
than `key`, or the association with the least key strictly greater than `key`.
The boundary key need not be present.  When no such association exists, the
optional zero-argument `failure` procedure is handled as for `avl-tree-min`.

### Partition and combination

```scheme
(avl-tree-split tree boundary)
    -> less less-or-equal equivalent greater-or-equal greater
```

Returns five AVL trees, all using `tree`'s ordering.  They contain,
respectively, associations whose keys are strictly less than `boundary`, less
than or equivalent to it, equivalent to it, greater than or equivalent to it,
and strictly greater than it.  The `equivalent` result is empty or has one
association.

```scheme
(avl-tree-catenate left key value right) -> avl-tree
```

Returns an AVL tree using `left`'s ordering and containing the associations of
`left`, the association `key` to `value`, and the associations of `right`.
The trees must use compatible orderings over their combined key domain.
Associations from `right` take precedence over equivalent associations from
`left` or the pivot association.

```scheme
(avl-tree-map/monotone procedure tree) -> avl-tree
```

Calls `procedure` as `(procedure key value)` in ascending key order.
`procedure` must return a new key and value as two values, and the returned keys
must be strictly increasing under `tree`'s ordering.  The result uses the same
ordering procedure and contains the returned associations.

### Conversion

```scheme
(avl-tree->alist tree) -> alist
```

Returns a newly allocated association list in ascending key order.  Each
association is a pair whose car is a stored key and whose cdr is its value.

```scheme
(alist->avl-tree ordering alist) -> avl-tree
```

Returns a tree populated by setting each association in `alist` from left to
right.  For equivalent keys, the first key object is retained and the last
value wins.  Every element of `alist` must be an association pair.

## Examples

Persistent updates leave earlier snapshots available:

```scheme
(define empty (make-avl-tree string<?))
(define first (avl-tree-set empty "beta" 2))
(define second (avl-tree-set first "alpha" 1))

(avl-tree-size first)                 ; => 1
(avl-tree->alist second)              ; => (("alpha" . 1) ("beta" . 2))
(avl-tree-ref/default second "gamma" #f) ; => #f
```

Range and neighboring-key operations do not require a matching boundary:

```scheme
(define numbers
  (alist->avl-tree < '((10 . ten) (20 . twenty) (30 . thirty))))

(call-with-values
    (lambda () (avl-tree-key-predecessor numbers 25))
  list)                               ; => (20 twenty)

(call-with-values
    (lambda () (avl-tree-split numbers 20))
  (lambda (lt le eq ge gt)
    (map avl-tree-size (list lt le eq ge gt))))
                                    ; => (1 2 1 2 1)
```

The optional SRFI 146 provider constructs ordinary Mapping values backed by an
AVL tree:

```scheme
(import (scheme base)
        (stdlib comparator)
        (stdlib mapping)
        (data mapping avl))

(define table
  (avl-mapping (make-default-comparator) 'alpha 1 'beta 2))
(mapping-ref table 'beta)             ; => 2
```

## Complexity

For a tree with `n` associations, size and emptiness are constant time.
Lookup, stored-key lookup, adjoin, set, replace, delete, extrema, predecessor,
and successor take `O(log n)` ordering comparisons.  Invariant validation,
traversal, and association-list conversion take `O(n)` procedure calls.
Persistent updates allocate `O(log n)` new tree nodes while retaining
unaffected structure.

The current reference implementation constructs each result of split through
functional insertion, catenates by inserting the pivot and every right-tree
association, and implements monotone mapping through insertion.  Consequently,
those operations have `O(n log n)`, `O(m log(n + m))`, and `O(n log n)` upper
bounds respectively, where `m` is the size of the right tree.  These bounds do
not prevent another conforming implementation from using the usual linear or
logarithmic AVL join and build algorithms.

## Implementation notes

Consent Scheme represents each node with cached height and rebuilds only the
search path during update.  Single and double rotations restore the AVL
balance invariant.  Node representation remains private; the public invariant
predicate reports structural validity without exposing nodes or accessors.

The portable conformance suite exercises all four insertion rotations,
leaf/one-child/two-child deletion, invariants after every update in deterministic
stress sequences, snapshot persistence, equivalent-key retention, handler
contracts, traversal, extrema, neighbors, split, catenation, mapping, and
conversion across the supported R7RS hosts.

## References

- G. M. Adelson-Velsky and E. M. Landis, "An algorithm for the organization of
  information," *Soviet Mathematics Doklady* 3, 1962, pp. 1259-1263.
- Chris Okasaki, *Purely Functional Data Structures*, Cambridge University
  Press, 1998.
- [SRFI 146: Mappings](https://srfi.schemers.org/srfi-146/) defines the ordered
  Mapping interface used by `(data mapping avl)`.

## Copyright

Copyright 2026 Tahoma Toelkes.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this document except in compliance with the License.  You may obtain a copy of
the License at <https://www.apache.org/licenses/LICENSE-2.0>.

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied.  See the License for the
specific language governing permissions and limitations under the License.
