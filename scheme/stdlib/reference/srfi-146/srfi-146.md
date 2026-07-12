<!-- SPDX-License-Identifier: MIT -->

<!-- SPDX-FileCopyrightText: SRFI document authors -->

# [<img src="https://srfi.schemers.org/srfi-logo.svg" class="srfi-logo" alt="SRFI surfboard logo" />](https://srfi.schemers.org/)146: Mappings

Arthur A. Gleckler, Marc Nieper-Wißkirchen

## Status

This SRFI is currently in *final* status. Here is [an explanation](https://srfi.schemers.org/srfi-process.html) of each status that a SRFI can hold. To provide input on this SRFI, please send email to [`srfi-146@`<span class="antispam">`nospam`</span>`srfi.schemers.org`](mailto:srfi+minus+146+at+srfi+dotschemers+dot+org). To subscribe to the list, follow [these instructions](http://srfi.schemers.org/srfi-list-subscribe.html). You can access previous messages via the mailing list [archive](https://srfi-email.schemers.org/srfi-146).

- Received: 2016-12-18
- Draft #1 published: 2016-12-18
- Draft #2 published: 2016-12-20
- Draft #3 published: 2016-12-27
- Draft #4 published: 2017-01-03
- Draft #5 published: 2017-01-04
- Draft #6 published: 2017-05-02
- Draft #7 published: 2017-07-01
- Draft #8 published: 2017-07-02
- Draft #9 published: 2017-07-03
- Draft #10 published: 2017-07-12
- Draft #11 published: 2017-07-28
- Draft #12 published: 2018-04-11
- Draft #13 published: 2018-05-19
- Finalized: 2018-05-24
- Revised to fix errata:
  - 2018-07-03 (Fixed wording error, a simple miscount.)
  - 2018-07-03 ([Fixed previous fix](#errata-2).)
  - 2025-06-15 (Fixed [example of `mapping-map`](#errata-3).)
- <span id="pfn1">**Post-finalization note added on 2021-06-08**: At the request of Marc Nieper-Wißkirchen, [the description of `mapping-comparator` below](#pfn1-change) has been updated.</span>

## Abstract

*Mappings* are finite sets of associations, where each association is a pair consisting of a key and an arbitrary Scheme value. The keys are elements of a suitable domain. Each mapping holds no more than one association with the same key. The fundamental mapping operation is retrieving the value of an association stored in the mapping when the key is given.

## Rationale

Like sets and bags, mappings represent a fundamental data type. Currently, a Scheme programmer has quite a few means to implement this data type: The base library has some support for association lists, which are lightweight data structures that can function as mappings. More efficient data structures are supported by SRFI 125, namely hash tables. Finally, the set data structure of SRFI 113 using suitable comparators can be used to model mappings. However, all three means have individual short-comings when it comes to mappings:

Most operations on association lists are of running time O(n) and thus not very efficient, and association lists do not implement the restriction that keys have to be unique in mappings.

While the hash table model of SRFI 125 implements proper mappings, it makes very strict assumptions on how these mappings have to be implemented. In particular, these requirements make purely functional mappings based on SRFI 125 rather inefficient.

On the other hand, SRFI 113 has an interface that allows implementations to implement purely functional mappings efficiently, while allowing even more efficient mutable data structures when immutability is not needed. However, although one can use SRFI 113 to implement sets of associations, SRFI 113 does not export any procedures that explicitly deal with sets of associations.

One can view the interface proposed in this SRFI as the mapping analogue of the set interface of SRFI 113. The choices of names in this SRFI are drawn from SRFI 113, SRFI 125, and general Scheme conventions.

Multi-mappings (*i.e.* general relations) are not covered by this SRFI. They are left to a future SRFI should they prove to be essential.

Marc Nieper-Wißkirchen is the author and shepherd of this SRFI. Arthur Gleckler implemented the HAMT (Hash Array Mapped Tries) data structure on which the sample implementation of `hashmap`s is based.

## Specification

Mappings form a new type as if created by `define-record-type`. The effect of using record-type inspection or inheritance for the mapping type is unspecified.

The two mapping types as exported from `(srfi 146)` and `(srfi 146 hash)` (see below) are mutually disjoint.

This specification uses the notion of equality of comparators. The exact equality predicate is left implementation-dependent but is always at least as fine as `equal?` (and not finer than `eq?`).

It is an error for any procedure defined in this SRFI to be invoked on mappings with distinct comparators, except if noted otherwise.

It is an error to mutate any key while it is contained in an association in a mapping.

It is an error to add any association to a mapping whose key does not satisfy the type test predicate of the comparator.

It is an error to apply any procedures defined in this SRFI whose names end in `!` to a mapping while iterating over it.

When part of an R7RS implementation, the library `(srfi 146)` should export exactly those identifiers that are described in this specification with the appropriate bindings. Should this SRFI become an essential part of a future Scheme system based on R7RS (*e.g.* R7RS-large), the library's name would become `(scheme mapping)`.

### Linear update

The procedures of this SRFI, like those of SRFI 113, by default, are "pure functional" — they do not alter their parameters. However, this SRFI also defines "linear-update" procedures, all of whose names end in `!`. They have hybrid pure-functional/side-effecting semantics: they are allowed, but not required, to side-effect one of their parameters in order to construct their result. An implementation may legally implement these procedures as pure, side-effect-free functions, or it may implement them using side effects, depending upon the details of what is the most efficient or simple to implement in terms of the underlying representation.

It is an error to reference a (mapping) parameter after a linear-update procedure has been invoked. For example, this is not guaranteed to work:

```
  (let* ((mapping1
          (mapping (make-default-comparator) 'a 1 'b 2 'c 3)) ; mapping1 = {a↦1,b↦2,c↦3}.
         (mapping2
          (mapping-set! mapping1 'd 4))) ; mapping2 = {a↦1,b↦2,c↦3,d↦4}
    mapping1) ; mapping1 = {a↦1,b↦2,c↦3} or mapping1 = {a↦1,b↦2,c↦3;d↦4} ???
```

However, this is well-defined:

```
  (let ((mapping1 (mapping (make-default-comparator) 'a 1 'b 2 'c 3)))
    (mapping-set! mapping1 'd 4)) ; ⇒ {a↦1,b↦2,c↦3;d↦4}
```

So clients of these procedures write in a functional style, but must additionally be sure that, when the procedure is called, there are no other live pointers to the potentially-modified mapping (hence the term "linear update").

There are two benefits to this convention:

- Implementations are free to provide the most efficient possible implementation, either functional or side-effecting.

- Programmers may nonetheless continue to assume that mappings are purely functional data structures: they may be reliably shared without needing to be copied, uniquified, and so forth (as long as the mapping in question is not an argument of a "linear-update" procedure).

In practice, these procedures are most useful for efficiently constructing mappings in a side-effecting manner, in some limited local context, before passing the mapping outside the local construction scope to be used in a functional manner.

Scheme provides no assistance in checking the linearity of the potentially side-effected parameters passed to these functions — there's no linear type checker or run-time mechanism for detecting violations.

Note that if an implementation uses no side effects at all, it is allowed to return existing mappings rather than newly allocated ones, even where this SRFI explicitly says otherwise. For example, `mapping-copy` could be a no-op.

### Comparator restrictions

The library `(srfi 146)` described in this SRFI requires comparators to provide an ordering predicate. Any implementation shall also provide the library `(srfi 146 hash)` which implements essentially the same interface (see below) as `(srfi 146)` but requires comparators to provide a hash function instead of an ordering predicate, unless the equality predicate of the comparator is `eq?`, `eqv?`, `equal?`, `string=?`, or `string-ci=?`.

The library `(srfi 146 hash)` exports exactly the same identifiers (up to a simple prefix-replacing textual substitution as described in the next paragraph), except for those bound to locations which make no sense when an ordering predicate is absent (e.g. `mapping-split`). Should `(srfi 146)` once become known as `(scheme mapping)`, it is recommended that the library `(srfi 146 hash)` receives the alternative name `(scheme hashmap)`.

To make it possible for a program to easily import `(srfi 146)` and `(srfi 146 hash)` at the same time, the prefix `mapping` that prefixes the identifiers in `(srfi 146)` is substituted by `hashmap` in `(srfi 146 hash)`. For example, `mapping` becomes `hashmap`, `mapping?` becomes `hashmap?`, and `mapping-ref` becomes `hashmap-ref`. `comparator?` remains unchanged. For simplicity, the rest of this SRFI refers to the identifiers by their names in `(srfi 146)`.

### Index

- [Constructors](#Constructors): `mapping`, `mapping-unfold`, `mapping/ordered`, `mapping-unfold/ordered`

- [Predicates](#Predicates): `mapping?`, `mapping-contains?`, `mapping-empty?`, `mapping-disjoint?`

- [Accessors](#Accessors): `mapping-ref`, `mapping-ref/default`, `mapping-key-comparator`

- [Updaters](#Updaters): `mapping-adjoin`, `mapping-adjoin!`, `mapping-set`, `mapping-set!`, `mapping-replace`, `mapping-replace!`, `mapping-delete`, `mapping-delete!`, `mapping-delete-all`, `mapping-delete-all!`, `mapping-intern`, `mapping-intern!`, `mapping-update`, `mapping-update!`, `mapping-update/default`, `mapping-update!/default`, `mapping-pop`, `mapping-pop!`, `mapping-search`, `mapping-search!`

- [The whole mapping](#Thewholemapping): `mapping-size`, `mapping-find`, `mapping-count`, `mapping-any?`, `mapping-every?`, `mapping-keys`, `mapping-values`, `mapping-entries`

- [Mapping and folding](#Mappingandfolding): `mapping-map`, `mapping-map->list`, `mapping-for-each`, `mapping-fold`, `mapping-filter`, `mapping-filter!`, `mapping-remove`, `mapping-remove!`, `mapping-partition`, `mapping-partition!`

- [Copying and conversion](#Copyingandconversion): `mapping-copy`, `mapping->alist`, `alist->mapping`, `alist->mapping!`

- [Submappings](#Submappings): `mapping=?`, `mapping<?`, `mapping>?`, `mapping<=?`, `mapping>=?`

- [Set theory operations](#Settheoryoperations): `mapping-union`, `mapping-intersection`, `mapping-difference`, `mapping-xor`, `mapping-union!`, `mapping-intersection!`, `mapping-difference!`, `mapping-xor!`

- [Additional procedures for mappings with ordered keys](#Additionalproceduresformappingswithorderedkeys): `mapping-min-key`, `mapping-max-key`, `mapping-min-value`. `mapping-max-value`, `mapping-key-predecessor`, `mapping-key-successor`, `mapping-range=`, `mapping-range<`, `mapping-range>`, `mapping-range<=`, `mapping-range>=`, `mapping-range=!`, `mapping-range<!`, `mapping-range>!`, `mapping-range<=!`, `mapping-range>=!`, `mapping-split`, `mapping-catenate`, `mapping-catenate!`, `mapping-map/monotone`, `mapping-map/monotone!`, `mapping-fold/reverse`

- [Comparators](#Comparators): `comparator?`, `mapping-comparator`, `make-mapping-comparator`

## Constructors

`(mapping `*`comparator`*` `*`arg`*` ...)`

Returns a newly allocated mapping. The *comparator* argument is a [SRFI 128](https://srfi.schemers.org/srfi-128/srfi-128.html) comparator, which is used to control and distinguish the keys of the mapping. The \*`arg`\*s alternate between keys and values and are used to initialize the mapping. In particular, the number of \*`arg`\*s has to be even. Earlier associations with equal keys take precedence over later arguments.

`(mapping-unfold `*`stop?`*` `*`mapper`*` `*`successor`*` `*`seed`*` `*`comparator`*`)`

Create a newly allocated mapping as if by `mapping` using *comparator*. If the result of applying the predicate *stop?* to *seed* is true, return the mapping. Otherwise, apply the procedure *mapper* to *seed*. *Mapper* returns two values which are added to the mapping as the key and the value, respectively. Then get a new seed by applying the procedure *successor* to *seed*, and repeat this algorithm. Associations earlier in the list take precedence over those that come later.

*Note that the choice of precedence in `mapping` and `mapping-unfold` is compatible with `mapping-adjoin` and `alist->mapping` detailed below and with `alist->hash-table` from SRFI 125, but different from the one in `mapping-set` from below.*

### Predicates

`(mapping? `*obj*`)`

Returns `#t` if *`obj`* is a mapping, and `#f` otherwise.

`(mapping-contains? `*`mapping`*` `*`key`*`)`

Returns `#t` if *`key`* is the key of an association of *`mapping`* and `#f` otherwise.

`(mapping-empty? `*`mapping`*`)`

Returns `#t` if *mapping* has no associations and `#f` otherwise.

`(mapping-disjoint? `*`mapping`<sub>`1`</sub>*` `*`mapping`<sub>`2`</sub>*`)`

Returns `#t` if *`mapping`<sub>`1`</sub>* and *`mapping`<sub>`2`</sub>* have no keys in common and `#f` otherwise.

### Accessors

The following three procedures, given a key, return the corresponding value.

`(mapping-ref `*`mapping`*` `*`key`*` `*`failure`*` `*`success`*`)`

`(mapping-ref `*`mapping`*` `*`key`*` `*`failure`*`)`

`(mapping-ref `*`mapping`*` `*`key`*`)`

Extracts the value associated to *`key`* in the mapping *`mapping`*, invokes the procedure *`success`* in tail context on it, and returns its result; if *`success`* is not provided, then the value itself is returned. If *`key`* is not contained in *`mapping`* and *`failure`* is supplied, then *`failure`* is invoked in tail context on no arguments and its values are returned. Otherwise, it is an error.

`(mapping-ref/default `*`mapping`*` `*`key`*` `*`default`*`)`

Semantically equivalent to, but may be more efficient than, the following code:

```
  (mapping-ref mapping key (lambda () default))
```

`(mapping-key-comparator `*`mapping`*`)`

Returns the comparator used to compare the keys of the mapping *mapping*.

### Updaters

`(mapping-adjoin `*`mapping`*` `*`arg`*` ...)`

The `mapping-adjoin` procedure returns a newly allocated mapping that uses the same comparator as the mapping *`mapping`* and contains all the associations of *`mapping`*, and in addition new associations by processing the arguments from left to right. The \*`arg`\*s alternate between keys and values. Whenever there is a previous association for a key, the previous association prevails and the new association is skipped. It is an error to add an association to *`mapping`* whose key that does not return `#t` when passed to the type test procedure of the comparator.

`(mapping-adjoin! `*`mapping`*` `*`arg`*` ...)`

The `mapping-adjoin!` procedure is the same as `mapping-adjoin`, except that it is permitted to mutate and return the *`mapping`* argument rather than allocating a new mapping.

`(mapping-set `*`mapping`*` `*`arg`*` ...)`

The `mapping-set` procedure returns a newly allocated mapping that uses the same comparator as the mapping *`mapping`* and contains all the associations of *`mapping`*, and in addition new associations by processing the arguments from left to right. The \*`arg`\*s alternate between keys and values. Whenever there is a previous association for a key, it is deleted. It is an error to add an association to *`mapping`* whose key that does not return `#t` when passed to the type test procedure of the comparator.

`(mapping-set! `*`mapping`*` `*`arg`*` ...)`

The `mapping-set!` procedure is the same as `mapping-set`, except that it is permitted to mutate and return the *`mapping`* argument rather than allocating a new mapping.

`(mapping-replace `*`mapping`*` `*`key`*` `*`value`*`)`

The `mapping-replace` procedure returns a newly allocated mapping that uses the same comparator as the mapping *mapping* and contains all the associations of *mapping* except as follows: If *`key`* is equal (in the sense of *`mapping`*'s comparator) to an existing key of *`mapping`*, then the association for that key is omitted and replaced the association defined by the pair *`key`* and *`value`*. If there is no such key in *`mapping`*, then *`mapping`* is returned unchanged.

`(mapping-replace! `*`mapping`*` `*`key`*` `*`value`*`)`

The `mapping-replace!` procedure is the same as `mapping-replace`, except that it is permitted to mutate and return the *`mapping`* argument rather than allocating a new mapping.

`(mapping-delete `*`mapping`*` `*`key`*` ...)`

`(mapping-delete! `*`mapping`*` `*`key`*` ...)`

`(mapping-delete-all `*`mapping`*` `*`key-list`*`)`

`(mapping-delete-all! `*`mapping`*` `*`key-list`*`)`

The `mapping-delete` procedure returns a newly allocated mapping containing all the associations of the mapping *`mapping`* except for any whose keys are equal (in the sense of *`mapping`*'s comparator) to one or more of the \*`key`\*s. Any *`key`* that is not equal to some key of the mapping is ignored.

The `mapping-delete!` procedure is the same as `mapping-delete`, except that it is permitted to mutate and return the *`mapping`* argument rather than allocating a new mapping.

The `mapping-delete-all` and `mapping-delete-all!` procedures are the same as `mapping-delete` and `mapping-delete!`, respectively, except that they accept a single argument which is a list of keys whose associations are to be deleted.

`(mapping-intern `*`mapping`*` `*`key`*` `*`failure`*`)`

Extracts the value associated to *`key`* in the mapping *`mapping`*, and returns *`mapping`* and the value as two values. If *`key`* is not contained in *`mapping`*, *`failure`* is invoked on no arguments. The procedure then returns two values, a newly allocated mapping that uses the same comparator as the *`mapping`* and contains all the associations of *`mapping`*, and in addition a new association mapping *key* to the result of invoking *`failure`*, and the result of invoking *`failure`*.

`(mapping-intern! `*`mapping`*` `*`key`*` `*`failure`*`)`

The `mapping-intern!` procedure is the same as `mapping-intern`, except that it is permitted to mutate and return the *`mapping`* argument as its first value rather than allocating a new mapping.

`(mapping-update `*`mapping`*` `*`key`*` `*`updater`*` `*`failure`*` `*`success`*`)`

`(mapping-update `*`mapping`*` `*`key`*` `*`updater`*` `*`failure`*`)`

`(mapping-update `*`mapping`*` `*`key`*` `*`updater`*`)`

Semantically equivalent to, but may be more efficient than, the following code

```
  (mapping-set mapping key (updater (mapping-ref mapping key failure success)))
```

The obvious semantics hold when *`success`* (and *`failure`*) are omitted (see `mapping-ref`).

`(mapping-update! `*`mapping`*` `*`key`*` `*`updater`*` `*`failure`*` `*`success`*`)`

`(mapping-update! `*`mapping`*` `*`key`*` `*`updater`*` `*`failure`*`)`

`(mapping-update! `*`mapping`*` `*`key`*` `*`updater`*`)`

The `mapping-update!` procedure is the same as `mapping-update`, except that it is permitted to mutate and return the *`mapping`* argument rather than allocating a new mapping.

`(mapping-update/default `*`mapping`*` `*`key`*` `*`updater`*` `*`default`*`)`

Semantically equivalent to, but may be more efficient than, the following code

```
  (mapping-set mapping key (updater (mapping-ref/default mapping key default)))
```

`(mapping-update!/default `*`mapping`*` `*`key`*` `*`updater`*` `*`default`*`)`

The `mapping-update!/default` procedure is the same as `mapping-update/default`, except that it is permitted to mutate and return the *`mapping`* argument rather than allocating a new mapping.

`(mapping-pop `*`mapping`*` `*`failure`*`)`

`(mapping-pop `*`mapping`*`)`

The `mapping-pop` procedure exported from `(srfi 146)` chooses the association with the least key from *`mapping`* and returns three values, a newly allocated mapping that uses the same comparator as *`mapping`* and contains all associations of *`mapping`* except the chosen one, and the key and the value of the chosen association. If *`mapping`* contains no association and *`failure`* is supplied, then *`failure`* is invoked in tail context on no arguments and its values returned. Otherwise, it is an error.

The `hashmap-pop` procedure exported by `(srfi 146 hash)` is similar but chooses an arbitrary association.

`(mapping-pop! `*`mapping`*` `*`failure`*`)`

`(mapping-pop! `*`mapping`*`)`

The `mapping-pop!` procedure is the same as `mapping-pop`, except that it is permitted to mutate and return the *`mapping`* argument rather than allocating a new mapping.

`(mapping-search `*`mapping`*` `*`key`*` `*`failure`*` `*`success`*`)`

The mapping *`mapping`* is searched in order (that is in the order of the stored keys) for an association with key *`key`*. If it is not found, then the *`failure`* procedure is tail-called with two continuation arguments, *`insert`* and *`ignore`*, and is expected to tail-call one of them. If an association with key *`key`* is found, then the *`success`* procedure is tail-called with the matching key of *`mapping`*, the associated value, and two continuations, *`update`* and *`remove`*, and is expected to tail-call one of them.

The `hashmap-search` procedure exported by `(srfi 146 hash)` searches in an arbitrary order.

It is an error if the continuation arguments are invoked, but not in tail position in the *`failure`* and *`success`* procedures. It is also an error if the *`failure`* and *`success`* procedures return to their implicit continuation without invoking one of their continuation arguments.

The effects of the continuations are as follows (where *`obj`* is any Scheme object):

- Invoking `(`*`insert`*` `*`value`*` `*`obj`*`)` causes a mapping to be newly allocated that uses the same comparator as the mapping *`mapping`* and contains all the associations of *`mapping`*, and in addition a new association mapping *`key`* to *`value`*.

- Invoking `(`*`ignore`*` `*`obj`*`)` has no effects; in particular, no new mapping is allocated (but see below).

- Invoking `(`*`update`*` `*`new-key`*` `*`new-value`*` `*`obj`*`)` causes a mapping to be newly allocated that uses the same comparator as the *`mapping`* and contains all the associations of *`mapping`*, except for the association with key *`key`*, which is replaced by a new association mapping *`new-key`* to *`new-value`*.

- Invoking `(`*`remove`*` `*`obj`*`)` causes a mapping to be newly allocated that uses the same comparator as the *`mapping`* and contains all the associations of *`mapping`*, except for the association with key *`key`*.

In all cases, two values are returned: the possibly newly allocated *`mapping`* and *`obj`*.

`(mapping-search! `*`mapping`*` `*`key`*` `*`failure`*` `*`success`*`)`

The `mapping-search!` procedure is the same as `mapping-search`, except that it is permitted to mutate and return the *`mapping`* argument rather than allocating a new mapping.

### The whole mapping

`(mapping-size `*`mapping`*`)`

Returns the number of associations in *mapping* as an exact integer.

`(mapping-find `*`predicate`*` `*`mapping`*` `*`failure`*`)`

Returns the association with the least key of the mapping *`mapping`* consisting of a key and value as two values such that *`predicate`* returns a true value when invoked with key and value as arguments, or the result of tail-calling *`failure`* with no arguments if there is none. There are no guarantees how many times and with which keys and values *`predicate`* is invoked.

The `hashmap-find` procedure exported by `(srfi 146 hash)` searches in arbitrary order.

`(mapping-count `*`predicate`*` `*`mapping`*`)`

Returns the number of associations of the mapping *mapping* that satisfy *`predicate`* (in the sense of `mapping-find`) as an exact integer. There are no guarantees how many times and with which keys and values *`predicate`* is invoked.

`(mapping-any? `*`predicate`*` `*`mapping`*`)`

Returns `#t` if any association of the mapping *`mapping`* satisfies *`predicate`* (in the sense of `mapping-find`), or `#f` otherwise. There are no guarantees how many times and with which keys and values *`predicate`* is invoked.

`(mapping-every? `*`predicate`*` `*`mapping`*`)`

Returns `#t` if every association of the mapping *`mapping`* satisfies *`predicate`* (in the sense of `mapping-find`), or `#f` otherwise. There are no guarantees how many times and with which keys and values *`predicate`* is invoked.

`(mapping-keys `*`mapping`*`)`

Returns a newly allocated list of all the keys in increasing order in the mapping *`mapping`*.

If `hashmap-keys` is imported from `(srfi 146 hash)`, the list is returned in arbitrary order.

`(mapping-values `*`mapping`*`)`

Returns a newly allocated list of all the values in increasing order of the keys in the mapping *`mapping`*.

If `hashmap-values` is imported from `(srfi 146 hash)`, the list is returned in arbitrary order.

`(mapping-entries `*`mapping`*`)`

Returns two values, a newly allocated list of all the keys in the mapping *`mapping`*, and a newly allocated list of all the values in the mapping *`mapping`* in increasing order of the keys.

If `hashmap-entries` is imported from `(srfi 146 hash)`, the lists are returned in arbitrary, but consistent order.

### Mapping and folding

`(mapping-map `*`proc`*` `*`comparator`*` `*`mapping`*`)`

Applies *`proc`*, which returns two values, on two arguments, the key and value of each association of *`mapping`* in increasing order of the keys and returns a newly allocated mapping that uses the comparator *`comparator`*, and which contains the results of the applications inserted as keys and values. Note that this is more akin to `set-mapping` from SRFI 113 than to `hash-table-mapping` from SRFI 125. For example:

```

  (mapping-map (lambda (key value)
             (values (symbol->string key) value))
           (make-default-comparator)
           (mapping (make-default-comparator) 'foo 1 'bar 2 'baz 3))
  ; ⇒ (mapping (make-default-comparator) "foo" 1 "bar" 2 "baz" 3)
```

Note that, when *`proc`* defines a mapping that is not 1:1 between the keys, some of the mapped objects may be equivalent in the sense of the *`comparator`*'s equality predicate, and in this case duplicate associations are omitted as in the mapping constructor. It is unpredictable which one will be preserved in the result.

If `hashmap-map` is imported from `(srfi 146 hash)`, the associations are mapped in arbitrary order.

`(mapping-for-each `*`proc`*` `*`mapping`*`)`

Invokes *`proc`* for every association in the mapping *`mapping`* in increasing order of the keys, discarding the returned values, with two arguments: the key of the association and the value of the association. Returns an unspecified value.

If `hashmap-for-each` is imported from `(srfi 146 hash)`, the associations are processed in arbitrary order.

`(mapping-fold `*`proc`*` `*`nil`*` `*`mapping`*`)`

Invokes *`proc`* for each association of the mapping *`mapping`* in increasing order of the keys with three arguments: the key of the association, the value of the association, and an accumulated result of the previous invocation. For the first invocation, *`nil`* is used as the third argument. Returns the result of the last invocation, or *`nil`* if there was no invocation.

If `hashmap-fold` is imported from `(srfi 146 hash)`, the associations are accumulated in arbitrary order.

`(mapping-map->list `*`proc`*` `*`mapping`*`)`

Calls *`proc`* for every association in increasing order of the keys in the mapping *`mapping`* with two arguments: the key of the association and the value of the association. The values returned by the invocations of *`proc`* are accumulated into a list, which is returned.

If `hashmap->list` is imported from `(srfi 146 hash)`, the associations are processed in arbitrary order.

`(mapping-filter `*`predicate`*` `*`mapping`*`)`

Returns a newly allocated mapping with the same comparator as the mapping *`mapping`*, containing just the associations of *`mapping`* that satisfy *predicate* (in the sense of `mapping-find`).

`(mapping-filter! `*`predicate`*` `*`mapping`*`)`

A linear update procedure that returns a mapping containing just the associations of *`mapping`* that satisfy *`predicate`*.

`(mapping-remove `*`predicate`*` `*`mapping`*`)`

Returns a newly allocated mapping with the same comparator as the mapping *`mapping`*, containing just the associations of *`mapping`* that do not satisfy *predicate* (in the sense of `mapping-find`).

`(mapping-remove! `*`predicate`*` `*`mapping`*`)`

A linear update procedure that returns a mapping containing just the associations of *`mapping`* that do not satisfy *`predicate`*.

`(mapping-partition `*`predicate`*` `*`mapping`*`)`

Returns two values: a newly allocated mapping with the same comparator as the mapping *`mapping`* that contains just the associations of *`mapping`* that satisfy *`predicate`* (in the sense of `mapping-find`), and another newly allocated mapping, also with the same comparator, that contains just the associations of *`mapping`* that do not satisfy *`predicate`*.

`(mapping-partition! `*`predicate`*` `*`mapping`*`)`

A linear update procedure that returns two mappings containing the associations of *`mapping`* that do and do not, respectively, satisfy *`predicate`*.

### Copying and conversion

`(mapping-copy `*`mapping`*`)`

Returns a newly allocated mapping containing the associations of the mapping *`mapping`*, and using the same comparator.

`(mapping->alist `*`mapping`*`)`

Returns a newly allocated association list containing the associations of the *`mapping`* in increasing order of the keys. Each association in the list is a pair whose car is the key and whose cdr is the associated value.

If `hashmap->alist` is imported from `(srfi 146 hash)`, the association list is in arbitrary order.

`(alist->mapping `*`comparator`*` `*`alist`*`)`

Returns a newly allocated mapping, created as if by `mapping` using the comparator *`comparator`*, that contains the associations in the list, which consist of a pair whose car is the key and whose cdr is the value. Associations earlier in the list take precedence over those that come later.

`(alist->mapping! `*`mapping`*` `*`alist`*`)`

A linear update procedure that returns a mapping that contains the associations of both *`mapping`* and *`alist`*. Associations in the mapping and those earlier in the list take precedence over those that come later.

### Submappings

All predicates in this subsection take a *`comparator`* argument, which is a comparator used to compare the values of the associations stored in the mappings. Associations in the mappings are equal if their keys are equal with mappings' key comparator and their values are equal with the given comparator. Two mappings are equal if and only if their associations are equal, respectively.

Note: None of these five predicates produces a total order on mappings. In particular, `mapping=?`, `mapping<?`, and `mapping>?` do not obey the trichotomy law.

`(mapping=? `*`comparator`*` `*`mapping`<sub>`1`</sub>*` `*`mapping`<sub>`2`</sub>*` ...)`

Returns `#t` if each mapping *`mapping`* contains the same associations, and `#f` otherwise.

Furthermore, it is explicitly not an error if `mapping=?` is invoked on mappings that do not share the same (key) comparator. In that case, `#f` is returned.

`(mapping<? `*`comparator`*` `*`mapping`<sub>`1`</sub>*` `*`mapping`<sub>`2`</sub>*` ...)`

Returns `#t` if the set of associations of each mapping *`mapping`* other than the last is a proper subset of the following *mapping*, and `#f` otherwise.

`(mapping>? `*`comparator`*` `*`mapping`<sub>`1`</sub>*` `*`mapping`<sub>`2`</sub>*` ...)`

Returns `#t` if the set of associations of each mapping *`mapping`* other than the last is a proper superset of the following *mapping*, and `#f` otherwise.

`(mapping<=? `*`comparator`*` `*`mapping`<sub>`1`</sub>*` `*`mapping`<sub>`2`</sub>*` ...)`

Returns `#t` if the set of associations of each mapping *`mapping`* other than the last is a subset of the following *mapping*, and `#f` otherwise.

`(mapping>=? `*`comparator`*` `*`mapping`<sub>`1`</sub>*` `*`mapping`<sub>`2`</sub>*` ...)`

Returns `#t` if the set of associations of each mapping *`mapping`* other than the last is a superset of the following *mapping*, and `#f` otherwise.

### Set theory operations

`(mapping-union `*`mapping`<sub>`1`</sub>` mapping`<sub>`2`</sub>*` ...)`

`(mapping-intersection `*`mapping`<sub>`1`</sub>` mapping`<sub>`2`</sub>*` ...)`

`(mapping-difference `*`mapping`<sub>`1`</sub>` mapping`<sub>`2`</sub>*` ...)`

`(mapping-xor `*`mapping`<sub>`1`</sub>` mapping`<sub>`2`</sub>*`)`

Return a newly allocated mapping whose set of associations is the union, intersection, asymmetric difference, or symmetric difference of the sets of associations of the mappings \*`mapping`\*s. Asymmetric difference is extended to more than two mappings by taking the difference between the first mapping and the union of the others. Symmetric difference is not extended beyond two mappings. When comparing associations, only the keys are compared. In case of duplicate keys (in the sense of the \*`mapping`\*s comparators), associations in the result mapping are drawn from the first mapping in which they appear.

`(mapping-union! `*`mapping`<sub>`1`</sub>` mapping`<sub>`2`</sub>*` ...)`

`(mapping-intersection! `*`mapping`<sub>`1`</sub>` mapping`<sub>`2`</sub>*` ...)`

`(mapping-difference! `*`mapping`<sub>`1`</sub>` mapping`<sub>`2`</sub>*` ...)`

`(mapping-xor! `*`mapping`<sub>`1`</sub>` mapping`<sub>`2`</sub>*`)`

These procedures are the linear update analogs of the corresponding pure functional procedures above.

### Additional procedures for mappings with ordered keys

The following procedures are only exported by the `(srfi 146)` library and not by `(srfi 146 hash)`:

`(mapping/ordered `*`comparator`*` `*`arg`*` ...)`

`(mapping-unfold/ordered `*`stop?`*` `*`mapper`*` `*`successor`*` `*`seed`*` `*`comparator`*`)`

These are the same as `mapping` and `mapping-unfold`, except that it is an error if the keys are not in order, and they may be more efficient.

`(alist->mapping/ordered `*`comparator`*` `*`alist`*`)`

`(alist->mapping/ordered! `*`mapping`*` `*`alist`*`)`

These are the same as `alist->mapping` and `alist->mapping!`, except that it is an error if the keys are not in order, and they may be more efficient.

`(mapping-min-key `*`mapping`*`)`

`(mapping-max-key `*`mapping`*`)`

Returns the least/greatest key contained in the mapping *`mapping`*. It is an error for *`mapping`* to be empty.

`(mapping-min-value `*`mapping`*`)`

`(mapping-max-value `*`mapping`*`)`

Returns the value associated with the least/greatest key contained in the mapping *`mapping`*. It is an error for *`mapping`* to be empty.

*Note: It does not make sense to ask for the least/greatest value contained in *`mapping`* because the values have no specified order.*

`(mapping-min-entry `*`mapping`*`)`

`(mapping-max-entry `*`mapping`*`)`

Returns the entry associated with the least/greatest key contained in the mapping *`mapping`* as two values, the key and its associated value. It is an error for *`mapping`* to be empty.

`(mapping-key-predecessor `*`mapping`*` `*`obj`*` `*`failure`*`)`

`(mapping-key-successor `*`mapping`*` `*`obj`*` `*`failure`*`)`

Returns the key contained in the mapping *`mapping`* that immediately precedes/succeeds *`obj`* in the mapping's order of keys. If no such key is contained in *`mapping`* (because *`obj`* is the minimum/maximum key, or because *`mapping`* is empty), returns the result of tail-calling the thunk *`failure`*.

`(mapping-range= `*`mapping`*` `*`obj`*`)`

`(mapping-range< `*`mapping`*` `*`obj`*`)`

`(mapping-range> `*`mapping`*` `*`obj`*`)`

`(mapping-range<= `*`mapping`*` `*`obj`*`)`

`(mapping-range>= `*`mapping`*` `*`obj`*`)`

Returns a mapping containing only the associations of the *`mapping`* whose keys are equal to, less than, greater than, less than or equal to, or greater than or equal to *`obj`*.

*Note: Note that since keys in mappings are unique, `mapping-range=` returns a mapping with at most one association.*

`(mapping-range=! `*`mapping`*` `*`obj`*`)`

`(mapping-range<! `*`mapping`*` `*`obj`*`)`

`(mapping-range>! `*`mapping`*` `*`obj`*`)`

`(mapping-range<=! `*`mapping`*` `*`obj`*`)`

`(mapping-range>=! `*`mapping`*` `*`obj`*`)`

Linear update procedures returning a mapping containing only the associations of the *`mapping`* whose keys are equal to, less than, greater than, less than or equal to, or greater than or equal to *`obj`*.

`(mapping-split `*`mapping`*` `*`obj`*`)`

Returns five values, equivalent to the results of invoking `(mapping-range< `*`mapping`*` `*`obj`*`)`, `(mapping-range<= `*`mapping`*` `*`obj`*`)`, `(mapping-range= `*`mapping`*` `*`obj`*`)`, `(mapping-range>= `*`mapping`*` `*`obj`*`)`, and `(mapping-range> `*`mapping`*` `*`obj`*`)`, but may be more efficient.

`(mapping-split! `*`mapping`*` `*`obj`*`)`

The `mapping-split!` procedure is the same as `mapping-split`, except that it is permitted to mutate and return the *`mapping`* rather than allocating a new mapping.

`(mapping-catenate `*`comparator`*` `*`mapping`*<sub>`1`</sub>` `*`key`*` `*`value`*` `*`mapping`*<sub>`2`</sub>`)`

Returns a newly allocated mapping using the comparator *`comparator`* whose set of associations is the union of the sets of associations of the mapping *`mapping`*<sub>`1`</sub>, the association mapping *`key`* to *`value`*, and the associations of *`mapping`*<sub>`2`</sub>. It is an error if the keys contained in *`mapping`*<sub>`1`</sub> in their natural order, the key *key*, and the keys contained in *`mapping`*<sub>`2`</sub> in their natural order (in that order) do not form a strictly monotone sequence with respect to the ordering of *`comparator`*.

`(mapping-catenate! `*`mapping1`*` `*`key`*` `*`value`*` `*`mapping2`*`)`

The `mapping-catenate!` procedure is the same as `mapping-catenate`, except that it is permitted to mutate and return one of the \*`mapping`\*s rather than allocating a new mapping.

`(mapping-map/monotone `*`proc`*` `*`comparator`*` `*`mapping`*`)`

Equivalent to `(mapping-map `*`proc`*` `*`comparator`*` `*`mapping`*`)`, but it is an error if *proc* does not induce a strictly monotone mapping between the keys with respect to the ordering of the comparator of *`mapping`* and the ordering of *`comparator`*. Maybe be implemented more efficiently than `mapping-map`.

`(mapping-map/monotone! `*`proc`*` `*`comparator`*` `*`mapping`*`)`

The `mapping-map/monotone!` procedure is the same as `mapping-map/monotone`, except that it is permitted to mutate and return the *`mapping`* argument rather than allocating a new mapping.

`(mapping-fold/reverse `*`proc`*` `*`nil`*` `*`mapping`*`)`

Equivalent to `(mapping-fold `*`proc`*` `*`nil`*` `*`mapping`*`)` except that the associations are processed in reverse order with respect to the natural ordering of the keys.

### Comparators

`(comparator? `*`obj`*`)`

Type predicate for comparators as exported by `(srfi 128)`.

*Rationale:* The reason why `comparator?` is reexported from `(srfi 128)` is that it helps to detect if an implementation of the R7RS module system is broken in the sense that it does not allow interdependent libraries. If a program's imports are `(import (srfi 128) (srfi 146))`, it would be an error (principally detectable at expansion time) if the Scheme system loaded `(srfi 128)` twice, once for importing into the program, and once for importing into `(srfi 146)`. Namely, in that case the main program would import `comparator?` with two different bindings, and it would be impossible to invoke any procedure of `(srfi 146)` with a comparator created in the top-level program.

If `(srfi 146)` didn't export `comparator?`, multiple loadings of `(srfi 128)` would not be detected early; only when a `(srfi 146)` procedure is invoked with a comparator created in the top-level program.

One may view exporting `comparator?` as a hack only necessary because the R7RS library system fails to say anything about interdependent libraries (although it is usually assumed that interdependent libraries are possible); one can, however, also make independent sense out of it: By exporting `comparator?`, this specification declares or announces the actual type of comparators, on which its procedures depend.

`(make-mapping-comparator `*`comparator`*`)`

Returns a comparator for mappings that is compatible with the equality predicate `(mapping=? `*`comparator`*` `*`mapping`<sub>`1`</sub>*` `*`mapping`<sub>`2`</sub>*`)`. If `make-mapping-comparator` is imported from `(srfi 146)`, it provides a (partial) ordering predicate that is applicable to pairs of mappings with the same (key) comparator. If `(make-hashmap-comparator)` is imported from `(srfi 146 hash)`, it provides an implementation-dependent hash function.

If `make-mapping-comparator` is imported from `(srfi 146)`, the lexicographic ordering with respect to the keys (and, in case a tiebreak is necessary, with respect to the ordering of the values) is used for mappings sharing a comparator.

The existence of comparators returned by `make-mapping-comparator` allows mappings whose keys are mappings themselves, and it allows to compare mappings whose values are mappings.

~~The following comparator is used to compare mappings when `(make-default-comparator)` from SRFI 128 is invoked~~The user may register the following comparator to compare mappings when `(make-default-comparator)` from SRFI 128 is invoked. (See [post-finalization note](#pfn1) above.)

`mapping-comparator`

`mapping-comparator` is constructed by invoking `make-mapping-comparator` on `(make-default-comparator)`.

## Implementation

The sample implementation for `(srfi 146)` uses a purely functional data structure and is based on red-black trees. This sample R7RS implementation is based on SRFI 1, SRFI 2, SRFI 8, SRFI 128, SRFI 145, and SRFI 158.

The sample implementation for `(srfi 146 hash)` is a thin layer on top of Arthur Gleckler's Hash Array Mapped Trie implementation. This implementation and its tests depend on the SRFIs 1, 16, 27, 113, 125, 128, 132, 143, 151.

[Source for the reference implementation.](https://srfi.schemers.org/srfi-146/srfi-146.tgz)

## Acknowledgements

Credit goes to John Cowan for SRFI 113 and SRFI 128, to Will Clinger and John Cowan for SRFI 125, and to Kevin Wortman for his immutable-maps-proposal. Special credit also goes to Sudarshan S Chawathe and Shiro Kawai for their careful readings of the drafts of this SRFI and their many valuable comments which helped to improve this proposal, and to Jown Cowan for ideas on ordered mappings.

Some wording from SRFI 113 and SRFI 125 has been copied *mutatis mutandis*.

## Copyright

© Marc Nieper-Wißkirchen (2016, 2017).

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice (including the next paragraph) shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

______________________________________________________________________

Editor: [Arthur A. Gleckler](mailto:srfi-editors+at+srfi+dot+schemers+dot+org)
