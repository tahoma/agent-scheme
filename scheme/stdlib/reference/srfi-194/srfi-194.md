<!-- SPDX-License-Identifier: MIT -->

<!-- SPDX-FileCopyrightText: SRFI document authors -->

# [<img src="https://srfi.schemers.org/srfi-logo.svg" class="srfi-logo" alt="SRFI logo" />](https://srfi.schemers.org/)194: Random data generators

by Shiro Kawai (design), Arvydas Silanskas (implementation), Linas Vepštas
(implementation), and John Cowan (editor and shepherd)

## Status

This SRFI is currently in *final* status. Here is
[an explanation](https://srfi.schemers.org/srfi-process.html) of each status
that a SRFI can hold. To provide input on this SRFI, please send email to
[`srfi-194@`<span class="antispam">`nospam`</span>`srfi.schemers.org`](mailto:srfi+minus+194+at+srfi+dotschemers+dot+org).
To subscribe to the list, follow
[these instructions](https://srfi.schemers.org/srfi-list-subscribe.html). You
can access previous messages via the mailing list
[archive](https://srfi-email.schemers.org/srfi-194).

- Received: 2020-05-03
- Draft #1 published: 2020-05-14
- Draft #2 published: 2020-06-16
- Draft #3 published: 2020-08-06
- Draft #4 published: 2020-08-22
- Finalized: 2020-08-26
- 2024-01-17 (Fixed definition of
  [make-random-source-generator](#make_random_source_generator).)

## Abstract

This SRFI defines a set of
[SRFI 158](https://srfi.schemers.org/srfi-158/srfi-158.html) generators and
generator makers that yield random data of specific ranges and distributions. It
is intended to be implemented on top of
[SRFI 27](https://srfi.schemers.org/srfi-27/srfi-27.html), which provides the
underlying source of random integers and floats.

## Rationale

Most of SRFI 27 is involved with creating and managing random sources; there are
only two generators for getting random numbers, namely `random-integer` to get a
random but bounded non-negative exact integer, and `random-real` to get a random
inexact real number in the unit interval. (When making use of a non-default
random number source, the otherwise equivalent procedures
`random-source-make-integers` and `random-source-make-reals` can be used
instead.)

However, it's very often useful to loosen these limitations, to provide random
exact integers or real numbers within any desired range. In order to make them
easy to use, they are exposed as generators: choose your bounds and you get a
procedure which can be called without any arguments. This allows them to
participate freely in the SRFI 158 infrastructure. In the same way, random
booleans, random characters chosen from a seed string, and strings of random
lengths up to a limit and with characters drawn from the same kind of seed
string are all available.

All these use a uniform distribution of random numbers, but normal, exponential,
geometric, and Poisson distributions also have their uses. Finally, if multiple
generators are available, uniform and weighted choices can be made from them to
produce a unified output stream.

## Specification

### Current random source

`current-random-source`\
An R7RS or [SRFI 39](https://srfi.schemers.org/srfi-39/srfi-39.html) parameter
that provides the random source for all the procedures in this SRFI. Its initial
value is `default-random-source` from SRFI 27. Use `parameterize` to specify a
dynamic scope in which a different SRFI 27 random source is used when creating
new generators. The behavior of existing generators is not affected by changes
to this parameter.

``` (with-random-source`` random-source thunk``) ```\
Binds `current-random-source` to `random-source` and then invokes `thunk`.

``` (make-random-source-generator`` i``) ```\
Returns a generator of random sources. Each invocation of the generator returns
a new random source created by calling `make-random-source` (SRFI 27). The new
random source is passed to `random-source-pseudo-randomize!` with `i`, and
successive integers `j` (starting with 0), before being returned.

The random sources are guaranteed to be distinct as long as `i` and `j` are not
too large and the generator is not called too many times. What counts as "too
large/many" depends on the SRFI 27 implementation; the sample implementation
works correctly if `i` < 2<sup>63</sup> and `j` < 2<sup>51</sup> and no more
than 2<sup>76</sup> values are generated.

### Uniform distributions

These generators generate uniformly distributed values of various simple Scheme
types.

In the following examples, we use the `generator->list` procedure to show some
concrete data from the generators.

``` (make-random-integer-generator`` lower-bound upper-bound``) ```\
Returns a generator of exact integers between `lower-bound` (inclusive) and
`upper-bound` (exclusive) uniformly. It is an error if the bounds are not exact
integers or if the specified interval is empty.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>;; A die roller
(define die (make-random-integer-generator 1 7))
&#10;;; Roll the die 10 times
(generator-&gt;list die 10)
 ⇒ (6 6 2 4 2 5 5 1 2 2)</code></pre></td>
</tr>
</tbody>
</table>

<!-- -->

``` (make-random-u1-generator``) ```\
``` (make-random-u8-generator``) ```\
``` (make-random-s8-generator``) ```\
``` (make-random-u16-generator``) ```\
``` (make-random-s16-generator``) ```\
``` (make-random-u32-generator``) ```\
``` (make-random-s32-generator``) ```\
``` (make-random-u64-generator``) ```\
``` (make-random-s64-generator``) ```\
These procedures return generators of exact integers in the ranges of 1-bit
unsigned and 8, 16, 32, and 64-bit signed and unsigned values respectively.
These values can be stored in the corresponding homogeneous vectors of
[SRFI 160](https://srfi.schemers.org/srfi-160/srfi-160.html) and
[SRFI 178](https://srfi.schemers.org/srfi-178/srfi-178.html).

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(generator-&gt;list (make-random-s8-generator) 10)
 ⇒ (20 -101 50 -99 -111 -28 -19 -61 39 110)</code></pre></td>
</tr>
</tbody>
</table>

``` (clamp-real-number`` lower-bound upper-bound value``) ```\
Returns `value` clamped to be between *lower-bound* and *upper-bound*,
inclusive. Note that this procedure works with either exact or inexact numbers,
but will produce strange results with a mixture of the two. It is an error if
the specified interval is empty.

``` (make-random-real-generator`` lower-bound upper-bound``) ```\
Returns a generator that generates inexact real numbers uniformly. (Note that
this is not the same as returning all possible IEEE floats within the stated
range uniformly.) The procedure returns reals between `lower-bound` and
`upper-bound`, both inclusive. The similar procedure `random-real` in SRFI 27
uses the exclusive bounds 0.0 and 1.0. It is an error if the specified interval
is empty.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(define uniform-100 (make-random-real-generator 0 100))
&#10;(generator-&gt;list uniform-100 3)
 ⇒ (81.67965004942268 81.84927577572596 53.02443813660833)</code></pre></td>
</tr>
</tbody>
</table>

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(define generate-from-0-below-1
  (gfilter (lambda (r) (not (= r 1.0))) (make-random-real-generator 0.0 1.0)))</code></pre></td>
</tr>
</tbody>
</table>

``` (make-random-rectangular-generator`` real-lower-bound real-upper-bound imaginary-lower-bound imag-upper-bound``) ```\
Returns a generator that generates inexact complex numbers uniformly. The
procedure returns complex numbers in a rectangle whose real part is between
`real-lower-bound` and `real-upper-bound` (both inclusive), and whose imaginary
part is between `imag-lower-bound` and `imag-upper-bound` (both inclusive). It
is an error if either of the specified intervals is empty.

``` (make-random-polar-generator``  ```\[`origin ] magnitude-lower-bound magnitude-upper-bound`\[```  angle-lower-bound angle-upper-bound ]``) ```\
Returns a generator that generates inexact complex numbers uniformly. The
procedure returns complex numbers in a sector of an annulus whose origin point
is `origin`, whose magnitude is between `magnitude-lower-bound` and
`magnitude-upper-bound` (both inclusive), and whose angle is between
`angle-lower-bound` and `angle-upper-bound` (both inclusive). It is an error if
either of the specified intervals is empty. The default value of `origin` is
0+0`i`, the default value of `angle-lower-bound` is 0, and the default value of
`angle-upper-bound` is 2`π`. If all three are defaulted, the resulting shape is
a disk centered on the origin.

`(make-random-boolean-generator)`\
Generates boolean values (`#f` and `#t`) with equal probability.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>(generator-&gt;list (make-random-boolean-generator) 10)
 ⇒ (#f #f #t #f #f #t #f #f #f #f)</code></pre></td>
</tr>
</tbody>
</table>

``` (make-random-char-generator`` string``) ```\
Returns a generator that generates characters in `string` uniformly. Note that
the characters in `string` need not be distinct, which allows simple weighting.
It is an error if `string` is empty.

<table>
<colgroup>
<col style="width: 50%" />
<col style="width: 50%" />
</colgroup>
<tbody>
<tr>
<td> </td>
<td><pre class="example"><code>
(define alphanumerics &quot;ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789&quot;)
(define alphanumeric-chars (make-random-char-generator alphanumerics))
&#10;(generator-&gt;list alphanumeric-chars 10)
 ⇒ (#\f #\m #\3 #\S #\z #\m #\x #\S #\l #\y)</code></pre></td>
</tr>
</tbody>
</table>

``` (make-random-string-generator`` k string``) ```\
Returns a generator that generates random strings whose characters are in
`string`. Note that the characters in `string` need not be distinct, which
allows simple weighting. The length of the strings is uniformly distributed
between 0 (inclusive) and the length of `string` (exclusive). It is an error if
`string` is empty.

### Nonuniform distributions

``` (make-bernoulli-generator`` p``) ```\
Returns a generator that yields 1 with probability `p` and 0 with probability 1
\- `p`.

``` (make-binomial-generator ``n p``) ```\
Returns a binomial random variate generator, which conceptually is the sum of
`n` Bernoulli-`p` random variables.

``` (make-categorical-generator`` weight-vec``) ```\
Returns a generator that yields an exact integer `n` between 0 (inclusive) and
the length of `weight-vec` (inclusive) with probability equal to the `n`th
element of `weight-vec` divided by the sum of its elements. It is an error if
any element of `weight-vec` is negative or their sum is zero.

``` (make-normal-generator`` [ mean [ deviation ] ]``) ```\
Returns a generator that yields real numbers from a normal distribution with the
specified `mean` and `deviation`. The default value of `mean` is 0.0 and
`deviation` is 1.0.

<!-- -->

``` (make-exponential-generator`` mean``) ```\
Returns a generator that yields real numbers from an exponential distribution
with the specified `mean`.

<!-- -->

``` (make-geometric-generator`` p``) ```\
Returns a generator that yields integers from the geometric distribution with
success probability `p` (0 \<= p \<= 1). The mean is `1/p` and variance is
`(1-p)/p^2`.

<!-- -->

``` (make-poisson-generator`` L``) ```\
Returns a generator that yields integers from the Poisson distribution with mean
`L`, variance `L`.

<!-- -->

``` (make-zipf-generator`` N [ s [ q ] ]``) ```\
Returns a generator that yields exact integers `k` from the generalized Zipf
distribution 1`/(k+q`<sup>`s`</sup> such that 1 ≤ k ≤ `N`). The default value of
`s` is 1.0 and the default value of `q` is 0.0. Parameters outside the following
ranges are likely to result in overflows or loss of precision: -10 < `s` < 100,
-0.5 < `q` < 2<sup>8</sup>, and 1 ≤ `N`.

The following three procedures generate points of real `k`-dimensional Euclidean
space. These points are modeled as Scheme vectors of real numbers of length `k`.

``` (make-sphere-generator ``n``) ```\
Returns a generator that generates points in real (`n` + 1)-dimensional
Euclidean space that are randomly, independently distributed on the surface of
an `n`-sphere. That is, the vectors are of unit length.

<!-- -->

``` (make-ellipsoid-generator ``axes``) ```\
Returns a generator that generates points in real (`n` + 1)-dimensional
Euclidean space that are randomly, independently distributed on the surface of
an `n`-ellipsoid. The ellipsoid is specified by the `axes` argument, which must
be a vector of real numbers giving the lengths of the axes. Given
`axes = (a, b, ...)`, then the generated vectors `v =(x, y, ...)` obey 1 =
`x`<sup>2</sup>/`a`<sup>2</sup> + `y`<sup>2</sup>/`b`<sup>2</sup> + ... .

<!-- -->

``` (make-ball-generator ``dimensions``) ```\
Returns a generator that generates points in real `n`-dimensional Euclidean
space corresponding to the inside of an `n`-ball. The `dimensions` argument can
be either a vector of `n` real numbers, in which case they are taken as the axes
of an ellipsoid, or it can be an integer, in which case it's treated as the
dimension `n`, (i.e. the generated vectors are inside a ball of radius 1.)

### Generator operations

``` (gsampling`` generator ``` ...`)`\
Takes the `generators` and returns a new generator. Every time the resulting
generator is called, it picks one of the input generators with equal
probability, then calls it to get a value. When all the generators are exhausted
or no generators are specified, the new generator returns an end-of-file object.

## Implementation

The sample implementation is in the
[repository](https://github.com/scheme-requests-for-implementation/srfi-194) of
this SRFI and in
[this `.tgz` file](https://srfi.schemers.org/srfi-194/srfi-194.tgz). An R7RS
library file and a separate file containing the actual implementation are
provided, along with a test file that works with
[SRFI 64](https://srfi.schemers.org/srfi-64/srfi-64.html). The library itself
depends on either [SRFI 121](https://srfi.schemers.org/srfi-121/srfi-121.html)
or [SRFI 158](https://srfi.schemers.org/srfi-158/srfi-158.html), and of course
[SRFI 27](https://srfi.schemers.org/srfi-27/srfi-27.html).

## Acknowledgements

This SRFI began life as Shiro Kawai's specification for `data.random`, a Gauche
library. Many of the names have been changed to fit in better with SRFI 158
names, but the essence is the same. John Cowan made those and other revisions,
and then put the SRFI on the back burner until he got around to implementing it.
Arvydas Silanskas began by asking why the next R7RS-large ballot was so delayed,
and ended up volunteering to write code for the parts already specified. This
SRFI is his first such implementation, and in the process of writing it he found
a number of errors in the specification as well, which John was very glad to be
told about.

During the SRFI review process, the following additional generators were added:
the binomial and random-source generators written by Brad Lucier, and the Zipf,
sphere, and ball generators written by Linas Vepstas.

Thanks also to the Scheme community and especially the contributors to the SRFI
194 mailing list, including Shiro Kawai and Marc Nieper-Wißkirchen.

## Copyright

© 2020 John Cowan.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice (including the next
paragraph) shall be included in all copies or substantial portions of the
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

______________________________________________________________________

Editor: [Arthur A. Gleckler](mailto:srfi-editors+at+srfi+dot+schemers+dot+org)
