<!-- SPDX-License-Identifier: MIT -->

<!-- SPDX-FileCopyrightText: SRFI document authors -->

# Title

Intermediate hash tables

# Author

John Cowan, Will Clinger

# Status

This SRFI is currently in *final* status. Here is
[an explanation](https://srfi.schemers.org/srfi-process.html) of each status
that a SRFI can hold. To provide input on this SRFI, please send email to
[`srfi-125@`<span class="antispam">`nospam`</span>`srfi.schemers.org`](mailto:srfi+minus+125+at+srfi+dotschemers+dot+org).
To subscribe to the list, follow
[these instructions](http://srfi.schemers.org/srfi-list-subscribe.html). You can
access previous messages via the mailing list
[archive](https://srfi-email.schemers.org/srfi-125).

- Received: 2015-09-07
- Draft #1 published: 2015-09-07
- Draft #2 published: 2015-09-09
- Draft #3 published: 2015-09-13
- Draft #4 published: 2015-12-06
- Draft #5 published: 2015-12-17
- Draft #6 published: 2016-01-20
- Draft #7 published: 2016-05-03
- Draft #8 published: 2016-05-06
- Draft #9 published: 2016-05-07
- Draft #10 published: 2016-05-17
- Draft #11 published: 2016-05-18
- Draft #12 published: 2016-05-19
- Finalized: 2016-05-28
- Revised for clarity:
  - 2017-09-12 (Clarify, esp. behavior of pop on empty table.)

# Abstract

This SRFI defines an interface to hash tables, which are widely recognized as a
fundamental data structure for a wide variety of applications. A hash table is a
data structure that:

- Is disjoint from all other types.
- Provides a mapping from objects known as *keys* to corresponding objects known
  as *values*.
  - Keys may be any Scheme objects in some kinds of hash tables, but are
    restricted in other kinds.
  - Values may be any Scheme objects.
- Has no intrinsic order for the key-value *associations* it contains.
- Provides an *equality predicate* which defines when a proposed key is the same
  as an existing key. No table may contain more than one value for a given key.
- Provides a *hash function* which maps a candidate key into a non-negative
  exact integer.
- Supports mutation as the primary means of setting the contents of a table.
- Provides key lookup and destructive update in (expected) amortized constant
  time, provided a satisfactory hash function is available.
- Does not guarantee that whole-table operations work in the presence of
  concurrent mutation of the whole hash table (values may be safely mutated).

# Rationale

Hash tables themselves don't really need defending: almost all dynamically typed
languages, from awk to JavaScript to Lua to Perl to Python to Common Lisp, and
including many Scheme implementations, provide them in some form as a
fundamental data structure. Therefore, what needs to be defended is not the data
structure but the procedures. This SRFI is at an intermediate level. It supports
a great many convenience procedures on top of the basic hash table interfaces
provided by [SRFI 69](https://srfi.schemers.org/srfi-69/srfi-69.html) and
[R6RS](http://www.r6rs.org/final/html/r6rs-lib/r6rs-lib-Z-H-14.html). Nothing in
it adds power to what those interfaces provide, but it does add convenience in
the form of pre-debugged routines to do various common things, and even some
things not so commonly done but useful.

There is no mandated support for thread safety, immutability, or weakness,
though there are portable hooks for specifying these features.

This specification accepts separate equality predicates and hash functions for
backward compatibility, but strongly encourages the use of
[SRFI 128](https://srfi.schemers.org/srfi-128/srfi-128.html) comparators, which
package a type test, an equality predicate, and a hash function into a single
bundle.

### SRFI 69 compatibility

This SRFI is downward compatible with SRFI 69. Some procedures have been given
new preferred names for compatibility with other SRFIs, but in all cases the
SRFI 69 names have been retained as deprecated synonyms; implementations must
still provide them, however. They appear in this SRFI <span class="small">in
small print</span>.

There is one absolute incompatibility with SRFI 69: the reflective procedure
`hash-table-hash-function` may return `#f`, which is not permitted by SRFI 69.
See the specification for details.

### R6RS compatibility

The relatively few hash table procedures in R6RS are all available in this SRFI
under somewhat different names. The only substantive difference is that R6RS
`hashtable-values` and `hashtable-entries` return vectors, whereas in this SRFI
`hash-table-values` and `hash-table-entries` return lists. This SRFI adopts SRFI
69's term `hash-table` rather than R6RS's `hashtable`, because of the universal
use of "hash table" rather than "hashtable" in other computer languages and in
technical prose generally. Besides, the English word *hashtable* obviously means
something that can be ... hashted.

In addition, the `hashtable-ref` and `hashtable-update!` of R6RS correspond to
the `hash-table-ref/default` and `hash-table-update!/default` of both SRFI 69
and this SRFI.

It would be trivial to provide the R6RS names on top of this SRFI.

### Common Lisp compatibility

As usual, the Common Lisp names are completely different from the Scheme names.
Common Lisp provides the following capabilities that are not in this SRFI:

- The constructor allows specifying the rehash size and rehash threshold of the
  new hash table. There are also accessors and mutators for these and for the
  current capacity (as opposed to size).

<!-- -->

- There are hash tables based on `equalp` (which does not exist in Scheme).

<!-- -->

- `With-hash-table-iterator` is a hash table external iterator implemented as a
  local macro.

<!-- -->

- `Sxhash` is a implementation-specific hash function for the `equal` predicate.
  It has the property that objects in different instantiations of the same Lisp
  implementation that are
  [similar](http://www.lispworks.com/documentation/lw61/CLHS/Body/03_bdbb.htm),
  a concept analogous to `equal` but defined across all instantiations, always
  return the same value from `sxhash`; for example, the symbol `xyz` will have
  the same `sxhash` result in all instantiations.

### Sources

The procedures in this SRFI are drawn primarily from SRFI 69 and R6RS. In
addition, the following sources are acknowledged:

- The `hash-table-mutable?` procedure and the second argument of
  `hash-table-copy` (which allows the creation of immutable hash tables) are
  from R6RS, renamed in the style of this SRFI.

<!-- -->

- The `hash-table-intern!` procedure is from
  [Racket](http://docs.racket-lang.org/reference/hashtables.html), renamed in
  the style of this SRFI.

<!-- -->

- The `hash-table-find` procedure is a modified version of `table-search` in
  [Gambit](http://www.iro.umontreal.ca/~gambit/doc/gambit-c.html#Tables).

<!-- -->

- The procedures `hash-table-unfold` and `hash-table-count` were suggested by
  [SRFI 1](https://srfi.schemers.org/srfi-1/srfi-1.html).

<!-- -->

- The procedures `hash-table=?` and `hash-table-map` were suggested by
  [Haskell's Data.Map.Strict module](http://hackage.haskell.org/packages/archive/containers/0.5.2.1/doc/html/Data-Map-Strict.html).

<!-- -->

- The procedure `hash-table-map->list` is from
  [Guile](http://www.gnu.org/software/guile/manual/html_node/Hash-Table-Reference.html).

The procedures `hash-table-empty?`, `hash-table-empty-copy`, `hash-table-pop!`,
`hash-table-map!`, `hash-table-intersection!`, `hash-table-difference!`, and
`hash-table-xor!` were added for convenience and completeness.

The native hash tables of
[MIT](http://web.mit.edu/scheme_v9.0.1/doc/mit-scheme-ref/Hash-Tables.html),
[SISC](http://sisc-scheme.org/manual/html/ch09.html#Hashtables),
[Bigloo](http://www-sop.inria.fr/indes/fp/Bigloo/doc/bigloo-7.html#Hash-Tables),
[Scheme48](http://s48.org/0.57/manual/s48manual_44.html),
[SLIB](http://www.cs.indiana.edu/scheme-repository/SCM/slib_2.html#SEC13),
[RScheme](http://www.rscheme.org/rs/b/0.7.3.4/5/html/c2143.html),
[Scheme 7](https://ccrma.stanford.edu/software/snd/snd/s7.html#hashtables),
[Scheme 9](https://github.com/barak/scheme9/blob/master/lib/hash-table.scm),
[Rep](<http://www.fifi.org/cgi-bin/info2www?(librep)Hash+Tables>), and
[FemtoLisp](https://code.google.com/p/femtolisp/wiki/APIReference) were also
investigated, but no additional procedures were incorporated.

### Pronunciation

The slash in the names of some procedures can be pronounced "with".

# Specification

The procedures in this SRFI are in the `(srfi 125)` library (or `(srfi :125)` on
R6RS).

All references to "executing in expected amortized constant time" presuppose
that a satisfactory hash function is available. Arbitrary or impure hash
functions can make a hash of any implementation.

Hash tables are allowed to cache the results of calling the equality predicate
and hash function, so programs cannot rely on the hash function being called
exactly once for every primitive hash table operation: it may be called zero,
one, or more times.

It is an error if the procedure argument of `hash-table-find`,
`hash-table-count`, `hash-table-map`, `hash-table-for-each`, `hash-table-map!`,
`hash-table-map->list`, `hash-table-fold` or `hash-table-prune!` mutates the
hash table being walked.

It is an error to pass two hash tables that have different comparators or
equality predicates to any of the procedures of this SRFI.

Implementations are permitted to ignore user-specified hash functions in certain
circumstances. Specifically, if the equality predicate, whether passed as part
of a comparator or explicitly, is more fine-grained (in the sense of R7RS-small
section 6.1) than `equal?`, the implementation is free — indeed, is encouraged —
to ignore the user-specified hash function and use something
implementation-dependent. This allows the use of addresses as hashes, in which
case the keys must be rehashed if they are moved by the garbage collector. Such
a hash function is unsafe to use outside the context of implementation-provided
hash tables. It can of course be exposed by an implementation as an extension,
with suitable warnings against inappropriate uses.

It is an error to mutate a key during or after its insertion into a hash table
in such a way that the hash function of the table will return a different result
when applied to that key.

### Index

- <a href="https://srfi.schemers.org/srfi-125/srfi-125.html#Constructors" class="wiki">Constructors</a>:
  `make-hash-table`, `hash-table`, `hash-table-unfold`, `alist->hash-table`

<!-- -->

- <a href="https://srfi.schemers.org/srfi-125/srfi-125.html#Predicates" class="wiki">Predicates</a>:
  `hash-table?`, `hash-table-contains?`, `hash-table-exists?` (deprecated),
  `hash-table-empty?`, `hash-table=?`, `hash-table-mutable?`

<!-- -->

- <a href="https://srfi.schemers.org/srfi-125/srfi-125.html#Accessors" class="wiki">Accessors</a>:
  `hash-table-ref`, `hash-table-ref/default`

<!-- -->

- <a href="https://srfi.schemers.org/srfi-125/srfi-125.html#Mutators" class="wiki">Mutators</a>:
  `hash-table-set!`, `hash-table-delete!`, `hash-table-intern!`,
  `hash-table-update!`, `hash-table-update!/default`, `hash-table-pop!`,
  `hash-table-clear!`

<!-- -->

- <a href="https://srfi.schemers.org/srfi-125/srfi-125.html#Thewholehashtable" class="wiki">The
  whole hash table</a>: `hash-table-size`, `hash-table-keys`,
  `hash-table-values`, `hash-table-entries`, `hash-table-find`,
  `hash-table-count`

<!-- -->

- <a href="https://srfi.schemers.org/srfi-125/srfi-125.html#Mappingandfolding" class="wiki">Mapping
  and folding</a>: `hash-table-map`, `hash-table-for-each`, `hash-table-walk`
  (deprecated), `hash-table-map!`, `hash-table-map->list`, `hash-table-fold`,
  `hash-table-prune!`

<!-- -->

- <a href="https://srfi.schemers.org/srfi-125/srfi-125.html#Copyingandconversion" class="wiki">Copying
  and conversion</a>: `hash-table-copy`, `hash-table-empty-copy`,
  `hash-table->alist`

<!-- -->

- <a href="https://srfi.schemers.org/srfi-125/srfi-125.html#Hashtablesassets" class="wiki">Hash
  tables as sets</a>: `hash-table-union!`, `hash-table-merge!` (deprecated),
  `hash-table-intersection!`, `hash-table-difference!`, `hash-table-xor!`

<!-- -->

- <a href="https://srfi.schemers.org/srfi-125/srfi-125.html#Hashfunctionsandreflectivity" class="wiki">Hash
  functions and reflectivity</a> (deprecated): `hash`, `string-hash`,
  `string-ci-hash`, `hash-by-identity`, `hash-table-equivalence-function`,
  `hash-table-hash-function`

### Constructors

`(make-hash-table `*comparator* \[ *arg* ... \]`)`

<span class="small">`(make-hash-table `*equality-predicate* \[ *hash-function*
\] \[ *arg* ... \]`)`</span>

Returns a newly allocated hash table whose equality predicate and hash function
are extracted from *comparator*. Alternatively, for backward compatibility with
SRFI 69 the equality predicate and hash function can be passed as separate
arguments; this usage is deprecated.

As mentioned above, implementations are free to use an appropriate
implementation-dependent hash function instead of the specified hash function,
provided that the specified equality predicate is a refinement of the `equal?`
predicate. This applies whether the hash function and equality predicate are
passed as separate arguments or packaged up into a comparator.

If an equality predicate rather than a comparator is provided, the ability to
omit the *hash-function* argument is severely limited. The implementation must
provide hash functions appropriate for use with the predicates `eq?`, `eqv?`,
`equal?`, `string=?`, and `string-ci=?`, and may extend this list. But if any
unknown equality predicate is provided without a hash function, an error should
be signaled. The constraints on equality predicates and hash functions are given
in [SRFI 128](https://srfi.schemers.org/srfi-128/srfi-128.html).

The meaning of any further arguments is implementation-dependent. However,
implementations which support the ability to specify the initial capacity of a
hash table should interpret a non-negative exact integer as the specification of
that capacity. In addition, if the symbols `thread-safe`, `weak-keys`,
`ephemeral-keys`, `weak-values`, or `ephemeral-values` are present,
implementations should create thread-safe hash tables, hash tables with weak
keys or ephemeral keys, or hash tables with weak or ephemeral values
respectively. Implementations are free to use ephemeral keys or values when weak
keys or values respectively have been requested. To avoid collision with the
*hash-function* argument, none of these arguments can be procedures.

(R6RS `make-eq-hashtable`, `make-eqv-hashtable`, and `make-hashtable`; Common
Lisp `make-hash-table`)

`(hash-table `*comparator* \[ *key value* \] ...`)`

Returns a newly allocated hash table, created as if by `make-hash-table` using
*comparator*. For each pair of arguments, an association is added to the new
hash table with *key* as its key and *value* as its value. If the implementation
supports immutable hash tables, this procedure returns an immutable hash table.
If the same key (in the sense of the equality predicate) is specified more than
once, it is an error.

`(hash-table-unfold `*stop? mapper successor seed comparator arg* ... `)`

Create a new hash table as if by `make-hash-table` using *comparator* and the
*args*. If the result of applying the predicate *stop?* to *seed* is true,
return the hash table. Otherwise, apply the procedure *mapper* to *seed*.
*Mapper* returns two values, which are inserted into the hash table as the key
and the value respectively. Then get a new seed by applying the procedure
*successor* to *seed*, and repeat this algorithm.

`(alist->hash-table `*alist comparator arg* ...`)`

<span class="small">`(alist->hash-table `*alist equality-predicate* \[
*hash-function* \] *arg* ...`)`</span>

Returns a newly allocated hash-table as if by `make-hash-table` using
*comparator* and the *args*. It is then initialized from the associations of
*alist*. Associations earlier in the list take precedence over those that come
later. The second form is for compatibility with SRFI 69, and is deprecated.

### Predicates

`(hash-table? `*obj*`)`

Returns `#t` if *obj* is a hash table, and `#f` otherwise. (R6RS `hashtable?`;
Common Lisp `hash-table-p`)

`(hash-table-contains? `*hash-table key*`)`

<span class="small">`(hash-table-exists? `*hash-table key*`)`</span>

Returns `#t` if there is any association to *key* in *hash-table*, and `#f`
otherwise. Must execute in expected amortized constant time.
<span class="small">The `hash-table-exists?` procedure is the same as
`hash-table-contains?`, is provided for backward compatibility with SRFI 69, and
is deprecated.</span> (R6RS `hashtable-contains?`)

`(hash-table-empty? `*hash-table*`)`

Returns `#t` if *hash-table* contains no associations, and `#f` otherwise.

`(hash-table=? `*value-comparator hash-table<sub>1</sub>
hash-table<sub>2</sub>*`)`

Returns `#t` if *hash-table<sub>1</sub>* and *hash-table<sub>2</sub>* have the
same keys (in the sense of their common equality predicate) and each key has the
same value (in the sense of *value-comparator*), and `#f` otherwise.

`(hash-table-mutable? `*hash-table*`)`

Returns `#t` if the hash table is mutable. Implementations may or may not
support immutable hash tables. (R6RS `hashtable-mutable?`)

### Accessors

The following procedures, given a key, return the corresponding value.

`(hash-table-ref `*hash-table key* \[ *failure* \[ *success* \] \]`)`

Extracts the value associated to *key* in *hash-table*, invokes the procedure
*success* on it, and returns its result; if *success* is not provided, then the
value itself is returned. If *key* is not contained in *hash-table* and
*failure* is supplied, then *failure* is invoked on no arguments and its result
is returned. Otherwise, it is an error. Must execute in expected amortized
constant time, not counting the time to call the procedures. SRFI 69 does not
support the *success* procedure.

`(hash-table-ref/default `*hash-table key default*`)`

Semantically equivalent to, but may be more efficient than, the following code:

> `(hash-table-ref `*hash-table key* `(lambda () `*default*`))`

(R6RS `hashtable-ref`; Common Lisp `gethash`)

### Mutators

The following procedures alter the associations in a hash table either
unconditionally, or conditionally on the presence or absence of a specified key.
It is an error to add an association to a hash table whose key does not satisfy
the type test predicate of the comparator used to create the hash table.

`(hash-table-set! `*hash-table* *arg* ...`)`

Repeatedly mutates *hash-table*, creating new associations in it by processing
the arguments from left to right. The *args* alternate between keys and values.
Whenever there is a previous association for a key, it is deleted. It is an
error if the type check procedure of the comparator of *hash-table*, when
invoked on a key, does not return `#t`. Likewise, it is an error if a key is not
a valid argument to the equality predicate of *hash-table*. Returns an
unspecified value. Must execute in expected amortized constant time per key.
SRFI 69, R6RS `hashtable-set!` and Common Lisp `(setf gethash)` do not handle
multiple associations.

`(hash-table-delete! `*hash-table key* ...`)`

Deletes any association to each *key* in *hash-table* and returns the number of
keys that had associations. Must execute in expected amortized constant time per
key. SRFI 69, R6RS `hashtable-delete!`, and Common Lisp `remhash` do not handle
multiple associations.

`(hash-table-intern! `*hash-table key* *failure*`)`

Effectively invokes `hash-table-ref` with the given arguments and returns what
it returns. If *key* was not found in *hash-table*, its value is set to the
result of calling *failure*. Must execute in expected amortized constant time.

`(hash-table-update! `*hash-table key updater* \[ *failure* \[ *success \]
\]`)`*

Semantically equivalent to, but may be more efficient than, the following code:

> `(hash-table-set! `*hash-table key*` (`*updater* `(hash-table-ref `*hash-table
> key failure success*`)))`

Must execute in expected amortized constant time. Returns an unspecified value.
(SRFI 69 and R6RS `hashtable-update!` do not support the *success* procedure)

`(hash-table-update!/default `*hash-table key updater default*`)`

Semantically equivalent to, but may be more efficient than, the following code:

> `(hash-table-set! `*hash-table key*` (`*updater*
> `(hash-table-ref/default `*hash-table key default*`)))`

Must execute in expected amortized constant time. Returns an unspecified value.

`(hash-table-pop! `*hash-table*`)`

Chooses an arbitrary association from *hash-table* and removes it, returning the
key and value as two values.

It is an error if *hash-table* is empty.

`(hash-table-clear! `*hash-table*`)`

Delete all the associations from *hash-table*. (R6RS `hashtable-clear!`; Common
Lisp `clrhash`)

### The whole hash table

These procedures process the associations of the hash table in an unspecified
order.

`(hash-table-size `*hash-table*`)`

Returns the number of associations in *hash-table* as an exact integer. Should
execute in constant time. (R6RS `hashtable-size`; Common Lisp
`hash-table-count`.)

`(hash-table-keys `*hash-table*`)`

Returns a newly allocated list of all the keys in *hash-table*. R6RS
`hashtable-keys` returns a vector.

`(hash-table-values `*hash-table*`)`

Returns a newly allocated list of all the keys in *hash-table*.

`(hash-table-entries `*hash-table*`)`

Returns two values, a newly allocated list of all the keys in *hash-table* and a
newly allocated list of all the values in *hash-table* in the corresponding
order. R6RS `hash-table-entries` returns vectors.

`(hash-table-find `*proc hash-table failure*`)`

For each association of *hash-table*, invoke *proc* on its key and value. If
*proc* returns true, then `hash-table-find` returns what *proc* returns. If all
the calls to *proc* return `#f`, return the result of invoking the thunk
*failure*.

`(hash-table-count `*pred hash-table*`)`

For each association of *hash-table*, invoke *pred* on its key and value. Return
the number of calls to *pred* which returned true.

### Mapping and folding

These procedures process the associations of the hash table in an unspecified
order.

`(hash-table-map `*proc comparator hash-table*`)`

Returns a newly allocated hash table as if by
`(make-hash-table `*comparator*`)`. Calls *proc* for every association in
*hash-table* with the value of the association. The key of the association and
the result of invoking *proc* are entered into the new hash table. Note that
this is *not* the result of lifting mapping over the domain of hash tables, but
it is considered more useful.

If *comparator* recognizes multiple keys in the *hash-table* as equivalent, any
one of such associations is taken.

`(hash-table-for-each `*proc hash-table*`)`

<span class="small">`(hash-table-walk `*hash-table proc*`)`</span>

Calls *proc* for every association in *hash-table* with two arguments: the key
of the association and the value of the association. The value returned by
*proc* is discarded. Returns an unspecified value. <span class="small">The
`hash-table-walk` procedure is equivalent to `hash-table-for-each` with the
arguments reversed, is provided for backward compatibility with SRFI 69, and is
deprecated.</span> (Common Lisp `maphash`)

`(hash-table-map! `*proc hash-table*`)`

Calls *proc* for every association in *hash-table* with two arguments: the key
of the association and the value of the association. The value returned by
*proc* is used to update the value of the association. Returns an unspecified
value.

`(hash-table-map->list `*proc hash-table*`)`

Calls *proc* for every association in *hash-table* with two arguments: the key
of the association and the value of the association. The values returned by the
invocations of *proc* are accumulated into a list, which is returned.

`(hash-table-fold `*proc seed hash-table*`)`

<span class="small">`(hash-table-fold `*hash-table proc seed*`)`</span>

Calls *proc* for every association in *hash-table* with three arguments: the key
of the association, the value of the association, and an accumulated value
*val*. *Val* is *seed* for the first invocation of *procedure*, and for
subsequent invocations of *proc*, the returned value of the previous invocation.
The value returned by `hash-table-fold` is the return value of the last
invocation of *proc*. <span class="small">The order of arguments with
*hash-table* as the first argument is provided for SRFI 69 compatibility, and is
deprecated.</span>

`(hash-table-prune! `*proc hash-table*`)`

Calls *proc* for every association in *hash-table* with two arguments, the key
and the value of the association, and removes all associations from *hash-table*
for which *proc* returns true. Returns an unspecified value.

### Copying and conversion

`(hash-table-copy `*hash-table* \[ *mutable?* \]`)`

Returns a newly allocated hash table with the same properties and associations
as *hash-table*. If the second argument is present and is true, the new hash
table is mutable. Otherwise it is immutable provided that the implementation
supports immutable hash tables. SRFI 69 `hash-table-copy` does not support a
second argument. (R6RS `hashtable-copy`)

`(hash-table-empty-copy `*hash-table*`)`

Returns a newly allocated mutable hash table with the same properties as
*hash-table*, but with no associations.

`(hash-table->alist `*hash-table*`)`

Returns an alist with the same associations as *hash-table* in an unspecified
order.

### Hash tables as sets

`(hash-table-union! `*hash-table<sub>1</sub> hash-table<sub>2</sub>*`)`

<span class="small">`(hash-table-merge! `*hash-table<sub>1</sub>
hash-table<sub>2</sub>*`)`</span>

Adds the associations of *hash-table<sub>2</sub>* to *hash-table<sub>1</sub>*
and returns *hash-table<sub>1</sub>*. If a key appears in both hash tables, its
value is set to the value appearing in *hash-table<sub>1</sub>*. Returns
*hash-table<sub>1</sub>*. <span class="small">The `hash-table-merge!` procedure
is the same as `hash-table-union!`, is provided for compatibility with SRFI 69,
and is deprecated.</span>

`(hash-table-intersection! `*hash-table<sub>1</sub> hash-table<sub>2</sub>*`)`

Deletes the associations from *hash-table<sub>1</sub>* whose keys don't also
appear in *hash-table<sub>2</sub>* and returns *hash-table<sub>1</sub>*.

`(hash-table-difference! `*hash-table<sub>1</sub> hash-table<sub>2</sub>*`)`

Deletes the associations of *hash-table<sub>1</sub>* whose keys are also present
in *hash-table<sub>2</sub>* and returns *hash-table<sub>1</sub>*.

`(hash-table-xor! `*hash-table<sub>1</sub> hash-table<sub>2</sub>*`)`

Deletes the associations of *hash-table<sub>1</sub>* whose keys are also present
in *hash-table<sub>2</sub>*, and then adds the associations of
*hash-table<sub>2</sub>* whose keys are not present in *hash-table<sub>1</sub>*
to *hash-table<sub>1</sub>*. Returns *hash-table<sub>1</sub>*.

### Hash functions and reflectivity

<span class="small">These functions are made part of this SRFI solely for
compatibility with SRFI 69, and are deprecated.</span>

<span class="small">`(hash `*obj*`[`*arg*` ] )`</span>

<span class="small">The same as SRFI 128's `default-hash` procedure, except that
it must accept (and should ignore) an optional second argument.</span>

<span class="small">`(string-hash `*obj*`[`*arg*` ] )`</span>

<span class="small">Similar to SRFI 128's `string-hash` procedure, except that
it must accept (and should ignore) an optional second argument. It is
incompatible with the procedure of the same name exported by SRFI 128 and
[SRFI 126](https://srfi.schemers.org/srfi-126/srfi-126.html).</span>

<span class="small">`(string-ci-hash `*obj*`[`*arg*` ] )`</span>

<span class="small">Similar to SRFI 128's `string-ci-hash` procedure, except
that it must accept (and should ignore) an optional second argument. It is
incompatible with the procedure of the same name exported by SRFI 128 and
[SRFI 126](https://srfi.schemers.org/srfi-126/srfi-126.html).</span>

<span class="small">`(hash-by-identity `*obj*`[`*arg*` ] )`</span>

<span class="small">The same as SRFI 128's `default-hash` procedure, except that
it must accept (and should ignore) an optional second argument. However, if the
implementation replaces the hash function associated with the `eq?` predicate
with an implementation-dependent alternative, it is an error to call this
procedure at all.</span>

<span class="small">`(hash-table-equivalence-function `*hash-table*`)`</span>

<span class="small">Returns the equivalence procedure used to create
*hash-table*.</span>

<span class="small">`(hash-table-hash-function `*hash-table*`)`</span>

<span class="small">Returns the hash function used to create *hash-table*.
However, if the implementation has replaced the user-specified hash function
with an implementation-specific alternative, the implementation may return `#f`
instead.</span>

# Implementation

The current sample implementation is in the code repository of this SRFI. It
relies upon [SRFI 126](https://srfi.schemers.org/srfi-126/srfi-126.html) and
[SRFI 128](https://srfi.schemers.org/srfi-128/srfi-128.html), but the sample
implementation for SRFI 126 is easily layered over any hash table implementation
that supports either SRFI 69 or R6RS.

The sample implementation of this SRFI never calls any hash function with two
arguments.

The original intention was to make it possible to implement this SRFI on top of
all the native hash table systems mentioned in
<a href="https://srfi.schemers.org/srfi-125/srfi-125.html#Sources" class="wiki">Sources</a>
above as well. However, this turned out not to be practical for the following
reasons:

- Gauche does not support arbitrary equality predicates, only `eq?`, `eqv?`,
  `equal?`, and `string=?`.

<!-- -->

- S7 does not support arbitrary equality predicates: the implementation chooses
  a predicate based on the nature of the keys.

<!-- -->

- SISC, Scheme48/scsh, RScheme, Scheme 9, and Rep do not document any way of
  inspecting a hash table to determine its equality predicates and hash
  functions so that it can be re-created.

<!-- -->

- SLIB hash tables are vectors, not disjoint objects.

<!-- -->

- FemtoLisp supports only `equal?` as the equality predicate.

Native Guile hash tables are a special case. The equivalents of
`hash-table-ref/default`, `hash-table-set!`, and `hash-table-delete!` require
the equality predicate and hash function to be passed to them explicitly
(although there are utility functions for `eq?`, `eqv?`, and `equal?` hash
tables). Consequently, hash tables corresponding to this SRFI would have to be
records containing a Guile hash table, an equality predicate, and a hash
function, which means they could not interoperate directly with native Guile
hash tables.

# Acknowledgements

Some of the language of this SRFI is copied from SRFI 69 with thanks to its
author, Panu Kalliokoski. However, he is not responsible for what I have done
with it. Thanks to Will Clinger for providing the sample implementation, and to
Taylan Ulrich Bayırlı/Kammer for his spirited review.

I also acknowledge the members of the SRFI 125, 126, and 128 mailing lists,
especially Takashi Kato, Alex Shinn, Shiro Kawai, and Per Bothner.

# Copyright

Copyright (C) John Cowan (2015).

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

Editor: [Arthur A. Gleckler](mailto:srfi-editors+at+srfi+dot+schemers+dot+org)

Last modified: Sat, May 7, 2016 9:57:02 PM
