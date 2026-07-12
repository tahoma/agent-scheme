<!-- SPDX-License-Identifier: MIT -->

<!-- SPDX-FileCopyrightText: SRFI document authors -->

# Title

Assumptions

# Author

Marc Nieper-Wißkirchen

# Status

This SRFI is currently in *final* status. Here is [an explanation](https://srfi.schemers.org/srfi-process.html) of each status that a SRFI can hold. To provide input on this SRFI, please send email to [`srfi-145@`<span class="antispam">`nospam`</span>`srfi.schemers.org`](mailto:srfi+minus+145+at+srfi+dotschemers+dot+org). To subscribe to the list, follow [these instructions](http://srfi.schemers.org/srfi-list-subscribe.html). You can access previous messages via the mailing list [archive](https://srfi-email.schemers.org/srfi-145).

- Received: 2016-12-17
- 60-day deadline: 2017-02-16
- Draft #1 published: 2016-12-18
- Draft #2 published: 2016-12-20
- Draft #3 published: 2016-12-31
- Draft #4 published: 2017-01-08
- Finalized: 2017-03-31
- Revised to fix errata:
  - 2017-04-03 (Fixed example.)
  - 2020-08-18 (Fixed [first sample implementation](#simple-implementation) of `assume` to return `obj` on success, as required by the specification.)

# Abstract

A means to denote the invalidity of certain code paths in a Scheme program is proposed. It allows Scheme code to turn the evaluation into a user-defined error that need not be signalled by the implementation. Optimizing compilers may use these denotations to produce better code and to issue better warnings about dead code.

# Issues

There are currently no issues.

# Rationale

The R7RS requires some operations to signal an error when they fail. Signalling an error means, among other things, that a non-continuable exception is raised. Such exceptions can be handled by exception handlers; in particular, signalling an error is observable behaviour in a Scheme program.

In all other error situations, implementations — while not required — are encouraged to detect and report the error, but they do not have to signal the error as if `raise` was invoked.

The `error` procedure of the R7RS gives a Scheme program a means to signal user-defined errors. However, there is no canonical way to turn the evaluation of a piece of Scheme code into a user-defined error that is not signalled. Consider the following definition:

```
(define (f x)
  (unless (exact-integer? x)
    (error "f: argument is not an integer" x))
  (g (* x x)))
```

It is the intention to express that invoking the procedure `f` with any argument but an exact integer is an error. However it is (usually) not important that such an error situation can be handled by an exception handler (in the Java programming language, one would probably use an *unchecked exception*). So the above program is over-specifying. While an optimizing compiler on which the definition is evaluated may assume that `x` is an exact integer after the first expression in the procedure body (and thus may emit specialised monomorphic code afterwards), it must not eliminate the first expression in the procedure body because calling `f` with a non-exact-integer argument has different observable behaviour than calling just `(g (* x x))`.

Given that `f` is called a lot in the code and that performance is important, the programmer may thus decide that it is better to comment out the test at the beginning of the procedure body in non-debug situations:

```
(define (f x)
  (cond-expand
    (debug
     (unless (exact-integer? x)
       (error "f: argument is not an integer" x)))
    (else #f))
  (g (* x x)))
```

However, this code (when the feature identifier `debug` is not defined) may even be less performant than the first solution: An optimizing implementation now has no way (in case `g` is not well-known) to detect that `x` is always supposed to be an exact integer in the code path of the procedure body. So the compiler has to emit slow, polymorphic code that works on either number type.

To remedy these problems, this SRFI specifies a way to denote error situations that are not supposed to be recoverable and which is helpful for debugging and for the control and data flow analysis of optimizing compilers. For implementations conforming to this SRFI, the procedure `f` can be rewritten as follows:

```
(define (f x)
  (assume (exact-integer? x) "f takes integer arguments" x)
  (g (* x x)))
```

An optimizing compiler may deduce that `x` is an exact integer after the first expression in the procedure body so may emit specialised monomorphic code. However, in non-debug mode, an optimizing compiler may also remove the whole test at the beginning of the procedure body because the test has only one branch that does not lead into an error situation.

Another interesting use case is the following, which employs an assumption that would fail unconditionally:

```
 (define (foo x a b)
   (case x
    ((plus) (+ a b))
    ((minus) (- a b))
    (else (assume #f "valid operators are plus/minus" x))))
```

This definition allows a compiler to treat `(foo 'times 3 5)` as a compile-time error.

One should note that error situations in which implementations are not required to signal an error (and the R7RS is full of those and this specification adds user defined version on top of that) are analogous to what is called *undefined behaviour*, for example, in the C programming language, including its boon and bane. In order to reduce a potential source of software bugs, an optimizing compiler that makes use of code elimination through undefined behaviour should warn the user about dead or meaningless code:

```
(define (f x)
  (unless (exact-integer? x)
    (frob x)
    (assume #f))
  (when (inexact? x)
    (twiddle x))
  (g (* x x)))
```

Assuming the compiler can prove that `(frob x)` returns, it is encouraged issue a warning that the evaluation of `frob` is meaningless because the code path in which it appears is invalid. Likewise, the compiler is encouraged to issue a warning that `(twiddle x)` is likewise dead code, never evaluated.

*Note: A program that, for some input, would eventually evaluate `(assume #f)` is invalid and execution of it is an error itself, so anything may happen. In particular `frob` may never be called in the above example. An optimizing compiler may assume that a program presented to it is valid, so it may assume that the branch including the call to frob is never taken. Thus any expression in this path is simply superfluous.*

# Specification

## Syntax

`(assume `*`obj`*` `*`message`*` ...)`

This special form is an expression that evaluates to the value of *obj* if *obj* evaluates to a true value. It is an error if *obj* evaluates to a false value. In this case, implementations are encouraged to report this error together with the \*`message`\*s to the user, at least when the implementation is in debug or non-optimizing mode. In case of reporting the error, an implementation is also encouraged to report the source location of the source of the error.

# Implementation

A simple implementation for R7RS can be given as follows:

```

(define-library (srfi 145)
  (export assume)
  (import (scheme base))
  (begin
    (define-syntax assume
      (syntax-rules ()
        ((assume expression message ...)
         (or expression
             (fatal-error "invalid assumption" (quote expression) (list message ...))))
        ((assume . _)
         (syntax-error "invalid assume syntax"))))
  (cond-expand
    (debug
     (begin
       (define fatal-error error)))
    (else
     (begin
       (define (fatal-error message . objs)
         (car 0)))))))
```

This sample implementation meets all the requirements. If the feature identifier `debug` is set, `assume` uses `error` to signal an invalid assumption. If the feature identifier `debug` is not set, invoking `assume` with a false argument causes a subsequent error when `(car 0)` is evaluated, thus rendering the whole code path leading to the invocation of that `assume` invalid.

One should note that there is also a trivial R7RS implementation for the specification given in this SRFI, namely:

```
(define-library (srfi 145)
  (export assume)
  (import (scheme base))
  (begin
    (define-syntax assume
      (syntax-rules ()
        ((assume obj . _) obj)))))
```

The reason why this is a faithful implementation is that whenever `(assume #f)` is invoked, it is an error anyway, so that implementations are allowed to fail catastrophically (in the words of the R7RS), including that they simply return `#f`.

# Acknowledgements

I would like to thank all the persons who have been involved in discussing the topic of this SRFI and helping to bring it in final shape, in particular John Cowan and Jim Rees.

# Copyright

Copyright (C) Marc Nieper-Wißkirchen (2016). All Rights Reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

______________________________________________________________________

Editor: [Arthur A. Gleckler](mailto:srfi-editors+at+srfi+dot+schemers+dot+org)
