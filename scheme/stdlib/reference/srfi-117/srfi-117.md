<!-- SPDX-License-Identifier: MIT -->

<!-- SPDX-FileCopyrightText: SRFI document authors -->

# Title

Queues based on lists

# Author

John Cowan \<cowan@ccil.org>

# Status

This SRFI is currently in *final* status. Here is
[an explanation](https://srfi.schemers.org/srfi-process.html) of each status
that a SRFI can hold. To provide input on this SRFI, please send email to
[`srfi-117@`<span class="antispam">`nospam`</span>`srfi.schemers.org`](mailto:srfi+minus+117+at+srfi+dotschemers+dot+org).
To subscribe to the list, follow
[these instructions](https://srfi.schemers.org/srfi-list-subscribe.html). You
can access previous messages via the mailing list
[archive](https://srfi-email.schemers.org/srfi-117).

- Received: [2014-12-02](https://srfi.schemers.org/srfi-117/srfi-117-1.1.html)
- Draft: 2014-12-02--2015-02-02
- Revised: [2014-12-04](https://srfi.schemers.org/srfi-117/srfi-117-1.2.html)
- Revised: [2014-12-06](https://srfi.schemers.org/srfi-117/srfi-117-1.3.html)
- Revised: [2015-01-11](https://srfi.schemers.org/srfi-117/srfi-117-1.4.html)
- Revised: [2015-06-08](https://srfi.schemers.org/srfi-117/srfi-117-1.5.html)
- Finalized: 2015-08-25
- Revised to fix errata: 2015-09-06, 2015-09-10, 2016-07-26

# Abstract

List queues are mutable ordered collections that can contain any Scheme object.
Each list queue is based on an ordinary Scheme list containing the elements of
the list queue by maintaining pointers to the first and last pairs of the list.
It's cheap to add or remove elements from the front of the list or to add
elements to the back, but not to remove elements from the back. List queues are
disjoint from other types of Scheme objects.

# Issues

No issues at present.

# Rationale

The list queues described in this SRFI are objects of a disjoint type that
provide an ordered sequence of arbitrary Scheme objects. Like lists, they
provide sequential access to their elements; unlike lists, they normally should
not share storage with other list queues, unless special precautions have been
taken.

Technically, a queue is an object that makes it efficient to remove elements
from the front and to add elements to the back. List queues also make it
efficient to add elements to the front, but removing elements from the back is
inefficient. Therefore, because these objects do not provide the normal
behavioral guarantees of
[deques](http://en.wikipedia.org/wiki/Double-ended_queue), they are not referred
to as deques. True deques will be provided in a future SRFI.

Historically, objects of this form were called "tconc structures" (where "tconc"
is short for "tail concatenate"), and Lispers have tended to roll their own
using pairs. This version uses a record to hold the first-pair and last-pair
pointers rather than a pair, but uses pairs and the empty list internally.

Because the representation of list queues as lists is exposed by the
implementation, it's not necessary to provide a comprehensive API for list
queues. Instead,
<a href="https://srfi.schemers.org/srfi-1/srfi-1.html" class="ext-link">SRFI
1</a> and other list APIs can serve the same purpose, using the conversion
procedures to convert between list queues and lists fairly cheaply.
Consequently, the API provided here over and above the bare necessities of
queueing and dequeueing elements is roughly analogous to the R7RS-small API for
lists. It also subsumes the
<a href="http://wiki.call-cc.org/man/4/Unit%20data-structures#queues" class="ext-link">Chicken</a>
and
<a href="http://people.csail.mit.edu/jaffer/slib/Queues.html#Queues" class="ext-link">​SLIB</a>
APIs.

# Specification

## Constructors

``` (make-list-queue ``list ``` \[ `last` \]`)`

Returns a newly allocated list queue containing the elements of `list` in order.
The result shares storage with `list`. If the `last` argument is not provided,
this operation is O(n) where n is the length of `list`.

However, if `last` is provided, `make-list-queue` returns a newly allocated list
queue containing the elements of the list whose first pair is `first` and whose
last pair is `last`. It is an error if the pairs do not belong to the same list.
Alternatively, both `first` and `last` can be the empty list. In either case,
the operation is O(1).

Note: To apply a non-destructive list procedure to a list queue and return a new
list queue, use
``` (make-list-queue (``proc`` (list-queue-list ``list-queue``))) ```.

``` (list-queue ``element ``` ...`)`

Returns a newly allocated list queue containing the `elements`. This operation
is O(n) where n is the number of elements.

``` (list-queue-copy ``list-queue``) ```

Returns a newly allocated list queue containing the elements of `list-queue`.
This operation is O(n) where n is the length of `list-queue`

``` (list-queue-unfold ``stop? mapper successor seed ``` \[ `queue` \]`)`

Performs the following algorithm:

If the result of applying the predicate `stop?` to `seed` is true, return
`queue`. Otherwise, apply the procedure `mapper` to `seed`, returning a value
which is added to the front of `queue`. Then get a new seed by applying the
procedure `successor` to `seed`, and repeat this algorithm.

If `queue` is omitted, a newly allocated list queue is used.

``` (list-queue-unfold-right ``stop? mapper successor seed ``` \[ `queue` \]`)`

Performs the following algorithm:

If the result of applying the predicate `stop?` to `seed` is true, return the
list queue. Otherwise, apply the procedure `mapper` to `seed`, returning a value
which is added to the back of the list queue. Then get a new seed by applying
the procedure `successor` to `seed`, and repeat this algorithm.

If `queue` is omitted, a newly allocated list queue is used.

## Predicates

``` (list-queue? ``obj``) ```

Returns `#t` if `obj` is a list queue, and `#f` otherwise. This operation is
O(1).

``` (list-queue-empty? ``list-queue``) ```

Returns `#t` if `list-queue` has no elements, and `#f` otherwise. This operation
is O(1).

## Accessors

``` (list-queue-front ``list-queue``) ```

Returns the first element of `list-queue`. If the list queue is empty, it is an
error. This operation is O(1).

``` (list-queue-back ``list-queue``) ```

Returns the last element of `list-queue`. If the list queue is empty, it is an
error. This operation is O(1).

``` (list-queue-list ``list-queue``) ```

Returns the list that contains the members of `list-queue` in order. The result
shares storage with `list-queue`. This operation is O(1).

``` (list-queue-first-last ``list-queue``) ```

Returns two values, the first and last pairs of the list that contains the
members of `list-queue` in order. If `list-queue` is empty, returns two empty
lists. The results share storage with `list-queue`. This operation is O(1).

## Mutators

``` (list-queue-add-front! ``list-queue element``) ```

Adds `element` to the beginning of `list-queue`. Returns an unspecified value.
This operation is O(1).

``` (list-queue-add-back! ``list-queue element``) ```

Adds `element` to the end of `list-queue`. Returns an unspecified value. This
operation is O(1).

``` (list-queue-remove-front! ``list-queue``) ```

Removes the first element of `list-queue` and returns it. If the list queue is
empty, it is an error. This operation is O(1).

``` (list-queue-remove-back! ``list-queue``) ```

Removes the last element of `list-queue` and returns it. If the list queue is
empty, it is an error. This operation is O(n) where n is the length of
`list-queue`, because queues do not not have backward links.

``` (list-queue-remove-all! ``list-queue``) ```

Removes all the elements of `list-queue` and returns them in order as a list.
This operation is O(1).

``` (list-queue-set-list! ``list-queue list ``` \[ `last` \]`)`

Replaces the list associated with `list-queue` with `list`, effectively
discarding all the elements of `list-queue` in favor of those in `list`. Returns
an unspecified value. This operation is O(n) where n is the length of `list`. If
`last` is provided, it is treated in the same way as in `make-list-queue`, and
the operation is O(1).

Note: To apply a destructive list procedure to a list queue, use
``` (list-queue-set-list! (``proc`` (list-queue-list ``list-queue``))) ```.

``` (list-queue-append ``list-queue ``` ...`)`

Returns a list queue which contains all the elements in front-to-back order from
all the `list-queues` in front-to-back order. The result does not share storage
with any of the arguments. This operation is O(n) in the total number of
elements in all queues.

``` (list-queue-append! ``list-queue ``` ...`)`

Returns a list queue which contains all the elements in front-to-back order from
all the `list-queues` in front-to-back order. It is an error to assume anything
about the contents of the `list-queues` after the procedure returns. This
operation is O(n) in the total number of queues, not elements. It is not part of
the R7RS-small list API, but is included here for efficiency when pure
functional append is not required.

``` (list-queue-concatenate ``list-of-list-queues``) ```

Returns a list queue which contains all the elements in front-to-back order from
all the list queues which are members of `list-of-list-queues` in front-to-back
order. The result does not share storage with any of the arguments. This
operation is O(n) in the total number of elements in all queues. It is not part
of the R7RS-small list API, but is included here to make appending a large
number of queues possible in Schemes that limit the number of arguments to
`apply`.

## Mapping

``` (list-queue-map ``proc list-queue``) ```

Applies `proc` to each element of `list-queue` in unspecified order and returns
a newly allocated list queue containing the results. This operation is O(n)
where n is the length of `list-queue`.

``` (list-queue-map! ``proc list-queue``) ```

Applies `proc` to each element of `list-queue` in front-to-back order and
modifies `list-queue` to contain the results. This operation is O(n) in the
length of `list-queue`. It is not part of the R7RS-small list API, but is
included here to make transformation of a list queue by mutation more efficient.

``` (list-queue-for-each ``proc list-queue``) ```

Applies `proc` to each element of `list-queue` in front-to-back order,
discarding the returned values. Returns an unspecified value. This operation is
O(n) where n is the length of `list-queue`.

# Implementation

The sample implementation places the identifiers defined above into the
`list-queue` library.

The [sample implementation](https://srfi.schemers.org/srfi-117/srfi-117.tgz)
contains the following files:

- `list-queues-impl.scm` – implementation of queues
- `list-queues.sld` – an R7RS library named `(list-queue)`
- `list-queues.scm` – a Chicken library
- `list-queues-test.scm` – tests using the Chicken test egg

# Copyright

Copyright © John Cowan, 2014. All Rights Reserved.

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

Editor: [Michael Sperber](mailto:srfi-editors+at+srfi+dot+schemers+dot+org)

Last modified: Tue Jun 9 08:44:01 MST 2015
