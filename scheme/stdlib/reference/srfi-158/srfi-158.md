<!-- SPDX-License-Identifier: MIT -->

<!-- SPDX-FileCopyrightText: SRFI document authors -->

# Title

Generators and Accumulators

# Author

Shiro Kawai, John Cowan, Thomas Gilray

# Status

This SRFI is currently in *final* status. Here is [an explanation](https://srfi.schemers.org/srfi-process.html) of each status that a SRFI can hold. To provide input on this SRFI, please send email to [`srfi-158@`<span class="antispam">`nospam`</span>`srfi.schemers.org`](mailto:srfi+minus+158+at+srfi+dotschemers+dot+org). To subscribe to the list, follow [these instructions](https://srfi.schemers.org/srfi-list-subscribe.html). You can access previous messages via the mailing list [archive](https://srfi-email.schemers.org/srfi-158).

- Received: 2017-08-11
- Draft #1 published: 2017-08-12
- Draft #2 published: 2017-10-09
- Draft #3 published: 2017-10-21
- Finalized: 2017-10-27
- Revised to fix errata:
  - 2017-10-29 (Fixed description of `gmap`.)
  - 2020-09-02
    1. The `gdelete` description talks about two generated values being compared, but that never happens. What is compared are the item to be deleted and one generated value.
    1. The `gindex` description says it's an error if any index is larger than the number of available values. In fact, that's just one way to reach the end of the resultant generator; there is nothing erroneous about it.
  - 2020-10-14 (Clarified the behavior of `generator-find`.)

# Abstract

This SRFI defines utility procedures that create, transform, and consume generators. A generator is simply a procedure with no arguments that works as a source of values. Every time it is called, it yields a value. Generators may be finite or infinite; a finite generator returns an end-of-file object to indicate that it is exhausted. For example, `read-char`, `read-line`, and `read` are generators that generate characters, lines, and objects from the current input port. Generators provide lightweight laziness.

This SRFI also defines procedures that return accumulators. An accumulator is the inverse of a generator: it is a procedure of one argument that works as a sink of values.

# Rationale

The main purpose of generators is high performance. Although [SRFI 41](https://srfi.schemers.org/srfi-41/srfi-41.html) streams can do everything generators can do and more, SRFI 41 uses lazy pairs that require making a thunk for every item. Generators can generate items without consing, so they are very lightweight and are useful for implementing simple on-demand calculations.

Existing examples of generators are readers from the current input port and [SRFI 27](https://srfi.schemers.org/srfi-27/srfi-27.html) random numbers. If Scheme had streams as one of its built-in abstractions, these would have been naturally represented by lazy streams. But Scheme usually does not expose this kind of API using lazy streams. Generator-like interfaces are common, so it seems worthwhile to have some common idioms extracted into a library.

Calling a generator is a side-effecting construct; you can't safely backtrack, for example, as you can with streams. Persistent lazy sequences based on generators and ordinary Scheme pairs (which are heavier weight than generators, but lighter weight than lazy pairs) are the subject of SRFI 127. Of course the efficiency of streams depends on the implementation. Some implementations may have have super-light thunk creation. But in most, thunk creation is probably slower than simple consing.

An accumulator is the inverse of a generator: it is a procedure of one argument that works as a sink of a series of values. When an accumulator is called on an object that is not an end-of-file object, the object is added to the accumulator's state, and the accumulator returns an unspecified value. How the object is integrated into the state depends on how accumulator was constructed. When an accumulator is called on an end-of-file object, the accumulator returns its state. It is an error to call an accumulator on anything but an end-of-file object after that.

The generators and accumulators of this SRFI don't belong to a disjoint type. They are just procedures that conform to a calling convention, so you can construct a generator or accumulator with `lambda`. The constructors of this SRFI are provided for convenience. Any procedure that can be called with no arguments can serve as a generator. Likewise, any procedure that can be called with one argument can serve as an accumulator.

Note that neither generators nor accumulators can be assumed to be thread-safe.

Using an end-of-file object to indicate that there is no more input makes it impossible to include such an object in the stream of generated or accumulated values. However, it is compatible with the existing design of input ports, and it makes for more compact code than returning a user-specified termination object (as in Common Lisp) or returning multiple values. (Note that some generators are infinite in length, and never return an end-of-file object.)

The combination of `make-for-each-generator` and `generator-unfold` makes it possible to convert any collection that has a for-each procedure into any collection that has an unfold constructor. This generalizes such conversion procedures as `list->vector` and `string->list`.

These procedures are drawn from the Gauche core and the Gauche module [`gauche.generator`](http://practical-scheme.net/gauche/man/gauche-refe/Generators.html) with some renaming to make them more systematic, and with a few additions from the Python library [`itertools`](https://docs.python.org/3/library/itertools.html). Consequently, Shiro Kawai, the author of Gauche and its specifications, is listed as first author of this SRFI. John Cowan served as editor and shepherd. Thomas Gilray provided the sample implementation and a valuable critique of the SRFI. Special acknowledgements to Kragen Javier Sitaker for his extensive review.

This SRFI differs from SRFI 121 by restoring the generator constructor `circular-generator` and the generator operations `gflatten`, `ggroup`, `gmerge`, `gmap`, `gstate-filter`, and `generator-map->list` from `gauche.generator`. It also adds the definition of accumulators and some accumulator constructors.

# Specification

Generators can be divided into two classes, finite and infinite. Both kinds of generators can be invoked an indefinite number of times. After a finite generator has generated all its values, it will return an end-of-file object for all subsequent calls. A generator is said to be *exhausted* if calling it will return an end-of-file object. By definition, infinite generators can never be exhausted.

A generator is said to be in an *undefined state* if it cannot be determined exactly how many values it has generated. This arises because it is impossible to tell by inspecting a generator whether it is exhausted. For example, `(generator-fold + 0 (generator 1 2 3) (generator 1 2))` will compute 0 + 1 + 1 + 2 + 2 = 6, at which time the second generator will be exhausted. If the first generator is invoked, however, it may return either 3 or an end-of-file object, depending on whether the implementation of `generator-fold` has invoked it. Therefore, the first generator is said to be in an undefined state.

After passing an end-of-file object to an accumulator, it is an error to pass anything but another end-of-file object. However, end-of-file objects may be passed repeatedly, and always produce the same result.

## Generator constructors

The result of a generator constructor is just a procedure, so printing it doesn't show much. In the examples in this section we use `generator->list` to convert the generator to a list.

These procedures have names ending with `generator`.

`generator` *arg …*\
The simplest finite generator. Generates each of its arguments in turn. When no arguments are provided, it returns an empty generator that generates no values.

<!-- -->

`circular-generator` *arg<sub>1</sub> arg<sub>2</sub> …*\
The simplest infinite generator. Generates each of its arguments in turn, then generates them again in turn, and so on forever.

<!-- -->

`make-iota-generator` *count \[ start [ step ] \]*\
Creates a finite generator of a sequence of `count` numbers. The sequence begins with `start` (which defaults to 0) and increases by `step` (which defaults to 1). If both `start` and `step` are exact, it generates exact numbers; otherwise it generates inexact numbers. The exactness of `count` doesn't affect the exactness of the results.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(generator-&gt;list (make-iota-generator 3 8))
  ⇒ (8 9 10)</code></pre></td>
</tr>
<tr>
<td> </td>
<td><pre class="example"><code>(generator-&gt;list (make-iota-generator 3 8 2))
  ⇒ (8 10 12)</code></pre></td>
</tr>
</tbody>
</table>

<!-- -->

`make-range-generator` *start \[ end [ step ] \]*\
Creates a generator of a sequence of numbers. The sequence begins with `start`, increases by `step` (default 1), and continues while the number is less than `end`, or forever if `end` is omitted. If both `start` and `step` are exact, it generates exact numbers; otherwise it generates inexact numbers. The exactness of `end` doesn't affect the exactness of the results.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(generator-&gt;list (make-range-generator 3) 4)
  ⇒ (3 4 5 6)</code></pre></td>
</tr>
<tr>
<td> </td>
<td><pre class="example"><code>(generator-&gt;list (make-range-generator 3 8))
  ⇒ (3 4 5 6 7)</code></pre></td>
</tr>
<tr>
<td> </td>
<td><pre class="example"><code>(generator-&gt;list (make-range-generator 3 8 2))
  ⇒ (3 5 7)</code></pre></td>
</tr>
</tbody>
</table>

<!-- -->

`make-coroutine-generator` *proc*\
Creates a generator from a coroutine.

The `proc` argument is a procedure that takes one argument, `yield`. When called, `make-coroutine-generator` immediately returns a generator `g`. When `g` is called, `proc` runs until it calls `yield`. Calling `yield` causes the execution of `proc` to be suspended, and `g` returns the value passed to `yield`.

Whether this generator is finite or infinite depends on the behavior of `proc`. If `proc` returns, it is the end of the sequence — `g` returns an end-of-file object from then on. The return value of `proc` is ignored.

The following code creates a generator that produces a series 0, 1, and 2 (effectively the same as `(make-range-generator 0 3)`) and binds it to `g`.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(define g
  (make-coroutine-generator
   (lambda (yield) (let loop ((i 0))
               (when (&lt; i 3) (yield i) (loop (+ i 1)))))))
&#10;(generator-&gt;list g) ⇒ (0 1 2)</code></pre></td>
</tr>
</tbody>
</table>

<!-- -->

`list->generator` *lis*\
`vector->generator` *vec \[ start [ end ] \]*\
`reverse-vector->generator` *vec \[ start [ end ] \]*\
`string->generator` *str \[ start [ end ] \]*\
`bytevector->generator` *bytevector \[ start [ end ] \]*\
These procedures return generators that yield each element of the given argument. Mutating the underlying object will affect the results of the generator.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(generator-&gt;list (list-&gt;generator &#39;(1 2 3 4 5)))
  ⇒ (1 2 3 4 5)
(generator-&gt;list (vector-&gt;generator &#39;#(1 2 3 4 5)))
  ⇒ (1 2 3 4 5)
(generator-&gt;list (reverse-vector-&gt;generator &#39;#(1 2 3 4 5)))
  ⇒ (5 4 3 2 1)
(generator-&gt;list (string-&gt;generator &quot;abcde&quot;))
  ⇒ (#\a #\b #\c #\d #\e)</code></pre></td>
</tr>
</tbody>
</table>

The generators returned by the constructors are exhausted once all elements are retrieved; the optional `start`-th and `end`-th arguments can limit the range the generator walks across.

For `reverse-vector->generator`, the first value is the element right before the `end`-th element, and the last value is the `start`-th element. For all the other constructors, the first value the generator yields is the `start`-th element, and it ends right before the `end`-th element.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(generator-&gt;list (vector-&gt;generator &#39;#(a b c d e) 2))
  ⇒ (c d e)
(generator-&gt;list (vector-&gt;generator &#39;#(a b c d e) 2 4))
  ⇒ (c d)
(generator-&gt;list (reverse-vector-&gt;generator &#39;#(a b c d e) 2))
  ⇒ (e d c)
(generator-&gt;list (reverse-vector-&gt;generator &#39;#(a b c d e) 2 4))
  ⇒ (d c)
(generator-&gt;list (reverse-vector-&gt;generator &#39;#(a b c d e) 0 2))
  ⇒ (b a)</code></pre></td>
</tr>
</tbody>
</table>

<!-- -->

`make-for-each-generator` *for-each obj*\
A generator constructor that converts any collection `obj` to a generator that returns its elements using a `for-each` procedure appropriate for `obj`. This must be a procedure that when called as `(for-each proc obj)` calls `proc` on each element of `obj`. Examples of such procedures are `for-each`, `string-for-each`, and `vector-for-each` from R7RS. The value returned by `for-each` is ignored. The generator is finite if the collection is finite, which would typically be the case.

The collections need not be conventional ones (lists, strings, etc.) as long as *for-each* can invoke a procedure on everything that counts as a member. For example, the following procedure allows `for-each-generator` to generate the digits of an integer from least to most significant:

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(define (for-each-digit proc n)
  (when (&gt; n 0)
    (let-values (((div rem) (truncate/ n 10)))
      (proc rem)
      (for-each-digit proc div))))</code></pre></td>
</tr>
</tbody>
</table>

<!-- -->

`make-unfold-generator` *stop? mapper successor seed*\
A generator constructor similar to [SRFI 1's](https://srfi.schemers.org/srfi-1/srfi-1.html) `unfold`.

The `stop?` predicate takes a seed value and determines whether to stop. The `mapper ` procedure calculates a value to be returned by the generator from a seed value. The `successor ` procedure calculates the next seed value from the current seed value.

For each call of the resulting generator, `stop?` is called with the current seed value. If it returns true, then the generator returns an end-of-file object. Otherwise, it applies `mapper` to the current seed value to get the value to return, and uses `successor` to update the seed value.

This generator is finite unless `stop?` never returns true.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(generator-&gt;list (make-unfold-generator
                      (lambda (s) (&gt; s 5))
                      (lambda (s) (* s 2))
                      (lambda (s) (+ s 1))
                      0))
  ⇒ (0 2 4 6 8 10)</code></pre></td>
</tr>
</tbody>
</table>

## Generator operations

The following procedures accept one or more generators and return a new generator without consuming any elements from the source generator(s). In general, the result will be a finite generator if the arguments are.

The names of these procedures are prefixed with `g`.

`gcons*` *item … gen*\
Returns a generator that adds `item`s in front of `gen`. Once the `items` have been consumed, the generator is guaranteed to tail-call `gen`.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(generator-&gt;list (gcons* &#39;a &#39;b (make-range-generator 0 2)))
 ⇒ (a b 0 1)</code></pre></td>
</tr>
</tbody>
</table>

<!-- -->

`gappend` *gen …*\
Returns a generator that yields the items from the first given generator, and once it is exhausted, from the second generator, and so on.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(generator-&gt;list (gappend (make-range-generator 0 3) (make-range-generator 0 2)))
 ⇒ (0 1 2 0 1)
&#10;(generator-&gt;list (gappend))
 ⇒ ()</code></pre></td>
</tr>
</tbody>
</table>

<!-- -->

`gflatten` *gen*\
Returns a generator that yields the elements of the lists produced by the given generator.

<!-- -->

`ggroup` *gen k [ padding ]*\
Returns a generator that yields lists of *k* items from the given generator. If fewer than *k* elements are available for the last list, and *padding* is absent, the short list is returned; otherwise, it is padded by *padding* to length *k*.

<!-- -->

`gmerge` *less-than gen1 gen2 ...*\
Returns a generator that yields the items from the given generators in the order dictated by *less-than*. If the items are equal, the leftmost item is used first. When all of given generators are exhausted, the returned generator is exhausted also.

As a special case, if only one generator is given, it is returned.

<!-- -->

`gmap` *proc gen1 gen2 ...*\
When only one generator is given, returns a generator that yields the items from the given generator after invoking *proc* on them.

When more than one generator is given, each item of the resulting generator is a result of applying *proc* to the items from each generator. If any of input generator is exhausted, the resulting generator is also exhausted.

Note: This differs from `generator-map->list`, which consumes all values at once and returns the results as a list, while `gmap` returns a generator immediately without consuming input.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(generator-&gt;list (gmap - (make-range-generator 0 3)))
 ⇒ (0 -1 -2)
&#10;(generator-&gt;list (gmap cons (generator 1 2 3) (generator 4 5)))
 ⇒ ((1 . 4) (2 . 5))</code></pre></td>
</tr>
</tbody>
</table>

<!-- -->

`gcombine` *proc seed gen gen<sub>2</sub> …*\
A generator for mapping with state. It yields a sequence of sub-folds over `proc`.

The `proc` argument is a procedure that takes as many arguments as the input generators plus one. It is called as ``` (``proc v ```<sub>`1`</sub>` v`<sub>`2`</sub>` … seed)`, where `v`<sub>`1`</sub>, `v`<sub>`2`</sub>, … are the values yielded from the input generators, and `seed` is the current seed value. It must return two values, the yielding value and the next seed. The result generator is exhausted when any of the *gen<sub>n</sub>* generators is exhausted, at which time all the others are in an undefined state.

<!-- -->

`gfilter` *pred gen*\
`gremove` *pred gen*\
Returns generators that yield the items from the source generator, except those on which `pred` answers false or true respectively.

<!-- -->

`gstate-filter` *proc seed gen*\
Returns a generator that obtains items from the source generator and passes an item and a state (whose initial value is *seed*) as arguments to *proc*. *Proc* in turn returns two values, a boolean and a new value of the state. If the boolean is true, the item is returned; otherwise, this algorithm is repeated until *gen* is exhausted, at which point the returned generator is also exhausted. The final value of the state is discarded.

<!-- -->

`gtake` *gen k [ padding ]*\
`gdrop` *gen k*\
These are generator analogues of SRFI 1 `take` and `drop`. `Gtake` returns a generator that yields (at most) the first `k` items of the source generator, while `gdrop` returns a generator that skips the first `k` items of the source generator.

These won't complain if the source generator is exhausted before generating `k` items. By default, the generator returned by `gtake` terminates when the source generator does, but if you provide the `padding` argument, then the returned generator will yield exactly `k` items, using the `padding` value as needed to provide sufficient additional values.

<!-- -->

`gtake-while` *pred gen*\
`gdrop-while` *pred gen*\
The generator analogues of SRFI-1 `take-while` and `drop-while`. The generator returned from `gtake-while` yields items from the source generator as long as `pred` returns true for each. The generator returned from `gdrop-while` first reads and discards values from the source generator while `pred` returns true for them, then starts yielding items returned by the source.

<!-- -->

`gdelete` *item gen [ = ]*\
Creates a generator that returns whatever `gen` returns, except for any items that are the same as `item` in the sense of `=`, which defaults to `equal?`. The `=` predicate is passed exactly two arguments, of which the first is *item* and the second is an element generated by *gen*.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(generator-&gt;list (gdelete 3 (generator 1 2 3 4 5 3 6 7)))
  ⇒ (1 2 4 5 6 7)</code></pre></td>
</tr>
</tbody>
</table>

<!-- -->

`gdelete-neighbor-dups` *gen [ = ]*\
Creates a generator that returns whatever `gen` returns, except for any items that are equal to the preceding item in the sense of `=`, which defaults to `equal?`. The `=` predicate is passed exactly two arguments, of which the first was generated by `gen` before the second.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(generator-&gt;list (gdelete-neighbor-dups (list-&gt;generator &#39;(a a b c a a a d c))))
  ⇒ (a b c a d c)</code></pre></td>
</tr>
</tbody>
</table>

<!-- -->

`gindex` *value-gen index-gen*\
Creates a generator that returns elements of `value-gen` specified by the indices (non-negative exact integers) generated by `index-gen`. It is an error if the indices are not strictly increasing. The result generator is exhausted when either generator is exhausted, at which time the other is in an undefined state.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(generator-&gt;list (gindex (list-&gt;generator &#39;(a b c d e f))
                         (list-&gt;generator &#39;(0 2 4))))
  ⇒ (a c e)</code></pre></td>
</tr>
</tbody>
</table>

<!-- -->

`gselect` *value-gen truth-gen*\
Creates a generator that returns elements of `value-gen` that correspond to the values generated by `truth-gen`. If the current value of `truth-gen` is true, the current value of `value-gen` is generated, but otherwise not. The result generator is exhausted when either generator is exhausted, at which time the other is in an undefined state.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(generator-&gt;list (gselect (list-&gt;generator &#39;(a b c d e f))
                          (list-&gt;generator &#39;(#t #f #f #t #t #f))))
  ⇒ (a d e)</code></pre></td>
</tr>
</tbody>
</table>

## Consuming generated values

Unless otherwise noted, these procedures consume all the values available from the generator that is passed to them, and therefore will not return if one or more generator arguments are infinite. They have names prefixed with `generator`.

`generator->list` *generator [ k ]*\
Reads items from `generator` and returns a newly allocated list of them. By default, it reads until the generator is exhausted.

If an optional argument `k` is given, it must be a non-negative integer, and the list ends when either `k` items are consumed, or *generator* is exhausted; therefore *generator* can be infinite in this case.

<!-- -->

`generator->reverse-list` *generator [ k ]*\
Reads items from `generator` and returns a newly allocated list of them in reverse order. By default, this reads until the generator is exhausted.

If an optional argument `k` is given, it must be a non-negative integer, and the list ends when either `k` items are read, or *generator* is exhausted; therefore *generator* can be infinite in this case.

<!-- -->

`generator->vector` *generator [ k ]*\
Reads items from `generator` and returns a newly allocated vector of them. By default, it reads until the generator is exhausted.

If an optional argument `k` is given, it must be a non-negative integer, and the list ends when either `k` items are consumed, or *generator* is exhausted; therefore *generator* can be infinite in this case.

<!-- -->

`generator->vector!` *vector at generator*\
Reads items from `generator` and puts them into `vector` starting at index `at`, until `vector` is full or `generator` is exhausted. *Generator* can be infinite. The number of elements generated is returned.

<!-- -->

`generator->string` *generator [ k ]*\
Reads items from `generator` and returns a newly allocated string of them. It is an error if the items are not characters. By default, it reads until the generator is exhausted.

If an optional argument `k` is given, it must be a non-negative integer, and the string ends when either `k` items are consumed, or *generator* is exhausted; therefore *generator* can be infinite in this case.

<!-- -->

`generator-fold` *proc seed gen<sub>1</sub> gen<sub>2</sub> …*\
Works like SRFI 1 `fold` on the values generated by the generator arguments.

When one generator is given, for each value `v` generated by `gen`, `proc` is called as ``` (``proc`` ``v`` ``r``) ```, where `r` is the current accumulated result; the initial value of the accumulated result is `seed`, and the return value from `proc` becomes the next accumulated result. When `gen` is exhausted, the accumulated result at that time is returned from `generator-fold`.

When more than one generator is given, `proc` is invoked on the values returned by all the generator arguments followed by the current accumulated result. The procedure terminates when any of the *gen<sub>n</sub>* generators is exhausted, at which time all the others are in an undefined state.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(with-input-from-string &quot;a b c d e&quot;
  (lambda () (generator-fold cons &#39;z read)))
  ⇒ (e d c b a . z)</code></pre></td>
</tr>
</tbody>
</table>

<!-- -->

`generator-for-each` *proc gen gen<sub>2</sub> …*\
A generator analogue of `for-each` that consumes generated values using side effects. Repeatedly applies `proc` on the values yielded by `gen`, `gen`<sub>`2`</sub> … until any one of the generators is exhausted, at which time all the others are in an undefined state. The values returned from `proc` are discarded. Returns an unspecified value.

<!-- -->

`generator-map->list` *proc gen gen<sub>2</sub> …*\
A generator analogue of `map` that consumes generated values, processes them through a mapping function, and returns a list of the mapped values. Repeatedly applies `proc` on the values yielded by `gen`, `gen`<sub>`2`</sub> … until any one of the generators is exhausted, at which time all the others are in an undefined state. The values returned from `proc` are accumulated into a list, which is returned.

<!-- -->

`generator-find` *pred gen*\
Applies `pred` to each item from `gen`. As soon as it yields a true value, the item is returned without consuming the rest of `gen`. If `gen` is exhausted, returns `#f`.

<!-- -->

`generator-count` *pred gen*\
Returns the number of items available from the generator `gen` that satisfy the predicate `pred`.

<!-- -->

`generator-any` *pred gen*\
Applies *pred* to each item from *gen*. As soon as it yields a true value, the value is returned without consuming the rest of *gen*. If *gen* is exhausted, returns `#f`.

<!-- -->

`generator-every` *pred gen*\
Applies *pred* to each item from *gen*. As soon as it yields a false value, the value is returned without consuming the rest of *gen*. If *gen* is exhausted, returns the last value returned by *pred*, or `#t` if *pred* was never called.

<!-- -->

`generator-unfold` *gen unfold arg ...*\
Equivalent to ``` (``unfold ``` ``` eof-object? (lambda (x) x) (lambda (x) (``gen``)) (``gen``) ``` `arg` ...`)`. The values of `gen` are unfolded into the collection that `unfold` creates.

The signature of the `unfold` procedure is ``` (``unfold stop? mapper successor seed args ...``) ```. Note that the `vector-unfold` and `vector-unfold-right` of [SRFI 43](https://srfi.schemers.org/srfi-43/srfi-43.html) and [SRFI 133](https://srfi.schemers.org/srfi-133/srfi-133.html) do not have this signature and cannot be used with this procedure. To unfold into a vector, use SRFI 1's `unfold` and then apply `list->vector` to the result.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>
;; Iterates over string and unfolds into a list using SRFI 1 unfold
(generator-unfold (make-for-each-generator string-for-each &quot;abc&quot;) unfold)
  ⇒ (#\a #\b #\c)</code></pre></td>
</tr>
</tbody>
</table>

## Accumulator constructors

These procedures have names ending with `accumulator`.

`make-accumulator` *kons knil finalizer*\
Returns an accumulator that, when invoked on an object other than an end-of-file object, invokes *kons* on its argument and the accumulator's current state, using the same order as a function passed to `fold`. It then sets the accumulator's state to the value returned by *kons* and returns an unspecified value. The initial state of the accumulator is set to *knil*. However, if an end-of-file object is passed to the accumulator, it returns the result of tail-calling the procedure *finalizer* on the state. Repeated calls with an end-of-file object will reinvoke *finalizer*.

<!-- -->

`count-accumulator`\
Returns an accumulator that, when invoked on an object, adds 1 to a count inside the accumulator and returns an unspecified value. However, if an end-of-file object is passed, the accumulator returns the count.

<!-- -->

`list-accumulator`\
Returns an accumulator that, when invoked on an object, adds that object to a list inside the accumulator in order of accumulation and returns an unspecified value. However, if an end-of-file object is passed, the accumulator returns the list.

<!-- -->

`reverse-list-accumulator`\
Returns an accumulator that, when invoked on an object, adds that object to a list inside the accumulator in reverse order of accumulation and returns an unspecified value. However, if an end-of-file object is passed, the accumulator returns the list.

<!-- -->

`vector-accumulator`\
Returns an accumulator that, when invoked on an object, adds that object to a vector inside the accumulator in order of accumulation and returns an unspecified value. However, if an end-of-file object is passed, the accumulator returns the vector.

<!-- -->

`reverse-vector-accumulator`\
Returns an accumulator that, when invoked on an object, adds that object to a vector inside the accumulator in reverse order of accumulation and returns an unspecified value. However, if an end-of-file object is passed, the accumulator returns the vector.

<!-- -->

`vector-accumulator!` *vector at*\
Returns an accumulator that, when invoked on an object, adds that object to consecutive positions of *vector* starting at *at* in order of accumulation. It is an error to try to accumulate more objects than *vector* will hold. An unspecified value is returned. However, if an end-of-file object is passed, the accumulator returns *vector*.

<!-- -->

`string-accumulator`\
Returns an accumulator that, when invoked on a character, adds that character to a string inside the accumulator in order of accumulation and returns an unspecified value. However, if an end-of-file object is passed, the accumulator returns the string.

<!-- -->

`bytevector-accumulator`\
Returns an accumulator that, when invoked on a byte, adds that integer to a bytevector inside the accumulator in order of accumulation and returns an unspecified value. However, if an end-of-file object is passed, the accumulator returns the bytevector.

<!-- -->

`bytevector-accumulator!` *bytevector at*\
Returns an accumulator that, when invoked on a byte, adds that byte to consecutive positions of *bytevector* starting at *at* in order of accumulation. It is an error to try to accumulate more bytes than *vector* will hold. An unspecified value is returned. However, if an end-of-file object is passed, the accumulator returns *bytevector*.

<!-- -->

`sum-accumulator`\
Returns an accumulator that, when invoked on a number, adds that number to a sum inside the accumulator in order of accumulation and returns an unspecified value. However, if an end-of-file object is passed, the accumulator returns the sum.

<!-- -->

`product-accumulator`\
Returns an accumulator that, when invoked on a number, multiplies that number to a product inside the accumulator in order of accumulation and returns an unspecified value. However, if an end-of-file object is passed, the accumulator returns the product.

# Implementation

The sample implementation is in the SRFI 158 repository. It contains the following files:

- `srfi-158-impl.scm` - implementation of generators
- `r7rs-shim.scm` - supplementary code for non-R7RS systems
- `srfi-158.sld` - R7RS library
- `srfi-158.scm` - Chicken library
- `chicken-test.scm` - Chicken test-egg test file

# Copyright

Copyright (C) Shiro Kawai, John Cowan, Thomas Gilray (2015). All Rights Reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

______________________________________________________________________

Editor: [Arthur Gleckler](mailto:srfi-editors+at+srfi+dot+schemers+dot+org)

Last modified: Wed Jun 10 08:57:14 MST 2015
