<!-- SPDX-License-Identifier: MIT -->

<!-- SPDX-FileCopyrightText: SRFI document authors -->

# Title

Comparators (reduced)

# Author

John Cowan

# Status

This SRFI is currently in *final* status. Here is
[an explanation](https://srfi.schemers.org/srfi-process.html) of each status
that a SRFI can hold. To provide input on this SRFI, please send email to
[`srfi-128@`<span class="antispam">`nospam`</span>`srfi.schemers.org`](mailto:srfi+minus+128+at+srfi+dotschemers+dot+org).
To subscribe to the list, follow
[these instructions](http://srfi.schemers.org/srfi-list-subscribe.html). You can
access previous messages via the mailing list
[archive](https://srfi-email.schemers.org/srfi-128).

- Received: 2015-10-26
- 60-day deadline: 2015-12-25
- Draft #1 published: 2015-10-26
- Draft #2 published: 2015-10-26
- Draft #3 published: 2015-10-29
- Draft #4 published: 2015-11-02
- Draft #5 published: 2015-11-08
- Draft #6 published: 2015-11-10
- Draft #7 published: 2015-11-23
- Draft #8 published: 2015-12-17
- Draft #9 published: 2015-12-25
- Draft #10 published: 2016-01-18
- Draft #11 published: 2016-02-06
- Draft #12 published: 2016-02-14
- Finalized: 2016-02-14
- Revised to fix errata:
  - 2016-05-14 (Add post-finalization note.)
  - 2018-10-09 (Add missing "not.")
  - 2021-03-29 (Fix arguments to `make-comparator` in the
    [Default comparators](#Defaultcomparators) section.)
  - 2024-03-01 (Fix [example](#erratum-floor).)
  - 2025-02-24 (Fix [bytevector comparator](#bytevector-comparator).)

**Post-finalization note #1**: Because of the extremely high cost of conforming
to the first and third conditions of `default-hash`, implementers may disregard
those conditions and examine only a bounded portion of the argument.

**Post-finalization note #2**: After finalization, on 2021-06-03, the author
requested the addition of a non-normative recommendation in the description of
`comparator-register-default!`. See the
[third paragraph](#comparator-register-default-recommendation).

**Post-finalization note #3** (added on 2022-07-19): The hash functions in the
`eq-comparator` and the `eqv-comparator` objects are implementation-defined.

# Abstract

This SRFI provides *comparators*, which bundle a type test predicate, an
equality predicate, an ordering predicate, and a hash function (the last two are
optional) into a single Scheme object. By packaging these procedures together,
they can be treated as a single item for use in the implementation of data
structures.

# Rationale

The four procedures above have complex dependencies on one another, and it is
inconvenient to have to pass them individually to other procedures that might or
might not make use of all of them. For example, a set implementation by its
nature requires only an equality predicate, but if it is implemented using a
hash table, an appropriate hash function is also required if the implementation
does not provide one; alternatively, if it is implemented using a tree,
procedures specifying a total order are required. By passing a comparator rather
than a bare equality predicate, the set implementation can make use of whatever
procedures are available and useful to it.

This SRFI is a simplified and enhanced rewrite of
<a href="https://srfi.schemers.org/srfi-114/srfi-114.html" target="_blank">SRFI
114</a>, and shares some of its design rationale and all of its
acknowledgements. The largest change is the replacement of the comparison
procedure with the ordering procedure. This allowed most of the special-purpose
comparators to be removed. In addition, many of the more specialized procedures,
as well as all but one of the syntax forms, have been removed as unnecessary.

Special thanks to Taylan Ulrich Bayırlı/Kammer, whose insistence that SRFI 114
was unacceptable inspired this redesign. Jörg Wittenberger added
Chicken-specific type declarations, which I have moved to `comparators.scm`, as
it is a Chicken-specific library. He also provided Chicken-specific metadata and
setup commands. Comments from Shiro Kawai, Alex Shinn, and Kevin Wortman guided
me to the current design for bounds and salt.

# Specification

The procedures in this SRFI are in the `(srfi 128)` library (or `(srfi :128)` on
R6RS), but the sample implementation currently places them in the
`(comparators)` library. This means it can't be used alongside SRFI 114, but
there's no reason for anyone to do that.

### Definitions

A *comparator* is an object of a disjoint type. It is a bundle of procedures
that are useful for comparing two objects in a total order. It is an error if
any of the procedures have side effects. There are four procedures in the
bundle:

- The *type test predicate* returns `#t` if its argument has the correct type to
  be passed as an argument to the other three procedures, and `#f` otherwise.

- The *equality predicate* returns `#t` if the two objects are the same in the
  sense of the comparator, and `#f` otherwise. It is the programmer's
  responsibility to ensure that it is reflexive, symmetric, transitive, and can
  handle any arguments that satisfy the type test predicate.

- The *ordering predicate* returns `#t` if the first object precedes the second
  in a total order, and `#f` otherwise. Note that if it is true, the equality
  predicate must be false. It is the programmer's responsibility to ensure that
  it is irreflexive, antisymmetric, transitive, and can handle any arguments
  that satisfy the type test predicate.

- The *hash function* takes an object and returns an exact non-negative integer.
  It is the programmer's responsibility to ensure that it can handle any
  argument that satisfies the type test predicate, and that it returns the same
  value on two objects if the equality predicate says they are the same (but not
  necessarily the converse).

It is also the programmer's responsibility to ensure that all four procedures
provide the same result whenever they are applied to the same object(s) (in the
sense of `eqv?`), unless the object(s) have been mutated since the last
invocation. In particular, they must not depend in any way on memory addresses
in implementations where the garbage collector can move objects in memory.

### Limitations

The comparator objects defined in this SRFI are not applicable to circular
structure or to NaNs, or to objects containing any of these. Attempts to pass
any such objects to any procedure defined here, or to any procedure that is part
of a comparator defined here, is an error except as otherwise noted.

### Index

- [Predicates](#Predicates):
  `comparator? comparator-ordered? comparator-hashable?`

- [Constructors](#Constructors):
  `make-comparator make-pair-comparator make-list-comparator make-vector-comparator make-eq-comparator make-eqv-comparator make-equal-comparator`

- [Standard hash functions](#Hashfunctions):
  `boolean-hash char-hash char-ci-hash string-hash string-ci-hash symbol-hash number-hash`

- [Bounds and salt](#Boundsandsalt): `hash-bound hash-salt`

- [Default comparators](#Defaultcomparators):
  `make-default-comparator default-hash comparator-register-default!`

- [Accessors and invokers](#Accessorsandinvokers):
  `comparator-type-test-predicate comparator-equality-predicate comparator-ordering-predicate comparator-hash-function comparator-test-type comparator-check-type comparator-hash`

- [Comparison predicates](#Comparisonpredicates): `=? <? >? <=? >=?`

- [Syntax](#Syntax): `comparator-if<=>`

### Predicates

`(comparator? `*obj*`)`

Returns `#t` if *obj* is a comparator, and `#f` otherwise.

`(comparator-ordered? `*comparator*`)`

Returns `#t` if *comparator* has a supplied ordering predicate, and `#f`
otherwise.

`(comparator-hashable? `*comparator*`)`

Returns `#t` if *comparator* has a supplied hash function, and `#f` otherwise.

### Constructors

The following comparator constructors all supply appropriate type test
predicates, equality predicates, ordering predicates, and hash functions based
on the supplied arguments. They are allowed to cache their results: they need
not return a newly allocated object, since comparators are pure and functional.
In addition, the procedures in a comparator are likewise pure and functional.

`(make-comparator `*type-test equality ordering hash*`)`

Returns a comparator which bundles the *type-test, equality, ordering*, and
*hash* procedures provided. However, if *ordering* or *hash* is `#f`, a
procedure is provided that signals an error on application. The predicates
`comparator-ordered?` and/or `comparator-hashable?`, respectively, will return
`#f` in these cases.

Here are calls on `make-comparator` that will return useful comparators for
standard Scheme types:

- `(make-comparator boolean? boolean=? (lambda (x y) (and (not x) y)) boolean-hash)`
  will return a comparator for booleans, expressing the ordering `#f` < `#t` and
  the standard hash function for booleans.

- <div id="erratum-floor">

  `(make-comparator real? = < (lambda (x) (exact (floor (abs x)))))` will return
  a comparator expressing the natural ordering of real numbers and a plausible
  (but not optimal) hash function.

  </div>

- `(make-comparator string? string=? string<? string-hash)` will return a
  comparator expressing the implementation's ordering of strings and the
  standard hash function.

- `(make-comparator string? string-ci=? string-ci<? string-ci-hash` will return
  a comparator expressing the implementation's case-insensitive ordering of
  strings and the standard case-insensitive hash function.

`(make-pair-comparator ` ``` car-comparator cdr-comparator``) ```

This procedure returns comparators whose functions behave as follows.

- The type test returns `#t` if its argument is a pair, if the car satisfies the
  type test predicate of `car-comparator`, and the cdr satisfies the type test
  predicate of `cdr-comparator`.

- The equality function returns `#t` if the cars are equal according to
  `car-comparator` and the cdrs are equal according to `cdr-comparator`, and
  `#f` otherwise.

- The ordering function first compares the cars of its pairs using the equality
  predicate of `car-comparator`. If they are not equal, then the ordering
  predicate of `car-comparator` is applied to the cars and its value is
  returned. Otherwise, the predicate compares the cdrs using the equality
  predicate of `cdr-comparator`. If they are not equal, then the ordering
  predicate of `cdr-comparator` is applied to the cdrs and its value is
  returned.

- The hash function computes the hash values of the car and the cdr using the
  hash functions of `car-comparator` and `cdr-comparator` respectively and then
  hashes them together in an implementation-defined way.

`(make-list-comparator ` *element-comparator* *type-test empty? head tail*`)`

This procedure returns comparators whose functions behave as follows:

- The type test returns `#t` if its argument satisfies `type-test` and the
  elements satisfy the type test predicate of `element-comparator`.

- The total order defined by the equality and ordering functions is as follows
  (known as lexicographic order):

  - The empty sequence, as determined by calling `empty?`, compares equal to
    itself.
  - The empty sequence compares less than any non-empty sequence.
  - Two non-empty sequences are compared by calling the `head` procedure on
    each. If the heads are not equal when compared using `element-comparator`,
    the result is the result of that comparison. Otherwise, the results of
    calling the `tail` procedure are compared recursively.

- The hash function computes the hash values of the elements using the hash
  function of `element-comparator` and then hashes them together in an
  implementation-defined way.

`(make-vector-comparator ` *element-comparator* *type-test* *length ref*`)`

This procedure returns comparators whose functions behave as follows:

- The type test returns `#t` if its argument satisfies `type-test` and the
  elements satisfy the type test predicate of `element-comparator`.

- The equality predicate returns `#t` if both of the following tests are
  satisfied in order: the lengths of the vectors are the same in the sense of
  `=`, and the elements of the vectors are the same in the sense of the equality
  predicate of `element-comparator`.

- The ordering predicate returns `#t` if the results of applying `length` to the
  first vector is less than the result of applying `length` to the second
  vector. If the lengths are equal, then the elements are examined pairwise
  using the ordering predicate of `element-comparator`. If any pair of elements
  returns `#t`, then that is the result of the list comparator's ordering
  predicate; otherwise the result is `#f`

- The hash function computes the hash values of the elements using the hash
  function of `element-comparator` and then hashes them together in an
  implementation-defined way.

Here is an example, which returns a comparator for byte vectors:

```
(make-vector-comparator
  (make-comparator exact-integer? = < number-hash)
  bytevector?
  bytevector-length
  bytevector-u8-ref)
```

`(make-eq-comparator)`

`(make-eqv-comparator)`

`(make-equal-comparator)`

These procedures return comparators whose functions behave as follows:

- The type test returns `#t` in all cases.

- The equality functions are `eq?`, `eqv?`, and `equal?` respectively.

- The ordering function is implementation-defined, except that it must conform
  to the rules for ordering functions. It may signal an error instead.

- The hash function is `default-hash`.

These comparators accept circular structure (in the case of `equal-comparator`,
provided the implementation's `equal?` predicate does so) and NaNs.

### Standard hash functions

These are hash functions for some standard Scheme types, suitable for passing to
`make-comparator`. Users may write their own hash functions with the same
signature. However, if programmers wish their hash functions to be backward
compatible with the reference implementation of
[SRFI 69](https://srfi.schemers.org/srfi-69/srfi-69.html), they are advised to
write their hash functions to accept a second argument and ignore it.

`(boolean-hash` ``` obj``) ```

`(char-hash` ``` obj``) ```

`(char-ci-hash` ``` obj``) ```

`(string-hash` ``` obj``) ```

`(string-ci-hash` ``` obj``) ```

`(symbol-hash` ``` obj``) ```

`(number-hash` ``` obj``) ```

These are suitable hash functions for the specified types. The hash functions
`char-ci-hash` and `string-ci-hash` treat their argument case-insensitively.
Note that while `symbol-hash` may return the hashed value of applying
`symbol->string` and then `string-hash` to the symbol, this is not a
requirement.

### Bounds and salt

The following macros allow the callers of hash functions to affect their
behavior without interfering with the calling signature of a hash function,
which accepts a single argument (the object to be hashed) and returns its hash
value. They are provided as macros so that they may be implemented in different
ways: as a global variable, a SRFI 39 or R7RS parameter, or an ordinary
procedure, whatever is most efficient in a particular implementation.

`(hash-bound)` [syntax]

Hash functions should be written so as to return a number between 0 and the
largest reasonable number of elements (such as hash buckets) a data structure in
the implementation might have. What that value is depends on the implementation.
This value provides the current bound as a positive exact integer, typically for
use by user-written hash functions. However, they are not required to bound
their results in this way.

`(hash-salt)` [syntax]

A `salt` is random data in the form of a non-negative exact integer used as an
additional input to a hash function in order to defend against dictionary
attacks, or (when used in hash tables) against denial-of-service attacks that
overcrowd certain hash buckets, increasing the amortized O(1) lookup time to
O(n). Salt can also be used to specify which of a family of hash functions
should be used for purposes such as cuckoo hashing. This macro provides the
current value of the salt, typically for use by user-written hash functions.
However, they are not required to make use of the current salt.

The initial value is implementation-dependent, but must be less than the value
of `(hash-bound)`, and should be distinct for distinct runs of a program unless
otherwise specified by the implementation. Implementations may provide a means
to specify the salt value to be used by a particular invocation of a hash
function.

### Default comparators

`(make-default-comparator)`

Returns a comparator known as a `default comparator` that accepts Scheme values
and orders them in some implementation-defined way, subject to the following
conditions:

- Given disjoint types *a* and *b*, one of three conditions must hold:

  - All objects of type *a* compare less than all objects of type *b*.
  - All objects of type *a* compare greater than all objects of type *b*.
  - All objects of both type *a* and type *b* compare equal to each other. This
    is not permitted for any of the Scheme types mentioned below.

- The empty list must be ordered before all pairs.

- When comparing booleans, it must use the total order `#f` < `#t`.

- When comparing characters, it must use `char=?` and `char<?`.

  Note: In R5RS, this is an implementation-dependent order that is typically the
  same as Unicode codepoint order; in R6RS and R7RS, it is Unicode codepoint
  order.

- When comparing pairs, it must behave the same as a comparator returned by
  `make-pair-comparator` with default comparators as arguments.

- When comparing symbols, it must use an implementation-dependent total order.
  One possibility is to use the order obtained by applying `symbol->string` to
  the symbols and comparing them using the total order implied by `string<?`.

- <div id="bytevector-comparator">

  When comparing bytevectors, it must behave the same as a comparator created by
  the expression
  `(make-vector-comparator (make-comparator exact-integer? = < number-hash) bytevector? bytevector-length bytevector-u8-ref)`.

  </div>

- When comparing numbers where either number is complex, since non-real numbers
  cannot be compared with `<`, the following least-surprising ordering is
  defined: If the real parts are < or >, so are the numbers; otherwise, the
  numbers are ordered by their imaginary parts. This can still produce somewhat
  surprising results if one real part is exact and the other is inexact.

- When comparing real numbers, it must use `=` and `<`.

- When comparing strings, it must use `string=?` and `string<?`.

  Note: In R5RS, this is lexicographic order on the implementation-dependent
  order defined by `char<?`; in R6RS it is lexicographic order on Unicode
  codepoint order; in R7RS it is an implementation-defined order.

- When comparing vectors, it must behave the same as a comparator returned by
  `(make-vector-comparator (make-default-comparator) vector? vector-length vector-ref)`.

- When comparing members of types registered with
  `comparator-register-default!`, it must behave in the same way as the
  comparator registered using that function.

Default comparators use `default-hash` as their hash function.

`(default-hash` ``` obj``) ```

This is the hash function used by default comparators, which accepts a Scheme
value and hashes it in some implementation-defined way, subject to the following
conditions:

- When applied to a pair, it must return the result of hashing together the
  values returned by `default-hash` when applied to the car and the cdr.
- When applied to a boolean, character, string, symbol, or number, it must
  return the same result as `boolean-hash`, `char-hash`, `string-hash`,
  `symbol-hash`, or `number-hash` respectively.
- When applied to a list or vector, it must return the result of hashing
  together the values returned by `default-hash` when applied to each of the
  elements.

``` (comparator-register-default! ``comparator``) ```

Registers `comparator` for use by default comparators, such that if the objects
being compared both satisfy the type test predicate of `comparator`, it will be
employed by default comparators to compare them. Returns an unspecified value.
It is an error if any value satisfies both the type test predicate of
`comparator` and any of the following type test predicates: `boolean?`, `char?`,
`null?`, `pair?`, `symbol?`, `bytevector?`, `number?`, `string?`, `vector?`, or
the type test predicate of a comparator that has already been registered.

This procedure is intended only to extend default comparators into territory
that would otherwise be undefined, not to override their existing behavior. In
general, the ordering of calls to `comparator-register-default!` should be
irrelevant. However, implementations that support inheritance of record types
may wish to ensure that default comparators always check subtypes before
supertypes.

This SRFI recommends (but does not require) that libraries which expose
comparators do *not* register them with this procedure, because the default
comparator (which is meant mostly for ad hoc programming) is meant to be under
the control of the program author rather than the library author. It is the
program author's responsibility to ensure that the registered comparators do not
conflict with each other.

### Accessors and Invokers

`(comparator-type-test-predicate `*comparator*`)`

`(comparator-equality-predicate `*comparator*`)`

`(comparator-ordering-predicate `*comparator*`)`

`(comparator-hash-function `*comparator*`)`

Return the four procedures of *comparator*.

`(comparator-test-type `*comparator obj*`)`

Invokes the type test predicate of *comparator* on *obj* and returns what it
returns. More convenient than `comparator-type-test-predicate`, but less
efficient when the predicate is called repeatedly.

`(comparator-check-type `*comparator obj*`)`

Invokes the type test predicate of *comparator* on *obj* and returns true if it
returns true, but signals an error otherwise. More convenient than
`comparator-type-test-predicate`, but less efficient when the predicate is
called repeatedly.

`(comparator-hash `*comparator obj*`)`

Invokes the hash function of *comparator* on `obj` and returns what it returns.
More convenient than `comparator-hash-function`, but less efficient when the
function is called repeatedly.

Note: No invokers are required for the equality and ordering predicates, because
`=?` and `<?` serve this function.

### Comparison predicates

`(=? `*comparator* *object<sub>1</sub> object<sub>2</sub> object<sub>3</sub>*
...`)`

`(<? `*comparator* *object<sub>1</sub> object<sub>2</sub> object<sub>3</sub>*
...`)`

`(>? `*comparator* *object<sub>1</sub> object<sub>2</sub> object<sub>3</sub>*
...`)`

`(<=? `*comparator* *object<sub>1</sub> object<sub>2</sub> object<sub>3</sub>*
...`)`

`(>=? `*comparator* *object<sub>1</sub> object<sub>2</sub> object<sub>3</sub>*
...`)`

These procedures are analogous to the number, character, and string comparison
predicates of Scheme. They allow the convenient use of comparators to handle
variable data types.

These procedures apply the equality and ordering predicates of *comparator* to
the *objects* as follows. If the specified relation returns `#t` for all
*object<sub>i</sub>* and *object<sub>j</sub>* where *n* is the number of objects
and 1 \<= *i < j \<= n*, then the procedures return `#t`, but otherwise `#f`.
Because the relations are transitive, it suffices to compare each object with
its successor. The order in which the values are compared is unspecified.

### Syntax

`(comparator-if<=> `[ \<comparator> ] \<object<sub>1</sub>>
\<object<sub>2</sub>> \<less-than> \<equal-to> \<greater-than>`)`

It is an error unless \<comparator> evaluates to a comparator and
\<object<sub>1</sub>> and \<object<sub>2</sub>> evaluate to objects that the
comparator can handle. If the ordering predicate returns true when applied to
the values of \<object<sub>1</sub>> and \<object<sub>2</sub>> in that order,
then \<less-than> is evaluated and its value returned. If the equality predicate
returns true when applied in the same way, then \<equal-to> is evaluated and its
value returned. If neither returns true, \<greater-than> is evaluated and its
value returned.

If \<comparator> is omitted, a default comparator is used.

# Implementation

The
<a href="https://srfi.schemers.org/srfi-128/srfi-128.tgz" target="_blank">sample
implementation</a> is found in the repository of this SRFI. It contains the
following files.

- `comparators-impl.scm` - the record type definition and most of the procedures
- `default.scm` - a simple implementation of the default constructor, which
  should be improved by implementers to handle records and
  implementation-specific types
- `r7rs-shim.scm` - procedures for R7RS compatibility, including a trivial
  implementation of bytevectors on top of
  <a href="https://srfi.schemers.org/srfi-4/srfi-4.html" target="_blank">SRFI
  4</a> u8vectors
- `complex-shim.scm` - a trivial implementation of `real-part` and `imag-part`
  for Schemes that don't have complex numbers
- `comparators.meta` - Chicken-specific metadata
- `comparators.setup` - Chicken-specific executable setup
- `comparators.sld` - an R7RS library
- `comparators.scm` - a Chicken library
- `comparators-test.scm` - a test file using the Chicken `test` egg

# Copyright

Copyright (C) John Cowan (2015). All Rights Reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

______________________________________________________________________

Editor:
<a href="mailto:srfi-editors+at+srfi+dot+schemers+dot+org" target="_blank">Arthur
A. Gleckler</a>
