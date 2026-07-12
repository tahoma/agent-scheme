<!-- SPDX-License-Identifier: MIT -->

<!-- SPDX-FileCopyrightText: SRFI document authors -->

# [<img src="https://srfi.schemers.org/srfi-logo.svg" class="srfi-logo" alt="SRFI surfboard logo" />](https://srfi.schemers.org/)252: Property Testing

by Antero Mejr

## Status

This SRFI is currently in *final* status. Here is
[an explanation](https://srfi.schemers.org/srfi-process.html) of each status
that a SRFI can hold. To provide input on this SRFI, please send email to
[`srfi-252@`<span class="antispam">`nospam`</span>`srfi.schemers.org`](mailto:srfi+minus+252+at+srfi+dotschemers+dot+org).
To subscribe to the list, follow
[these instructions](https://srfi.schemers.org/srfi-list-subscribe.html). You
can access previous messages via the mailing list
[archive](https://srfi-email.schemers.org/srfi-252/).

- Received: 2024-01-13
- Draft #1 published: 2024-01-13
- Draft #2 published: 2024-01-23
- Draft #3 published: 2024-02-05
- Draft #4 published: 2024-03-08
- Draft #5 published: 2024-03-21
- Draft #6 published: 2024-04-04
- Finalized: 2024-04-25

## Abstract

This defines an extension of the
[SRFI 64](https://srfi.schemers.org/srfi-64/srfi-64.html) test suite API to
support property testing. It uses
[SRFI 158](https://srfi.schemers.org/srfi-158/srfi-158.html) generators to
generate test inputs, which allows for the creation of custom input generators.
It uses [SRFI 194](https://srfi.schemers.org/srfi-194/srfi-194.html) as the
source of random data, so that the generation of random test inputs can be made
deterministic. For convenience, it also provides procedures to create test input
generators for the types specified in R7RS-small. The interface to run property
tests is similar to that of
[SRFI 64](https://srfi.schemers.org/srfi-64/srfi-64.html), and a
property-testing-specific test runner is specified in order to display the
results of the propertized tests.

## Table of contents

- [Rationale](#rationale)
- [Specification](#specification)
  - [Testing forms](#Testing-forms)
  - [Test runner](#Test-runner)
  - [Generators](#Generators)
  - [Number generators](#Number-generators)
  - [Exact number generators](#Exact-number-generators)
  - [Inexact number generators](#Inexact-number-generators)
  - [Special generators](#Special-generators)
- [Implementation](#implementation)
- [Acknowledgements](#acknowledgements)

## Rationale

*Property testing* is a software testing method where the programmer defines a
property for a piece of code. A property is a predicate procedure that accepts
one or more input arguments and returns True if the code under test exhibits
correct behavior for the given inputs. Then, the property testing library
generates pseudorandom ranges of inputs of the correct types, and applies them
to the property. After running many tests, if application of inputs to the
property ever returns False, then it can be assumed that there is a bug in the
code, provided that the property itself is correct.

Property testing can expose bugs that would not be found using a small number of
hand-written test cases. In addition to generating random inputs, property
testing libraries may also generate inputs that commonly cause incorrect
behavior, such as `0` or `NaN`.

Property testing offers a more rigorous alternative to traditional unit testing.
In terms of the learning and effort required for use, it serves as a middle
ground between unit tests and formal verification methods. Properties can be
written as stricter specifiers of program behavior than individual test cases.

Property testing was popularized by the QuickCheck library for Haskell, and has
since spread to other languages. The following libraries were referenced in the
creation of this document, in order of descending influence:

Hypothesis, QuickCheck, Scheme-Check, and QuickCheck for Racket.

Property testing requires a testing environment, generators, and random sources
of data. These dependencies are provided by SRFI
[64](https://srfi.schemers.org/srfi-64/srfi-64.html),
[158](https://srfi.schemers.org/srfi-158/srfi-158.html), and
[194](https://srfi.schemers.org/srfi-194/srfi-194.html), respectively. Users of
those SRFIs will note the familiar interfaces presented here.
[SRFI 64](https://srfi.schemers.org/srfi-64/srfi-64.html) is chosen to provide
the testing environment over the simpler
[SRFI 78](https://srfi.schemers.org/srfi-78/srfi-78.html). This is because
property testing is often more complex than unit testing, so a more extensive
testing environment is required.

The Scheme-Check library provided an implementation of property testing for a
limited set of Scheme implementations. However, it has been unmaintained for
many years, and is not compatible with R7RS. Introducing a flexible property
testing system as an SRFI will standardize a stable interface that can be used
in multiple implementations.

Property testing is also known as *generative testing* or *property-based
testing*. This document uses the short name in order to have shorter
identifiers.

## Specification

### Testing forms

The following procedure-like forms may be implemented as procedures or macros.

It is an error to invoke the testing procedures if there is no current test
runner.

``` (test-property`` property generator-list [runs]``) ```\
Run a property test.

The `property` argument is a predicate procedure with an arity equal to the
length of the `generator-list` argument. The `generator-list` argument must be a
proper list containing
[SRFI 158](https://srfi.schemers.org/srfi-158/srfi-158.html) generators. The
`property` procedure must be applied to the values returned by the
`generator-list` such that the value generated by the `car` position of the
`generator-list` will be the first argument to `property`, and so on.

The `runs` argument, if provided, must be a non-negative integer. This argument
specifies how many times the property will be tested with newly generated
inputs. If not provided, the implementation may choose how many times to run the
test.

It is an error if any generator in `generator-list` is exhausted before the
specified number of `runs` is completed.

Property tests can be named by placing them inside an
[SRFI 64](https://srfi.schemers.org/srfi-64/srfi-64.html) test group.

```example

(define (my-square z) (* z z))
(define (my-square-property z) (= (sqrt (my-square z)) z))

;; Test the property ten times.
(test-begin "my-square-prop-test")
(test-property my-square-property (list (integer-generator)) 10)
(test-end "my-square-prop-test")
```

<!-- -->

``` (test-property-expect-fail`` property generator-list [runs]``) ```\
Run a property test that is expected to fail for all inputs. This only affects
test reporting, not test execution.

```example

(define (my-square z) (+ z 1)) ; Incorrect for all inputs
(define (my-square-property z) (= (sqrt (my-square z)) z))

(test-property-expect-fail my-square-property
  (list (integer-generator)))
```

<!-- -->

``` (test-property-skip`` property generator-list [runs]``) ```\
Do not run a property test. The active test-runner will skip the test, and no
runs will be performed.

```example

(test-property-skip (lambda (x) #t) (list (integer-generator)))
```

<!-- -->

``` (test-property-error`` property generator-list [runs]``) ```\
Run a property test that is expected to raise an exception for all inputs. The
exception raised may be of any type.

```example

(define (my-square z) (* z "foo")) ; will cause an error
(define (my-square-property z) (= (sqrt (my-square z)) z))

(test-property-error my-square-property (list (integer-generator)))
```

<!-- -->

``` (test-property-error-type`` error-type property generator-list [runs]``) ```\
Run a property test that is expected to raise a specific type of exception for
all inputs. In order for the test to pass, the exception raised must match the
error type specified by the `error-type` argument. The error type may be
implementation-specific, or one specified in
[SRFI 36](https://srfi.schemers.org/srfi-36/srfi-36.html).

```example

(define (cause-read-error str)
  (read (open-input-string (string-append ")" str))))

(define (cause-read-error-property str)
  (symbol? (cause-read-error str)))

(test-property-error-type
  &read-error cause-read-error-property (list (string-generator)))
```

### Test runner

`(property-test-runner)`\
Creates a [SRFI 64](https://srfi.schemers.org/srfi-64/srfi-64.html) test-runner.
The test runner should be able to display or write the results of all the runs
of a property-based test.

### Generators

The generator procedures in this SRFI must be implemented using
[SRFI 194](https://srfi.schemers.org/srfi-194/srfi-194.html), such that the
`current-random-source` parameter can be configured to facilitate deterministic
generation of property test inputs.

`(boolean-generator)`\
Create an infinite generator that returns `#t` and `#f`. The generator should
return the sequence `(#t #f)` first, then a uniformly random distribution of
`#t` and `#f`.

```example

(define bool-gen (boolean-generator))

(bool-gen) ; => #t
(bool-gen) ; => #f
(bool-gen) ; => #t or #f
```

<!-- -->

`(bytevector-generator)`\
Create an infinite generator that returns objects that fulfill the `bytevector?`
predicate. The generator should return an empty bytevector first, then a series
of bytevectors with uniformly randomly distributed contents and lengths. The
maximum length of the generated bytevectors is chosen by the implementation.

```example

(define bytevector-gen (bytevector-generator))

(bytevector-gen) ; => #u8()
(bytevector-gen) ; => #u8(...)
```

<!-- -->

`(char-generator)`\
Create an infinite generator that returns objects that fulfill the `char?`
predicate. The generator should return the character `#\null` first, then a
uniformly random distribution of characters.

```example

(define char-gen (char-generator))

(char-gen) ; => #\null
(char-gen) ; => #\something
```

<!-- -->

`(string-generator)`\
Create an infinite generator that returns strings. The generator should return
an empty string first, then a series of strings with uniformly randomly
distributed contents and lengths. The maximum length of the generated strings is
chosen by the implementation.

```example

(define string-gen (string-generator))

(string-gen) ; => ""
(string-gen) ; => "..."
```

<!-- -->

`(symbol-generator)`\
Create an infinite generator that returns symbols. The generator should return
the empty symbol `||` first, then a series of randomized symbols.

```example

(define symbol-gen (symbol-generator))

(symbol-gen) ; => ||
(symbol-gen) ; => 'something
```

### Number generators

The ranges of the random numbers returned by the numeric generators below are
defined by the implementation. Applications that require a specific range of
numeric test inputs are encouraged to create custom generators using
[SRFI 158](https://srfi.schemers.org/srfi-158/srfi-158.html).

`(complex-generator)`\
Create an infinite generator that returns objects that fulfill the `complex?`
predicate. The real and imaginary parts of the complex numbers may be exact or
inexact. The generator should return a uniformly random sampling of the values
generated by `exact-complex-generator` and `inexact-complex-generator`.

If the implementation does not have support for `exact-complex`, this generator
should be an alias for `inexact-complex-generator`.

```example
(define complex-gen (complex-generator))

(complex-gen) ; => 0 or 0.0
```

<!-- -->

`(integer-generator)`\
Create an infinite generator that returns objects that fulfill the `integer?`
predicate. The generator should return a uniformly random sampling of the values
generated by `exact-integer-generator` and `inexact-integer-generator`.

```example
(define integer-gen (integer-generator))

(integer-gen) ; => 0 or 0.0
```

<!-- -->

`(number-generator)`\
Create an infinite generator that returns objects that fulfill the `number?`
predicate. The generator should return a uniformly random sampling of the values
generated by `exact-number-generator` and `inexact-number-generator`.

```example
(define number-gen (number-generator))

(number-gen) ; => 0 or 0.0
```

<!-- -->

`(rational-generator)`\
Create an infinite generator that returns objects that fulfill the `rational?`
predicate. The generator should return a uniformly random sampling of the values
generated by `exact-rational-generator` and `inexact-rational-generator`.

```example
(define rational-gen (rational-generator))

(rational-gen) ; => 0 or 0.0
```

<!-- -->

`(real-generator)`\
Create an infinite generator that returns objects that fulfill the `real?`
predicate. The generator should return a uniformly random sampling of the values
generated by `exact-real-generator` and `inexact-real-generator`.

```example
(define real-gen (real-generator))

(real-gen) ; => 0 or 0.0
```

### Exact number generators

`(exact-complex-generator)`\
Create an infinite generator that returns objects that fulfill the `exact?` and
`complex?` predicates. The real and imaginary parts of the complex numbers must
be exact. The generator should return the sequence

```
0 1 -1 1/2 -1/2 0+i 0-i 1+i 1-i -1+i -1-i
1/2+1/2i 1/2-1/2i -1/2+1/2i -1/2-1/2i
```

first, then a uniformly random distribution of exact complex numbers. Elements
of the above sequence may be omitted if they are not distinguished in the
implementation.

If the implementation does not support the `exact-complex` feature, it is an
error to call this procedure.

```example
(define exact-complex-gen (exact-complex-generator))

(exact-complex-gen) ; => 0
```

<!-- -->

`(exact-integer-generator)`\
Create an infinite generator that returns objects that fulfill the `exact?` and
`integer?` predicates. The generator should return the sequence

```
0 1 -1
```

first, then a uniformly random distribution of exact integers. Elements of the
above sequence may be omitted if they are not distinguished in the
implementation.

```example
(define exact-int-gen (exact-integer-generator))

(exact-int-gen) ; => 0
```

<!-- -->

`(exact-integer-complex-generator)`\
Create an infinite generator that returns objects that fulfill the `exact?` and
`complex?` predicates. The real and imaginary parts of the complex numbers must
be exact integers. The generator should return the sequence

```
0 1 -1 0+i 0-i 1+i 1-i -1+i -1-i
```

first, then a uniformly random distribution of exact complex numbers with
integer components. Elements of the above sequence may be omitted if they are
not distinguished in the implementation.

If the implementation does not support the `exact-complex` feature, it is an
error to call this procedure.

```example
(define exact-int-comp-gen (exact-integer-complex-generator))

(exact-int-comp-gen) ; => 0
```

<!-- -->

`(exact-number-generator)`\
Create an infinite generator that returns objects that fulfill the `exact?`
predicate. The generator should return the sequence

```
0 1 -1 1/2 -1/2 0+i 0-i 1+i 1-i -1+i -1-i
1/2+1/2i 1/2-1/2i -1/2+1/2i -1/2-1/2i
```

first, then a uniformly random distribution of exact numbers. Elements of the
above sequence may be omitted if they are not distinguished in the
implementation.

```example
(define exact-gen (exact-number-generator))

(exact-gen) ; => 0
```

<!-- -->

`(exact-rational-generator)`\
Create an infinite generator that returns objects that fulfill the `exact?` and
`rational?` predicates. The generator should return the sequence

```
0 1 -1 1/2 -1/2
```

first, then a uniformly random distribution of exact rational numbers. Elements
of the above sequence may be omitted if they are not distinguished in the
implementation.

```example
(define exact-rational-gen (exact-rational-generator))

(exact-rational-gen) ; => 0
```

<!-- -->

`(exact-real-generator)`\
Create an infinite generator that returns objects that fulfill the `exact?` and
`real?` predicates. The generator should return the sequence

```
0 1 -1 1/2 -1/2
```

first, then a uniformly random distribution of exact real numbers. Elements of
the above sequence may be omitted if they are not distinguished in the
implementation.

```example
(define exact-real-gen (exact-real-generator))

(exact-real-gen) ; => 0
```

### Inexact number generators

`(inexact-complex-generator)`\
Create an infinite generator that returns objects that fulfill the `inexact?`
and `complex?` predicates. The real and imaginary parts of the complex numbers
must be inexact. The generator should return the sequence

```
0.0 -0.0 0.5 -0.5 1.0 -1.0
0.0+1.0i 0.0-1.0i -0.0+1.0i -0.0-1.0i
0.5+0.5i 0.5-0.5i -0.5+0.5i -0.5-0.5i
1.0+1.0i 1.0-1.0i -1.0+1.0i -1.0-1.0i
+inf.0+inf.0i +inf.0-inf.0i -inf.0+inf.0i -inf.0-inf.0i
+nan.0+nan.0i
+inf.0 -inf.0 +nan.0
```

first, then a uniformly random distribution of inexact complex numbers. Elements
of the above sequence may be omitted if they are not distinguished in the
implementation.

```example
(define inexact-complex-gen (inexact-complex-generator))

(inexact-complex-gen) ; => 0.0+0.0i
```

<!-- -->

`(inexact-integer-generator)`\
Create an infinite generator that returns objects that fulfill the `inexact?`
and `integer?` predicates. The generator should return the sequence

```
0.0 -0.0 1.0 -1.0
```

first, then a uniformly random distribution of inexact integers. Elements of the
above sequence may be omitted if they are not distinguished in the
implementation.

```example
(define inexact-int-gen (inexact-integer-generator))

(inexact-int-gen) ; => 0.0
```

<!-- -->

`(inexact-number-generator)`\
Create an infinite generator that returns objects that fulfill the `inexact?`
predicate. The generator should return the sequence

```
0.0 -0.0 0.5 -0.5 1.0 -1.0
0.0+1.0i 0.0-1.0i -0.0+1.0i -0.0-1.0i
0.5+0.5i 0.5-0.5i -0.5+0.5i -0.5-0.5i
1.0+1.0i 1.0-1.0i -1.0+1.0i -1.0-1.0i
+inf.0+inf.0i +inf.0-inf.0i -inf.0+inf.0i -inf.0-inf.0i
+nan.0+nan.0i
+inf.0 -inf.0 +nan.0
```

first, then a uniformly random distribution of inexact numbers. Elements of the
above sequence may be omitted if they are not distinguished in the
implementation.

```example
(define inexact-gen (inexact-number-generator))

(inexact-gen) ; => 0.0
```

<!-- -->

`(inexact-rational-generator)`\
Create an infinite generator that returns objects that fulfill the `inexact?`
and `rational?` predicates. The generator should return the sequence

```
0.0 -0.0 0.5 -0.5 1.0 -1.0
```

first, then a uniformly random distribution of inexact rational numbers.
Elements of the above sequence may be omitted if they are not distinguished in
the implementation.

```example
(define inexact-rational-gen (inexact-rational-generator))

(inexact-rational-gen) ; => 0.0
```

<!-- -->

`(inexact-real-generator)`\
Create an infinite generator that returns objects that fulfill the `inexact?`
and `real?` predicates. The generator should return the sequence

```
0.0 -0.0 0.5 -0.5 1.0 -1.0 +inf.0 -inf.0 +nan.0
```

first, then a uniformly random distribution of inexact real numbers. Elements of
the above sequence may be omitted if they are not distinguished in the
implementation.

```example
(define inexact-real-gen (inexact-real-generator))

(inexact-real-gen) ; => 0.0
```

### Special generators

``` (list-generator-of`` subgenerator [max-length]``) ```\
Create an infinite generator that returns lists. The generator should return the
empty list first. Then it should return lists containing values generated by
`subgenerator`, with a length uniformly randomly distributed between 1 and
`max-length`, if specified. If the `max-length` argument is not specified, the
implementation may select the size range.

```example

(define list-gen (list-generator-of (integer-generator)))

(list-gen) ; => '()
(list-gen) ; => '(0 1 -1 ...)
```

<!-- -->

``` (pair-generator-of`` subgenerator-car [subgenerator-cdr]``) ```\
Create an infinite generator that returns pairs. The contents of the pairs are
values generated by the `subgenerator-car`, and if specified, `subgenerator-cdr`
arguments. If both subgenerator arguments are specified, `subgenerator-car` will
populate the `car`, while `subgenerator-cdr` will populate the `cdr` of the
pair. If the `subgenerator-cdr` argument is not specified, `subgenerator-car`
will be used to generate both elements of the pair.

```example

(define pair-gen
  (pair-generator-of (integer-generator) (boolean-generator)))

(pair-gen) ; => '(0 . #t)
```

<!-- -->

``` (procedure-generator-of`` subgenerator``) ```\
Create an infinite generator that returns procedures. The return values of those
procedures are values generated by the `subgenerator` argument. The procedures
generated should be variadic.

```example

(define proc-gen (procedure-generator-of (boolean-generator)))

((proc-gen) 1)           ; => #t
((proc-gen) 'foo 'bar)   ; => #f
((proc-gen) "x" "y" "z") ; => #t or #f
```

<!-- -->

``` (vector-generator-of`` subgenerator [max-length]``) ```\
Create an infinite generator that returns vectors. The generator should return
the empty vector first. Then it should return vectors containing values
generated by `subgenerator`, with a length uniformly randomly distributed
between 1 and `max-length`, if specified. If the `max-length` argument is not
specified, the implementation may select the size range.

```example

(define vector-gen (vector-generator-of (boolean-generator)))

(vector-gen) ; => #()
(vector-gen) ; => #(#t #f ...)
```

## Implementation

A conformant sample implementation is provided. It depends on R7RS-small,
[SRFI 1](https://srfi.schemers.org/srfi-1/srfi-1.html),
[SRFI 64](https://srfi.schemers.org/srfi-64/srfi-64.html),
[SRFI 158](https://srfi.schemers.org/srfi-158/srfi-158.html),
[SRFI 194](https://srfi.schemers.org/srfi-194/srfi-194.html), and optionally,
[SRFI 143](https://srfi.schemers.org/srfi-143/srfi-143.html) and
[SRFI 144](https://srfi.schemers.org/srfi-144/srfi-144.html). However, there are
values in the implementation that may need to be adjusted. The size of the
generated test inputs, and the number of cases to run, should be tuned depending
on the performance characteristics of the implementation. These tunable values
are denoted by comments in the code.

The sample implementation does not perform test case reduction, also known as
shrinking. Other implementations may choose to do so.

The `property-test-runner` provided by the sample implementation is the same as
the `test-runner-simple` from
[SRFI 64](https://srfi.schemers.org/srfi-64/srfi-64.html). However,
implementations should define a property-testing-specific runner that displays
results in a well-organized fashion.

The sample implementation is available
[in the repo](https://github.com/scheme-requests-for-implementation/srfi-252) or
[directly](https://srfi.schemers.org/srfi-252/property-test.sld).

A test suite for implementations is available
[in the repo](https://github.com/scheme-requests-for-implementation/srfi-252/blob/master/property-test-tests.scm)
or [directly](https://srfi.schemers.org/srfi-252/property-test-tests.scm).

## Acknowledgements

Thank you to Bradley Lucier, John Cowan, Marc Nieper-Wißkirchen, Per Bothner,
and Shiro Kawai for their input during the drafting process.

## Copyright

© 2024 Antero Mejr.

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
