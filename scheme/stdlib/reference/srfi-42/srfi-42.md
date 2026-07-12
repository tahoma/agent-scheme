<!-- SPDX-License-Identifier: MIT -->

<!-- SPDX-FileCopyrightText: SRFI document authors -->

# [<img src="https://srfi.schemers.org/srfi-logo.svg" class="srfi-logo" alt="SRFI surfboard logo" />](https://srfi.schemers.org/)42: Eager Comprehensions

by Sebastian Egner

## Status

This SRFI is currently in *final* status. Here is [an explanation](https://srfi.schemers.org/srfi-process.html) of each status that a SRFI can hold. To provide input on this SRFI, please send email to [`srfi-42@`<span class="antispam">`nospam`</span>`srfi.schemers.org`](mailto:srfi+minus+42+at+srfi+dotschemers+dot+org). To subscribe to the list, follow [these instructions](https://srfi.schemers.org/srfi-list-subscribe.html). You can access previous messages via the mailing list [archive](https://srfi-email.schemers.org/srfi-42).

- Received: 2003-02-20
- Draft: 2003-02-20--2003-04-20
- Revised: 2003-07-07
- Final: 2003-07-07

## Abstract

This SRFI defines a modular and portable mechanism for eager comprehensions extending the algorithmic language Scheme [[R5RS]](#R5RS). An eager comprehension is a convenient notation for one or more nested or parallel loops generating a sequence of values, and accumulating this sequence into a result. In its most simple form, a comprehension according to this SRFI looks like this:

> ```
> (list-ec (: i 5) (* i i)) => (0 1 4 9 16).
> ```

Here, `i` is a local variable that is sequentially bound to the values 0, 1, ..., 4, and the squares of these numbers are collected in a list. The following example illustrates most conventions of this SRFI with respect to nesting and syntax:

> ```
> (list-ec (: n 1 4) (: i n) (list n i)) => ((1 0) (2 0) (2 1) (3 0) (3 1) (3 2)).
> ```

In the example, the variable `n` is first bound to 1 then to 2 and finally to 3, and for each binding of `n` the variable `i` is bound to the values 0, 1, ..., `n`-1 in turn. The expression `(list n i)` constructs a two-element list for each bindings, and the comprehension `list-ec` collects all these results in a list.

The mechanism defined in this SRFI has the following properties:

- The set of comprehensions defined for this SRFI is inspired by those procedures and macros of [[R5RS, 6.]](#R5RS) leading to natural comprehensions such as [`list-ec`](#list-ec), [`append-ec`](#append-ec), [`sum-ec`](#sum-ec), [`min-ec`](#min-ec), [`every?-ec`](#every%3F-ec), [`do-ec`](#do-ec), and others. Some other natural comprehensions (e.g. `gcd-ec`) have not been included into this SRFI due to their low significance for most applications. On the other hand, a few comprehensions ([`fold-ec`](#fold-ec), [`fold3-ec`](#fold3-ec)) not inspired by [[R5RS]](#R5RS) have been included due to their broad applicability.
- There are typed generators ([`:list`](#%3Alist), [`:string`](#%3Alist), ...) expecting certain types of objects for their arguments. These generators usually produce code as efficient as hand coded `do`-loops.
- There is also the special generator [`:`](#%3A) (read 'run through') dispatching on the value of its argument list at runtime. In the examples above, one or two integers were used to define a range. The convenience of omitting the type comes at a certain performance penalty, both per iteration and during startup of the loop.
- Generators can be nested depth-first (as in the example above), run in parallel (with an optional [index variable](#vars) or more generally with [`:parallel`](#%3Aparallel)), and can be stopped early before ([`:while`](#%3Awhile)) or after ([`:until`](#%3Auntil)) producing the current value.
- The sequence of values can be filtered ([`if`](#if), [`not`](#not), [`and`](#and), [`or`](#or)), intermediate commands can be evaluated between generators ([`begin`](#begin)), and intermediate variables can be introduced ([`:let`](#%3Alet)).
- The mechanism is fully modular. This means that no existing macro or procedure needs to be modified when adding [application-specific comprehensions](#foo-ec), [application-specific typed generators](#%3Afoo), or [application-specific dispatching generators](#%3Adfoo).
- Syntactically, this SRFI uses the \[*outer* .. *inner* | *expr*\] convention, meaning that the most right generator (*inner*) spins fastest and is followed by the result expression over which the comprehension ranges (*expr*). Refer to the [Section "Design Rationale"](#convention). Moreover, the syntax is strictly prefix and the naming convention `my-comprehension-ec`, `:my-generator` is used systematically.

The remainder of this document is organized as follows. In section [Rationale](#rationale) a brief introduction is given what the motivation is for this SRFI. The following section [Specification](#specification) defines the mechanism. Section [Suggestions for Application-specific Extensions](#ext-examples) presents some ideas how extensions using this SRFI could look like. The section [Design Rationale](#design) contains some considerations that went into the design of the mechanism as defined in the specification. The following section [Related Work and Acknowledgements](#related-work) briefly reviews other proposals related to Scheme and comprehensions or loops. Finally, the section [Reference Implementation](#refimpl) gives source code for a reference implementation together with a collection of runnable examples and a few examples on extensions.

## Rationale

The purpose of this SRFI is to provide a compact notation for many common cases of loops, in particular those constructing values for further computation. The origin of this SRFI is my frustration that there is no simple for the list of integers from 0 to *n*-1. With this SRFI it is `(list-ec (: i n) i)`. Refer to the collection of examples for the [reference implementation](#refimpl) what it can be used for, and what it should not be used for. To give a practically useful example, the following procedure computes the sorted list of all prime numbers below a certain bound (you may want to run it yourself to get an idea of its efficiency):

> ```
> (define (eratosthenes n)          ; primes in {2..n-1} for n >= 1
>   (let ((p? (make-string n #\1)))
>     (do-ec (:range k 2 n)
>            (if (char=? (string-ref p? k) #\1))
>            (:range i (* 2 k) n k)
>            (string-set! p? i #\0) )
>     (list-ec (:range k 2 n) (if (char=? (string-ref p? k) #\1)) k) ))
> ```

Apart from *make simple things simple*, there is no other paradigm involved for this SRFI. In particular, it is not the ambition to implement the powerful *lazy* list comprehensions of other functional programming languages in Scheme. If you are looking for that you may want to refer to [[SRFI 40]](#SRFI40). (The usual definition of the stream of all primes does in fact also use Eratosthenes' sieve method. It is instructive to compare.)

The main focus of the design of this SRFI is portability under [[R5RS]](#R5RS) and modularity for extension. Portability is achieved by limiting the features included. Modularity for generators is achieved by a special implementation technique using *Continuation Passing Style* for macros (which I learned from Richard Kelsey's implementation of "Macros for writing loops", [[MWL]](#MWL)) and by limiting the expressive power of generators. Modularity for comprehensions requires no additional effort. As modularity was a major design goal, I hope many people will find it easy to define their own comprehensions and generators. As a starting point for doing so, I have included several [suggestions](#ext-examples) for extensions.

For a detailed motivation of the design decisions, please refer to the [Section "Design Rationale"](#design).

## Specification

A comprehension is a hygienic, referentially transparent macro in the sense of [[R5RS, 4.3.]](#R5RS). The macros extend the `<expression>`-syntax defined in [[R5RS, 7.1.3.]](#R5RS). The main syntactic pattern used for defining a comprehension is `<qualifier>`, representing a generator or a filter. It is defined in [Section "Qualifiers"](#qualifiers).

The most important instances of `<qualifier>` are generators. These are defined in [Section "Generators"](#generators). Generators come in three flavors, as *typed generators* ([`:list`](#%3Alist), [`:range`](#%3Arange) etc.), as *the dispatching generator* [`:`](#%3A) (pronounced as 'run through'), and as combined and modified generators ([`:parallel`](#%3Aparallel), [`:while`](#%3Awhile), [`:until`](#%3Auntil)). Most generators in this SRFI also support an optional [index variable](#vars) counting the values being generated.

Finally, it is explained how to add a new [application-specific comprehension](#foo-ec), how to add a new [application-specific typed generator](#%3Afoo), and how to add a new [application-specific dispatching generator](#%3Adfoo). As this concerns code unknown at the time this is being written, the explanation should not be taken as a *specification* in the literal sense. It rather suggests a convention to follow in order to ensure new comprehensions and generators blend seamlessly with the ones defined in this SRFI.

### Comprehensions

<span id="do-ec"></span> `(do-ec <qualifier>`\*` <command>)`\
Evaluates the `<command>` exactly once for each binding in the sequence defined by the qualifiers. If there are no qualifiers `<command>` is evaluated exactly once. The expression is evaluated for its side-effects only. The result of the comprehension is unspecified.

<!-- -->

<span id="list-ec"></span> `(list-ec <qualifier>`\*` <expression>)`\
The list of values obtained by evaluating `<expression>` once for each binding in the sequence defined by the qualifiers. If there are no qualifiers the result is the list with the value of `<expression>`.

<!-- -->

<span id="append-ec"></span> `(append-ec <qualifier>`\*` <expression>)`\
The list obtained by appending all values of `<expression>`, which must all be lists.\
Think of it as `(apply append (list-ec <qualifier>`\*` <expression>))`.

<!-- -->

<span id="string-ec"></span> `(string-ec <qualifier>`\*` <expression>)`\
The string of all values of `<expression>`.\
Think of it as `(list->string (list-ec <qualifier>`\*` <expression>))`.

<!-- -->

<span id="string-append-ec"></span> `(string-append-ec <qualifier>`\*` <expression>)`\
The string obtained by appending all values of `<expression>`, which must all be strings.\
Think of it as `(apply string-append (list-ec <qualifier>`\*` <expression>))`.

<!-- -->

<span id="vector-ec"></span> `(vector-ec <qualifier>`\*` <expression>)`\
The vector of all values of `<expression>`.\
Think of it as `(list->vector (list-ec <qualifier>`\*` <expression>))`.

<!-- -->

<span id="vector-of-length-ec"></span> `(vector-of-length-ec <k> <qualifier>`\*` <expression>)`\
The vector of all values of `<expression>`, of which there must be exactly `<k>`. This comprehension behaves like `vector-ec` but can be implemented more efficiently.

<!-- -->

<span id="sum-ec"></span> `(sum-ec <qualifier>`\*` <expression>)`\
The sum of all values of `<expression>`.\
Think of it as `(apply + (list-ec <qualifier>`\*` <expression>))`.

<!-- -->

<span id="product-ec"></span> `(product-ec <qualifier>`\*` <expression>)`\
The product of all values of `<expression>`.\
Think of it as `(apply * (list-ec <qualifier>`\*` <expression>))`.

<!-- -->

<span id="min-ec"></span><span id="max-ec"></span> `(min-ec <qualifier>`\*` <expression>)`\
`(max-ec <qualifier>`\*` <expression>)`\
The minimum and maximum of all values of `<expression>`. The sequence of values must be non-empty. Think of these as\
`(apply min (list-ec <qualifier>`\*` <expression>))`\
`(apply max (list-ec <qualifier>`\*` <expression>))`.

If you want to return a default value in case the sequence is empty you may want to consider\
`(fold3-ec 'infinity <qualifier>`\*` <expression> min min)`.

<span id="any?-ec"></span> `(any?-ec <qualifier>`\*` <test>)`\
Tests whether any value of `<test>` in the sequence of bindings specified by the qualifiers is non-`#f`. If this is the case, `#t` is returned, otherwise `#f`. If there are no bindings in the sequence specified by the qualifiers at all then the result is `#f`. The enumeration of values stops after the first non-`#f` encountered.

<!-- -->

<span id="every?-ec"></span> `(every?-ec <qualifier>`\*` <test>)`\
Tests whether all values of `<test>` are non-`#f`. If this is the case, `#t` is returned, otherwise `#f`. If the sequence is empty the result is `#t`. Enumeration stops after the first `#f`.

<!-- -->

<span id="first-ec"></span><span id="last-ec"></span>` (first-ec <default> <qualifier>`\*` <expression>)`\
`(last-ec  <default> <qualifier>`\*` <expression>)`\
The first or last value of `<expression>` in the sequence of bindings specified by the qualifiers. Before enumeration, the result is initialized with the value of `<default>`; so this will be the result if the sequence is empty. Enumeration is terminated in `first-ec` when the first value has been computed.

<!-- -->

<span id="fold-ec"></span><span id="fold3-ec"></span>` (fold-ec  <x0> <qualifier>`\*` <expression> <f2>)`\
`(fold3-ec <x0> <qualifier>`\*` <expression> <f1> <f2>)`\
Reduces the sequence *x*[0], *x*[1], ..., *x*\[*n*-1\] of values obtained by evaluating `<expression>` once for each binding as specified by `<qualifier>`\*. The arguments `<x0>`, `<f2>`, and `<f1>`, all syntactically equivalent to `<expression>`, specify the reduction process.

The reduction process for `fold-ec` is defined as follows. A reduction variable `x` is initialized to the value of `<x0>`, and for each *k* in {0, ..., *n*-1} the command `(set! x (<f2> `*x*\[*k*\]` x))` is evaluated. Finally, `x` is returned as the value of the comprehension.

The reduction process for `fold3-ec` is different. If and only if *n* = 0, i.e. the sequence is empty, then `<x0>` is evaluated and returned as the value of the comprehension. Otherwise, a reduction variable `x` is initialized to the value of `(<f1> `*x*[0]`)`, and for each *k* in {1, ..., *n*-1} the command `(set! x (<f2> `*x*\[*k*\]` x))` is evaluated. Finally, `x` is returned as the value of the comprehension.

As the order of the arguments suggests, `<x0>` is evaluated outside the scope of the qualifiers, whereas the reduction expressions involving `<f1>` and `<f2>` are inside the scope of the qualifiers (so they may depend on any variable introduced by the qualifiers). Note that `<f2>` is evaluated repeatedly, with any side-effect or overhead this might have.

The main purpose of these comprehensions is implementing other comprehensions as special cases. They are generalizations of the procedures `fold` and `reduce` in the sense of [[SRFI 1]](#SRFI1). (Concerning naming and argument order, please refer to the discussion archive of SRFI 1, in particular the posting [[Folds]](#Folds).) Note that `fold3-ec` is defined such that `<x0>` is only evaluated in case the sequence is empty. This allows raising an error for the empty sequence, as in the example definition of `min-ec` below.

<!-- -->

<span id="foo-ec"></span> `<application-specific comprehension>`\
An important aspect of this SRFI is a modular mechanism to define application-specific comprehensions. To create a new comprehension a hygienic macro of this name is defined. The macro transforms the new comprehension patterns into instances of [`do-ec`](#do-ec), which is the most fundamental eager comprehension, or any other comprehension already defined. For example, the following code defines [`list-ec`](#list-ec) and [`min-ec`](#min-ec) in terms of [`fold-ec`](#fold-ec) and [`fold3-ec`](#fold3-ec):

> ```
> (define-syntax list-ec
>   (syntax-rules ()
>     ((list-ec etc1 etc ...)
>      (reverse (fold-ec '() etc1 etc ... cons)) )))
>
> (define-syntax min-ec
>   (syntax-rules ()
>     ((min-ec etc1 etc ...)
>      (fold3-ec (min) etc1 etc ... min min) )))
> ```

Note that the pattern `etc1 etc ...` matches the syntax `<qualifier>`\*` <expression>` without separate access to `<qualifier>`\* and `<expression>`. In order to define a comprehension that does need explicit access to the `<expression>`-part, the following method is used. First, all qualifiers are collected into a [`nested`](#nested)-qualifier, and then the 'exactly one qualifier'-case is implemented. For illustration, the following code defines [`fold3-ec`](#fold3-ec) in terms of [`do-ec`](#do-ec):

> ```
> (define-syntax fold3-ec
>   (syntax-rules (nested)
>     ((fold3-ec x0 (nested q1 ...) q etc1 etc2 etc3 etc ...)
>      (fold3-ec x0 (nested q1 ... q) etc1 etc2 etc3 etc ...) )
>     ((fold3-ec x0 q1 q2 etc1 etc2 etc3 etc ...)
>      (fold3-ec x0 (nested q1 q2) etc1 etc2 etc3 etc ...) )
>     ((fold3-ec x0 expression f1 f2)
>      (fold3-ec x0 (nested) expression f1 f2) )
>
>     ((fold3-ec x0 qualifier expression f1 f2)
>      (let ((result #f) (empty #t))
>        (do-ec qualifier
>               (let ((value expression)) ; don't duplicate code
>                 (if empty
>                     (begin (set! result (f1 value))
>                            (set! empty #f) )
>                     (set! result (f2 value result)) )))
>        (if empty x0 result) ))))
> ```

Finally, observe that the newly defined `fold3-ec` comprehension inherits all types of qualifiers supported by `do-ec`, including all application-specific generators; no further definitions are necessary.

### Qualifiers

This section defines the syntax `<qualifier>`. The nesting of qualifiers is from left (outer) to right (inner). In other words, the rightmost generator spins fastest. The nesting also defines the scope of the variables introduced by the generators. This implies that inner generators may depend on the variables of outer generators. The sequence of enumeration of values is strictly *depth first*. These conventions are illustrated by the first [example](#example1).

The syntax `<qualifier>` consists of the following alternatives:

<span id="generator"></span> `<generator>`\
Enumerates a sequence of bindings of one or more variables. The scope of the variables starts at the generator and extends over all subsequent qualifiers and expressions in the comprehension. The `<generator>`-syntax is defined in [Section "Generators"](#generators).

<!-- -->

<span id="if"></span> `(if <test>)`\
Filters the sequence of bindings by testing if `<test>` evaluates to non-`#f`. Only for those bindings for which this is the case, the subsequent qualifiers of the comprehension are evaluated.

<!-- -->

<span id="not"></span><span id="and"></span><span id="or"></span>` (not <test>)`\
`(and <test>`\*`)`\
`(or  <test>`\*`)`\
Abbreviated notations for filters of the form `(if (not <test>))`, `(if (and <test>`\*`))`, and `(if (or <test>`\*`))`. These represent frequent cases of filters.

<!-- -->

<span id="begin"></span> `(begin <sequence>)`\
Evaluate `<sequence>`, consisting of `<command>`\*` <expression>`, once for each binding of the variables defined by the previous qualifiers in the comprehension. Using this qualifier, side effects can be inserted into the body of a comprehension.

<!-- -->

<span id="nested"></span> `(nested <qualifier>`\*`)`\
A syntactic construct to group qualifiers. The meaning of a qualifier according to the `nested`-syntax is the same as inserting `<qualifier>`\* into the enclosing comprehension. This construct can be used to reduce comprehensions with several qualifiers into a form with exactly one qualifier.

### Generators

This section defines the syntax `<generator>`. Each generator defines a sequence of bindings through which one or more variables are run. The scope of the variables begins after the closing parenthesis of the generator expression and extends to the end of the comprehension it is part of.

<span id="vars"></span>The variables defined by the generators are specified using the syntax

> ```
> <vars> --> <variable1> [ (index <variable2>) ],
> ```

where `<variable1>` runs through the values in the sequence defined by the generator, and the optional `<variable2>` is an exact integer-valued index variable counting the values (starting from 0). The names of the variables must be distinct. The following example illustrates the index variable:

> ```
> (list-ec (: x (index i) "abc") (list x i)) => ((#\a 0) (#\b 1) (#\c 2))
> ```

Unless defined otherwise, all generators make sure that the expressions provided for their syntactic arguments are evaluated exactly once, before enumeration begins. Moreover, it may be assumed that the generators do not copy the code provided for their arguments, because that could lead to exponential growth in code size. Finally, it is possible to assign a value to the variables defined by a generator, but the effect of this assignment is unspecified.

The syntax `<generator>` consists of the following alternatives:

<span id=":"></span> `(: <vars> <arg1> <arg>`\*`)`\
First the expressions `<arg1> <arg>`\* are evaluated into *a*[1] *a*[2] ... *a*\[*n*\] and then a global dispatch procedure is used to dispatch on the number and types of the arguments and run the resulting generator.

Initially (after loading the SRFI), the following cases are recognized:

| | | |
|----|----|----|
| [`:list`](#%3Alist) | if | for all *i* in {1..*n*}: `(list? `*a*\[*i*\]`)`. |
| [`:string`](#%3Astring) | if | for all *i* in {1..*n*}: `(string? `*a*\[*i*\]`)`. |
| [`:vector`](#%3Avector) | if | for all *i* in {1..*n*}: `(vector? `*a*\[*i*\]`)`. |
| [`:range`](#%3Arange) | if | *n* in {1..3} and for all *i* in {1..*n*}: `(integer? `*a*\[*i*\]`)` and `(exact? `*a*\[*i*\]`)`. |
| [`:real-range`](#%3Areal-range) | if | *n* in {1..3} and for all *i* in {1..*n*}: `(real? `*a*\[*i*\]`)`. |
| [`:char-range`](#%3Achar-range) | if | *n* = 2 and for all *i* in {1, 2}: `(char? `*a*\[*i*\]`)`. |
| [`:port`](#%3Aport) | if | *n* in {1,2} and `(input-port? `*a*[1]`)` and `(procedure? `*a*[2]`)`. |

<span id="make-initial-:-dispatch"></span><span id=":-dispatch-ref"></span><span id=":-dispatch-set!"></span> The current dispatcher can be retrieved as `(:-dispatch-ref)`, a new dispatcher *d* can be installed by `(:-dispatch-set! `*d*`)` yielding an unspecified result, and a copy of the initial dispatcher can be obtained as `(make-initial-:-dispatch)`. Please refer to the section [below](#%3Adfoo-global) for recommendation how to add cases to the dispatcher.

<span id=":list"></span><span id=":string"></span><span id=":vector"></span>` (:list   <vars> <arg1> <arg>`\*`)`\
`(:string <vars> <arg1> <arg>`\*`)`\
`(:vector <vars> <arg1> <arg>`\*`)`\
Run through one or more lists, strings, or vectors. First all expressions in `<arg1> <arg>`\* are evaluated and then all elements of the resulting values are enumerated from left to right. One can think of it as first appending all arguments and then enumerating the combined object. As a clarifying example, consider\
`(list-ec (:string c (index i) "a" "b") (cons c i))` => `((#\a . 0) (#\b . 1))`.

<!-- -->

<span id=":integers"></span> `(:integers <vars>)`\
Runs through the sequence 0, 1, 2, ... of non-negative integers. This is most useful in combination with [`:parallel`](#%3Aparallel), [`:while`](#%3Awhile), and [`:until`](#%3Auntil) or with a non-local exit in the body of the comprehension.

<!-- -->

<span id=":range"></span>` (:range <vars>         <stop>)`\
`(:range <vars> <start> <stop>)`\
`(:range <vars> <start> <stop> <step>)`\
Runs through a range of exact rational numbers.

The form `(:range <vars> <stop>)` evaluates the expression `<stop>`, which must result in an exact integer *n*, and runs through the finite sequence 0, 1, 2, ..., *n*-1. If *n* is zero or negative the sequence is empty.

The form `(:range <vars> <start> <stop>)` evaluates the expressions `<start>` and `<stop>`, which must result in exact integers *a* and *b*, and runs through the finite sequence *a*, *a*+1, *a*+2, ..., *b*-1. If *b* is less or equal *a* then the sequence is empty.

The form `(:range <vars> <start> <stop> <step>)` first evaluates the expressions `<start>`, `<stop>`, and `<step>`, which must result in exact integers *a*, *b*, and *s* such that *s* is unequal to zero. Then the sequence *a*, *a* + *s*, *a* + 2 *s*, ..., *a* + (*n*-1) *s* is enumerated where *n* = ceil((*b*-*a*)/*s*). In other words, the sequence starts at *a*, increments by *s*, and stops when the next value would reach or cross *b*. If *n* is zero or negative the sequence is empty.

<!-- -->

<span id=":real-range"></span>` (:real-range <vars>         <stop>)`\
`(:real-range <vars> <start> <stop>)`\
`(:real-range <vars> <start> <stop> <step>)`\
Runs through a range of real numbers using an explicit index variable. This form of range enumeration avoids accumulation of rounding errors and is the one to use if any of the numbers defining the range is inexact, not an integer, or a bignum of large magnitude.

Providing default value 0 for `<start>` and 1 for `<step>`, the generator first evaluates `<start>`, `<stop>`, and `<step>`, which must result in reals *a*, *b*, and *s* such that *n* = (*b*-*a*)/*s* is also representable as a real. Then the sequence 0, 1, 2, ... is enumerated while the current value *i* is less than *n*, and the variable in `<vars>` is bound to the value *a* + *i* *s*. If any of the values *a*, *b*, or *s* is non-exact then all values in the sequence are non-exact.

<!-- -->

<span id=":char-range"></span> `(:char-range <vars> <min> <max>)`\
Runs through a range of characters. First `<min>` and `<max>` are evaluated, which must result in two characters *a* and *b*. Then the sequence of characters *a*, *a*+1, *a*+2, ..., *b* is enumerated in the order defined by `char<=?` in the sense of [[R5RS, 6.3.4.]](#R5RS). If *b* is smaller than *a* then the sequence is empty. (Note that *b* is included in the sequence.)

<!-- -->

<span id=":port"></span> `(:port <vars> <port>)`\
`(:port <vars> <port> <read-proc>)`\
Reads from the port until the eof-object is read. Providing the default `read` for `<read-proc>`, the generator first evaluates `<port>` and `<read-proc>`, which must result in an input port *p* and a procedure *r*. Then the variable is run through the sequence obtained by `(`*r*` `*p*`)` while the result does not satisfy `eof-object?`.

<!-- -->

<span id=":dispatched"></span> `(:dispatched <vars> <dispatch> <arg1> <arg>`\*`)`\
Runs the variables through a sequence defined by `<dispatch>` and `<arg1> <arg>`\*. The purpose of `:dispatched` is implementing dispatched generators, in particular the predefined dispatching generator [`:`](#%3A).

The working of `:dispatched` is as follows. First `<dispatch>` and `<arg1> <arg>`\* are evaluated, resulting in a procedure *d* (the 'dispatcher') and the values *a*[1] *a*[2] ... *a*\[*n*\]. Then `(`*d*`(list`*a*[1] *a*[2] ... *a*\[*n*\] `))` is evaluated, resulting in a value *g*. If *g* is not a procedure then the dispatcher did not recognize the argument list and an error is raised. Otherwise the 'generator procedure' *g* is used to run `<vars>` through a sequence of values. The sequence defined by *g* is obtained by repeated evaluation of `(`*g* *empty*`)` until the result is *empty*. In other words, *g* indicates the end of the sequence by returning its only argument, for which the caller has provided an object distinct from anything *g* can produce. (Generator procedures are state based, they are no such noble things as streams in the sense of [SRFI 40](#SRFI40).)

The definition of dispatchers is greatly simplified by the macro `:generator-proc` that constructs a generator procedure from a typed generator. Let `(g var arg1 arg ...)` be an instance of the `<generator>` syntax, for example an [application-specific typed generator](#%3Afoo), with a single variable `var` and no index variable. Then

> `(:generator-proc (g arg1 arg ...)) =>`*g*,

where the generator procedure *g* runs through the list `(list-ec (g var arg1 arg ...) var)`.

*Adding an application-specific dispatching generator*. In order to define a new dispatching generator (say `:my`) first a dispatching procedure (say `:my-dispatch`) is defined. The dispatcher will be called with a single (!) argument containing the list of all values to dispatch on. To enable informative error messages, the dispatcher should return a descriptive object (e.g. a symbol for the module name) when it is called with the empty list. Otherwise (if there is at least one value to dispatch on), the dispatcher must either return a generator procedure or `#f` (= no interest). As an example, the following skeleton code defines a dispatcher similar to the initial dispatcher of [`:`](#%3A):

```
(define (:my-dispatch args)
  (case (length args)
    ((0) 'SRFI-NN)
    ((1) (let ((a1 (car args)))
           (cond
            ((list? a1)
             (:generator-proc (:list a1)) )
            ((string? a1)
             (:generator-proc (:string a1)) )
            ...more unary cases...
            (else
             #f ))))
    ((2) (let ((a1 (car args)) (a2 (cadr args)))
           (cond
            ((and (list? a1) (list? a2))
             (:generator-proc (:list a1 a2)) )
            ...more binary cases...
            (else
             #f ))))
    ...more arity cases...
    (else
     (cond
      ((every?-ec (:list a args) (list? a))
       (:generator-proc (:list (apply append args))) )
      ...more large variable arity cases...
      (else
       #f )))))
```

Once the dispatcher has been defined, the following macro implements the new dispatching generator:

```
(define-syntax :my
  (syntax-rules (index)
    ((:my cc var (index i) arg1 arg ...)
     (:dispatched cc var (index i) :my-dispatch arg1 arg ...) )
    ((:my cc var arg1 arg ...)
     (:dispatched cc var :my-dispatch arg1 arg ...) )))
```

This method of extension yields complete control of the dispatching process. Other modules can only add cases to `:my` if they have access to `:my-dispatch`.

*Extending the predefined dispatched generator*. An alternative to adding a new dispatched generators is extending the predefined generator [`:`](#%3A). Technically, extending [`:`](#%3A) means installing a new global dispatching procedure using [`:-dispatch-set!`](#%3A-dispatch-set!) as described above.

In most cases, however, the already installed dispatcher should be extended by new cases. The following procedure is a utility for doing so:

```
(dispatch-union d1 d2) => d,
```

where the new dispatcher *d* recognizes the union of the cases recognized by the dispatchers *d1* and *d2*. The new dispatcher always tries both component dispatchers and raises an error in case of conflict. The identification returned by `(`*d*`)` is the concatenation of the component identifications `(`*d1*`)` and `(`*d2*`)`, enclosed in lists if necessary. For illustration, consider the following code:

```
(define (example-dispatch args)
  (cond
   ((null? args)
    'example )
   ((and (= (length args) 1) (symbol? (car args)) )
    (:generator-proc (:string (symbol->string (car args)))) )
   (else
    #f )))

(:-dispatch-set! (dispatch-union (:-dispatch-ref) example-dispatch))
```

After evaluation of this code, the following example will work:

```
(list-ec (: c 'abc) c) => (#\a #\b #\c)
```

Adding cases to [`:`](#%3A) is particularly useful for frequent cases of interactive input. Be warned, however, that the advantage of global extension also carries the danger of conflicts, unexpected side-effects, and slow dispatching.

<!-- -->

<span id=":do"></span>` (:do (<lb>`\*`) <ne1?> (<ls>`\*`))`\
`(:do (let (<ob>`\*`) <oc>`\*`) (<lb>`\*`) <ne1?> (let (<ib>`\*`) <ic>`\*`) <ne2?> (<ls>`\*`))`\
Defines a generator in terms of a named-`let`, optionally decorated with inner and outer `let`s. This generator is for defining other generators. (In fact, the reference implementation transforms any other generator into an instance of fully decorated `:do`.) The generator is a compromise between expressive power (more flexible loops) and fixed structure (necessary for merging and modifying generators). In the fully decorated form, the syntactic variables `<ob>` (outer binding), `<oc>` (outer command), `<lb>` (loop binding), `<ne1?>` (not-end1?), `<ib>` (inner binding), `<ic>` (inner command), `<ne2?>` (not-end2?), and `<ls>` (loop step) define the following loop skeleton:

```
(let (<ob>*)
  <oc>*
  (let loop (<lb>*)
    (if <ne1?>
        (let (<ib>*)
          <ic>*
          payload
          (if <ne2?>
              (loop <ls>*) ))))),
```

where `<oc>*` and `<ic>*` are syntactically equivalent to `<command>`\*, i.e. they do not begin with a `<definition>`. The latter requirement allows the code generator to produce more efficient code for special cases by removing empty `let`-expressions altogether.

<!-- -->

<span id=":let"></span> `(:let <vars> <expression>)`\
Runs through the sequence consisting of the value of `<expression>`, only. This is the same as `(:list <vars> (list <expression>))`. If an index variable is specified, its value is 0. The `:let`-generator can be used to introduce an intermediate variable depending on outer generators.

<!-- -->

<span id=":parallel"></span> `(:parallel <generator>`\*`)`\
Runs several generators in parallel. This means that the next binding in the sequence is obtained by advancing each generator in `<generator>`\* by one step. The parallel generator terminates when any of its component generators terminates. The generators share a common scope for the variables they introduce. This implies that the names of the variables introduced by the various generators must be distinct.

<!-- -->

<span id=":while"></span> `(:while <generator> <expression>)`\
Runs `<generator>` while `<expression>` evaluates to non-`#f`. The guarding expression is included in the scope of the variables introduced by the generator.

Note the distinction between the filter `if` and the modified generator expressed by `:while`.

<!-- -->

<span id=":until"></span> `(:until <generator> <expression>)`\
Runs `<generator>` until after `<expression>` has evaluated to non-`#f`. The guarding expression is included in the scope of the variables introduced by the generator.

Note the distinction between `:while`, stopping *at* a certain condition, and `:until`, stopping *after* a certain condition has occurred. The latter implies that the binding that has triggered termination has been processed by the comprehension.

<!-- -->

<span id=":foo"></span> `<application-specific typed generator>`\
An important aspect of this SRFI is a modular mechanism to define new typed generators. To define a new typed generator a hygienic referentially transparent macro of the same name is defined to transform the generator pattern into an instance of the [`:do`](#%3Ado)-generator. The extension is fully modular, meaning that no other macro has to be modified to add the new generator. This is achieved by defining the new macro in *Continuation Passing Style*, as in [[MWL]](#MWL).

Technically, this works as follows. Assume the generator syntax `(:mygen <var> <arg>)` is to be implemented, for example running the variable `<var>` through the list `(reverse <arg>)`. The following definition implements `:mygen` in terms of [`:list`](#%3Alist) using the additional syntactic variable `cc` (read *current continuation*):

```
(define-syntax :mygen
  (syntax-rules ()
    ((:mygen cc var arg)
     (:list cc var (reverse arg)) )))
```

After this definition, any comprehension will accept the `:mygen`-generator and produce the proper code for it. This works as follows. When a comprehension sees something of the form `(g arg ...)` in the position of a `<qualifier>` then it will transform the entire comprehension into `(g (continue ...) arg ...)`. This effectively 'transfers control' to the macro `g`, for example `:mygen`. The macro `g` has full control of the transformation, but eventually it should transform the expression into `(:do (continue ...) etc ...)`. In the `:mygen`-example this is done by the `:list`-macro. The macro `:do` finally transforms into `(continue ... (:do etc ...))`. As `continue` has been chosen by the macro implementing the comprehension, it can regain control and proceed with other qualifiers.

In order to ensure consistency of new generators with the ones defined in this SRFI, a few conventions are in order. Firstly, the generator patterns begin with one or more variables followed by arguments defining the sequence. Secondly, each generator except `:do` can handle an optional index variable. This is most easily implemented using [`:parallel`](#%3Aparallel) together with [`:integers`](#%3Aintegers). In case the payload generator needs an index anyhow (e.g. [`:vector`](#%3Avector)) it is more efficient to add an index-variable if none is given and to implement the indexed case. Finally, make sure that no syntactic variable of the generator pattern ever gets duplicated in the code (to avoid exponential code size in nested application), and introduce sufficient intermediate variables to make sure expressions are evaluated at the correct time.

## Suggestions for application-specific extensions

### Arrays in the sense of [[SRFI25]](#SRFI25)

In order to create an array from a sequence of elements, a comprehension with the following syntax would be useful:

```
(array-ec <shape> <qualifier>* <expression>).
```

The comprehension constructs a new array of the given shape by filling it row-major with the sequence of elements as specified by the qualifiers.

On the generator side, it would be most useful to have a generator of the form

```
(:array <vars> <arg>),
```

running through the elements of the array in row-major. For the optional index variable, the extension `(index <k1> <k>`\*`)` could be defined where `<k1> <k>`\* are variable names indexing the various dimensions.

### Random Numbers in the sense of [[SRFI27]](#SRFI27)

In order to create a vector or list of random numbers, it would be convenient to have generators of the following form:

```
(:random-integer [ <range> [ <number> ] ] )
(:random-real    [ <number> ] )
```

where `<range>` (default 2) indicates the range of the integers and `<number>` (default infinity) specifies how many elements are to be generated. Derived from these basic generators, one could define several other generators for other distributions (e.g. Gaussian).

### Bitstrings in the sense of [[SRFI33]](#SRFI33)

As eager comprehensions are efficient, they can be useful for operations involving strings of bits. It could be useful to have the following comprehension:

```
(bitwise-ec <qualifier>* <expression>),
```

which constructs an integer from bits obtained as values of `<expression>` in the ordering defined by [[SRFI33]](#SRFI33). In other words, if the sequence of values is *x*[0], *x*[1], ..., *x*\[*n*-1\] then the result is *x*[0] + *x*[1] 2 + ... + *x*\[*n*-1\] 2^(*n*-1). On the generator side, a generator of the form

```
(:bitwise <vars> <arg1> <arg>*)
```

runs through the sequence of bits obtained by appending the binary digits of the integers `<arg1> <arg>`\*.

### <span id="srfi40-ec"></span>Streams in the sense of [[SRFI 40]](#SRFI40)

It is possible to 'lazify' the eager comprehension [`list-ec`](#list-ec), constructing a stream in the sense of [[SRFI 40]](#SRFI40). Clearly, such a comprehension (`stream-ec`) is not eager at all since it only runs the loops when results are requested. It is also possible to define a `:stream`-generator with the same API as [`:list`](#%3Alist) but running through streams instead of lists.

For what it is worth, the file [srfi40-ec.scm](srfi40-ec.scm) implements `:stream` and `stream-ec` and gives an example. The implementation makes substantial use of `call-with-current-continuation` to run the loop only when necessary. In some implementations of Scheme this may involve considerable overhead.

### Reading Text Files

Eager comprehensions can also be used to process files. However, bear in mind that an eager comprehension wants to read and process the entire file right away. Nevertheless, these generators would be useful for reading through the lines of a file or through the characters of a file:

```
(:lines-of-file <vars> <file>)
(:chars-of-file <vars> [ (line <variable1>) ] [ (column <variable2>) ] <file>)
```

Here `<file>` is either an input port or a string interpreted as a filename. In a similar fashion, generators reading from sockets defined by URLs or other communication facilities could be defined.

### The Scheme shell [Scsh](#SCSH)

In the Scheme-shell Scsh it could be useful to have certain comprehensions and generators. Candidates for comprehensions are `begin-ec`, `|-ec`, `||-ec`, and `&&-ec`. Concerning generators, it might be useful to have `:directory` running through the records of a directory, and maybe a sophisticated `:file-match`-generator could enumerate file record in a directory structure. Optional variables of the generators could give convenient access frequent components of the file records (e.g. the filename). Another candidate is `:env` to run through the environment associations. It is left to other authors and other SRFIs to define a useful set of comprehensions and generators for Scsh.

## Design Rationale

### What is the difference between eager and lazy comprehensions?

A lazy comprehension, for example `stream-of` in the sense of [[SRFI 40]](#SRFI40), constructs an object representing a sequence of values. Only at the time these values are needed that they are actually produced. An eager comprehension, on the other hand, is an instruction to run through a certain sequence of values and do something with it, for example as in [`do-ec`](#do-ec). In other words, it is nothing more sophisticated than a loop, potentially with a more convenient notation. This also explains why `stream-of` is the most fundamental *lazy* comprehension, and all others can be formulated in terms of it, whereas the most fundamental *eager* comprehension is `do-ec`.

### Why the \[*outer* .. *inner* | *expr*\] order of qualifiers?

In principle, there are six possible orders in which the qualifiers and the expression of a comprehension can be written. We denote the different conventions with a pattern in which *expr* denotes the expression over which the comprehension ranges, *inner* denotes the generator spinning fastest, and *outer* denotes the generator spinning slowest. For example, [[Haskell]](#Haskell) and [[Python]](#Python) use \[*expr* | *outer* .. *inner*\]. (Probably with sufficient persistence, instances for any of the conventions can be found on the Internet.) In addition, there is the common mathematical notation '{*f*(*x*) | *x* in *X*}'.

It is important to understand that the notational convention does not only determine the order of enumeration but also the scope of the variables introduced by the generators. The scope of *inner* includes *expr*, and the scope of *outer* should include *inner* to allow inner generates depending on outer generators. Eventually, the choice for a particular syntactic convention is largely a matter of personal preferences. However, there are a few considerations that went into the choice made for this SRFI:

1. The mathematical notation is universally known and widely used. However, the mathematical notation denotes a *set* comprehension in which the order of the qualifiers is either irrelevant or must be deduced from the context. For the purpose of eager comprehensions as a programming language construct, the order does matter and a simple convention is a plus. For these reasons, the mathematical notation as such is undesirable, but its widespread use is in favor of \[*expr* | *inner* .. *outer*\] and \[*expr* | *outer* .. *inner*\].

1. It is desirable to have the scope of the variables increase into one direction, as in \[*expr* | *inner* .. *outer*\] and \[*outer* .. *inner* | *expr*\], and not change direction, as in \[*expr* | *outer* .. *inner*\] where *expr* is in the scope of *inner* but *outer* is not. This is even more important if the syntax in Scheme does not explicitly contain the '|'-separator.

1. More complicated comprehensions with several nested generators eventually look like nested loops and Scheme always introduces them *outer* .. *inner* as in `do` and named-`let`. This is in favor of \[*expr* | *outer* .. *inner*\] and \[*outer* .. *inner* | *expr*\]. Shorter comprehension may look more naturally the other way around.

Regarding these contradicting preferences, I regard linearity in scoping (2.) most important, followed by readability for more complicated comprehensions (3.). This leads to \[*outer* .. *inner* | *expr*\]. An example in Scheme-syntax is `(list-ec (: x 10) (: y x) (f x y))`, which looks acceptable to me even without similarity to the mathematical notation. As a downside, the convention clashes with other the convention used in other languages (e.g. Haskell and Python).

### You forgot \[*choose your favorite here*\]-ec!

I tried to construct a reasonably useful set of tools according to what [[R5RS]](#R5RS) specifies. Nevertheless, is the choice what to include and what to leave out eventually a matter of personal preference.

When 'packing the toolbox' I went for travelling light; this SRFI does not include everything imaginable or even everything useful. I oriented myself at the standard procedures of [[R5RS]](#R5RS), with a few omissions and additions. A notable omission are `gcd-ec` and `lcm-ec` because they are one-liners, and more severely, of questionable value in practice. A notable addition are [`fold-ec`](#fold-ec) and [`fold3-ec`](#fold3-ec), providing a mechanism to define lots of useful one-liners. The other notable addition is [`first-ec`](#first-ec), which is the fundamental 'early stopping' comprehension. It is used to define [`any?-ec`](#any%3F-ec) and [`every?-ec`](#every%3F-ec) which are among the most frequent comprehensions.

Concerning the generators, the same principle has been used. Additions include [`:range`](#%3Arange) and friends because they are universally needed, and [`:dispatched`](#%3Adispatched) which is primarily intended for implementing [`:`](#%3A).

### Why is the order of enumeration specified?

For the purpose of this SRFI, every generator runs through its sequence of bindings in a well specified order, and nested generators run through the Cartesian product in the order of nested loops. The purpose of this definition is making the sequence as easily predictable as possible.

On the other hand, many mechanisms for *lazy* comprehensions do not specify the order in which the elements are enumerated. When it comes to infinite streams, this has the great advantage that a comprehension may interleave an inner and an outer enumeration, a method also known as 'dove-tailing' or 'diagonalizing'. Interleaving ensures that any value of the resulting stream is produced after a finite amount of time, even if one or more inner streams are infinite.

### Why both typed and dispatching generators?

The reason for typed generators is runtime efficiency. In fact, the code produced by `:range` and others will run as fast as a hand-coded `do`-loop. The primary purpose of the dispatching generator is convenience. It comes at the price of reduced runtime performance, both for loop iteration and startup.

### Why the *something*`-ec` and `:`*type* naming?

The purpose of the `:`*type* convention is to keep many common comprehensions down to one-liners. In my opinion, the fundamental nature of eager comprehensions justifies a single character naming convention. The *something*`-ec` convention is primarily intended to stay away from the widely used *something*`-of`. It reduces confusion and conflict with related mechanisms.

### Why combine variable binding and sequence definition?

The generators of this SRFI do two different things with a single syntactic construct: They define a sequence of values to enumerate and they specify a variable (within a certain scope) to run through that sequence. An alternative is to separate the two, for example as it has been done in [SRFI 40](https://srfi.schemers.org/srfi-40/srfi-40.html).

The reason for combining sequence definition and enumeration for the purpose of this SRFI is threefold. Firstly, sequences of values are not explicitly represented as objects in the typed generators; the generators merely manipulate an internal state. Secondly, this SRFI aims at a most concise notation for common comprehensions and reduces syntax to the naked minimum. Thirdly, this SRFI aims at the highest possible performance for typed generators, which is achieved if the state being manipulated is represented by the loop variable itself.

### Why is `(: <vars>)` illegal?

It is reasonable and easy to define `(`[`:`](#%3A)` <vars>)` as `(`[`:integers`](#%3Aintegers)` <vars>)`, enumerating the non-negative integers. However, it turned out that a frequent mistake in using the eager comprehensions is to forget either the variable or an argument for the enumeration. As this would lead to an infinite loop (not always equally pleasant in interactive sessions), it is not allowed.

### Why is there no `:sequential`?

Just like [`:parallel`](#%3Aparallel) enumerates generators in parallel, a `:sequential` generator could enumerate a concatenation of several generator, starting the next one when the previous has finished. The reason for not having such a qualifier is that the generators should use all the same variable name and there is no hygienic and referentially transparent way of enforcing this (or even knowing the variable).

### Why is there no general `let`-qualifier?

It is easy to add `let`, `let*`, and `letrec` as cases to `<qualifier>`. This would allow more sophisticated local variables and expressions than possible with `(`[`:let`](#%3Alet)` <vars> <expression>)` and `(`[`begin`](#begin)` <sequence>`\*`)`. In particular, a local `<definition>` in the sense of [[R5RS, 7.1.5.]](#R5RS) would be possible.

There are two reasons for not including `let` and friends as qualifiers. The first reason concerns readability. A qualifier of the form `(let (<binding spec>`\*`) <body>)` only makes sense if the scope of the new variables ends at the end of the comprehension, and *not* already after `<body>`. The similarity with ordinary `let`-expressions would be very confusing. The second reason concerns the design rationale. If sophisticated `let`-qualifiers involving recursion or local definitions are needed, it is likely that eager comprehensions are being overused. In that case it might be better to define a procedure for the task. So including an invitation to overuse the mechanism would be a serious violation of the *Keep It Simple and Stupid* principle.

### Why is there no `:nested` generator?

The specification above defines [`nested`](#nested) as a qualifier but [`:parallel`](#%3Aparallel) as a generator. In particular, this makes it impossible to make parallel generators from nested ones.

This design simply reflects an implementability limitation. All component generators of `:parallel` are transformed into [`:do`](#%3Ado)-generators and these can be merged into a parallel generator. However, nested generators cannot be merged easily without losing the type of the generator, which would seriously hurt modularity and performance.

### Is `any?-ec` eager?

Yes, it is still eager because it immediately starts to run through the sequence.

In fact, the reference implementation makes sure [`first-ec`](#first-ec), [`any?-ec`](#any%3F-ec), and [`every?-ec`](#every%3F-ec) execute efficiently so they can be used conveniently as in `(every?-ec (:list x my-list) (pred? x))`.

### Why this whole `:dispatched` business?

It is specified above that *the* dispatching generator, called [`:`](#%3A), is just a special case of [`:dispatched`](#%3Adispatched) using a global dispatching procedure. Alternatively, a simple fixed global mechanism to extend [`:`](#%3A) could have been used. This is much simpler but does not support the definition of new dispatched generators.

The purpose of [`:dispatched`](#%3Adispatched) and its utilities ([`:generator-proc`](#%3Agenerator-proc) and [`dispatch-union`](#dispatch-union)) is the following. Assume [`:`](#%3A) is to be used inside a module but it is essential that no other module can spoil it, e.g. by installing a very slow dispatcher. The recommended way to proceed in this case is to define a local copy of the original dispatching generator [`:`](#%3A), for example with the following code

```
(define :my-dispatch
  (make-initial-:-dispatch) )

(define-syntax :my
  (syntax-rules (index)
    ((:my cc var (index i) arg1 arg ...)
     (:dispatched cc var (index i) :my-dispatch arg1 arg ...) )
    ((:my cc var arg1 arg ...)
     (:dispatched cc var :my-dispatch arg1 arg ...) ))),
```

and to use the new generator `:my` instead of [`:`](#%3A).

An alternative for the dispatching mechanism as defined in this SRFI is the use of parameter objects in the sense of [[SRFI 39]](#SRFI39). The dispatching generator would then access a dynamically scoped variable to find the dispatcher, allowing full control over dispatching. However, this approach does not solve the dilemma that it is sometimes useful that [`:`](#%3A) is global and sometimes undesired. The approach specified for this SRFI addresses this dilemma by offering options.

Another alternative for dealing with the dispatching problem is adding an optional argument to the syntax of [`:`](#%3A) through which the dispatcher can be passed explicitly. However, as [`:`](#%3A) has variable arity and the identifier for the variable cannot be distinguished from any value for a dispatcher, this is syntactically problematic.

### Why is there no local mechanism for adding to [`:`](#%3A)?

According to [[R5RS, 7.1.6.]](#R5RS) macros can only be defined at the level of the `<program>` syntax. This implies that the scope of typed generators cannot easily be limited to local scopes. As typed and dispatched generators go together, there is also no strong need for a limited scope of dispatched generators either. Furthermore, locally extendable dispatchers are another major headache to those trying to understand other people's code.

### Why are dispatchers unary?

As defined in [`:dispatched`](#%3Adispatched), a dispatching procedure is called with a single argument being the list of values to dispatch on. An alternative is to `apply` the dispatcher to the list of values to dispatch on, which would be more natural in Scheme.

The reason for not using `apply` is a minor improvement in efficiency. Every time `apply` is used on a procedure of variable arity, an object containing the argument list is allocated on the heap. As a dispatcher may call many other dispatchers, this will adds to the overhead of dispatching, which is relevant in inner loops.

### Why are there two fold comprehensions?

The reason for having two fold comprehensions ([`fold-ec`](#fold-ec) and [`fold3-ec`](#fold3-ec)) is efficiency.

Clearly, the more general construction is [`fold3-ec`](#fold3-ec) as it allows individual treatment of the empty sequence case and the singleton sequence case. However, this comes at the price of more book-keeping as can be seen from the [implementation example](#fold3-ec-example). As the overhead is located within inner loops, it makes sense to define another fold comprehension for the case where the added flexibility is not needed. This is [`fold-ec`](#fold-ec).

The names `fold-ec` and `fold3-ec` have been chosen for the comprehensions in order to stay clear any other 'fold' that may be around.

### Why is `:char-range` not defined by `integer->char`?

The definition of [`:char-range`](#%3Achar-range) specifies a sequence of adjacent characters ordered by `char<=?`. The reason for not using `char->integer` and `integer->char` is the fact that [[R5RS, 6.3.4.]](#R5RS) leaves it to the implementation whether the integers representing characters are consecutive or not. In effect, this underspecification is inherited by `:char-range`.

## Related Work and Acknowledgements

Several other proposals related to the mechanism specified here exists. The following mechanisms are made for and in Scheme (or at least a specific dialect thereof):

First of all, the report [[R5RS]](#R5RS) of Scheme itself defines two constructs for writing loops: `do` and named-`let`. Both constructs express a single loop (not nested), possibly with several variables running in parallel, based on explicit manipulation of the state variables. For example `(do ((x 0 (+ x 1))) ((= x 10)) (display x))` explicitly mentions how to obtain the next binding of `x`.

Richard Kelsey's "Macros for writing loops", [[MWL]](#MWL) are an extension to Scheme48 to simplify the formulation of loops. The basic idea is to stick with a `do`-like syntax for more sophisticated loop constructs, not necessarily manipulating a state variable explicitly. For example, `(list* x '(1 2 3))` expresses an enumeration of the variable `x` through the list `(1 2 3)` without explicit state manipulation. The iteration constructs of [[MWL]](#MWL), named `iterate` and `reduce`, express a single (not nested) loop (`iterate`) or comprehension (`reduce`) with any number of parallel enumerations. A most important feature of the [[MWL]](#MWL)-concept is a modular way to add sequence types (generators). In effect, the addition of a new sequence type does not require a modification of the existing macros. This is achieved by carefully limiting the expressive power of the loop constructs and by using the macros in *Continuation Passing Style* to call other macros. The [[MWL]](#MWL)-concept, and its implementation, were most influential for this SRFI.

Another related mechanism is the library of streams recently submitted by Phil L. Bewig as [[SRFI 40]](#SRFI40). The library contains a data type to represent even streams (both car and cdr potentially delayed) and defines procedures for manipulating these streams. Moreover, the macro `stream-of` defines a lazy comprehension resulting in the stream of values of an expression subject to generators and filters. A fixed set of generators (lists, vector, string, port, and naturally: streams) is supported; extending the list of generators requires changing `stream-of`. Nevertheless, modularity is high since it is easy to define a procedure producing a stream object and this can be used for enumeration. The order of enumeration is left unspecified to allow interleaving of generators (also refer to [above](#dovetail).) Before Phil submitted his SRFIs, we had a short discussion in which we clarified the semantic and syntactic differences of our approaches. It turned out that the mechanisms are sufficiently different not to unify them. The most important difference is the design rationale: Phil created his library to support the stream-paradigm in Scheme, inspired by the work done for Haskell and other lazy languages, and intrigued by the beauty of programming with infinite streams. My work only aims at a convenient way of expressing frequent patterns of loops in a compact way. For what it is worth, section [SRFI40-ec](#srfi40-ec) contains a suggestion for extending the eager comprehension mechanism for SRFI40-streams.

Phil's work on streams and lazy comprehensions in Scheme triggered Eli Barzilay to implement a library of eager comprehensions for PLT-Scheme, [[Eli]](#Eli). The mechanism implemented by Eli is in essence very similar to the one proposed in this SRFI, and the two efforts have been independent until recently. Syntactically, Eli uses infix operators for generators, whereas this SRFI is purely prefix, and Eli uses the \[*expr* | *outer* .. *inner*\] convention for nesting, whereas this SRFI uses the \[*outer* .. *inner* | *expr*\] [convention](#convention). Semantically, Eli's mechanism defines more flexible loops than this SRFI. Comprehensions are regarded as generalized collection processes like fold and reduce. The mechanism in this SRFI is more restricted with respect to control flow (there is no general `while`) and more extensive with respect to generators and comprehensions. Despite the strong conceptual similarity, the design rationales are different. This SRFI focuses on portability and modular extension, whatever that may cost in terms of expressive power.

Finally, I would like to thank Mike Sperber for his encouragement to proceed with the SRFI and for several discussions of the matter. In particular, the dispatching mechanism evolved rapidly during discussions with Mike.

## Implementation

The reference implementation focuses on portability, performance, readability and simplicity, roughly in this order. It is written in [[R5RS]](#R5RS)-Scheme (including macros) extended by [[SRFI 23]](#SRFI23) (`error`). The reference implementation was developed under [Scheme48](#Scheme48) (0.57), [PLT](#PLT) (202, 204), and [SCM](#SCM) (5d7).

The file [ec.scm](ec.scm) is the source of the reference implementation. It also contains comments concerning potential problems. Implementors might find the file [design.scm](design.scm) helpful. It contains alternative implementations of certain comprehensions and generators in order to simplify tuning the implementation of this SRFI for different Scheme systems.

The file [examples.scm](examples.scm) contains a collection of examples, and some code checking their results. The purpose of most examples is detecting implementation errors, but the section 'Less artificial examples' contains a few real-world examples.

The file [timing.scm](timing.scm) contains some code to measure an idea of performance of the comprehensions. A hand-coded `do`-loop, the typed generator `(`[`:range`](#%3Arange)` `*n*`)`, and the dispatching generator `(`[`:`](#%3A)` `*n*`)` are compared. For each loop we compare the time needed per iteration and the time needed to construct the loop (the startup delay). As a rule of thumb, `:range` is as fast (or slightly faster) as a hand-coded `do`-loop per iteration and needs about a third more time for startup (due to type checking of the argument). The dispatching generator needs about twice the time per iteration (due to calling the generator procedure) and needs about five times as long for startup (due to dispatching).

The file [extension.scm](extension.scm) contains examples for adding new generators and comprehensions.

## References

| | |
|----|----|
| <span id="R5RS">[R5RS]</span> | Richard Kelsey, William Clinger, and Jonathan Rees (eds.): Revised(5) Report on the Algorithmic Language Scheme of 20 February 1998. Higher-Order and Symbolic Computation, Vol. 11, No. 1, September 1998. <http://schemers.org/Documents/Standards/R5RS/>. |
| <span id="MWL">[MWL]</span> | Richard Kelsey, Jonathan Rees: The Incomplete Scheme48 Reference Manual for Release 0.57 (July 15, 2001). Section "Macros for writing loops". <http://s48.org/0.57/manual/s48manual_49.html> |
| <span id="SRFI1">[SRFI 1]</span> | Olin Shivers: List Library. [http://srfi.schemers.org/srfi-1/](https://srfi.schemers.org/srfi-1/) |
| <span id="SRFI23">[SRFI 23]</span> | Stephan Houben: Error reporting mechanism [http://srfi.schemers.org/srfi-23/](https://srfi.schemers.org/srfi-23/) |
| <span id="SRFI25">[SRFI 25]</span> | Jussi Piitulainen: Multi-dimensional Array Primitives. [http://srfi.schemers.org/srfi-25/](https://srfi.schemers.org/srfi-25/) |
| <span id="SRFI27">[SRFI 27]</span> | Sebastian Egner: Sources of Random Bits. [http://srfi.schemers.org/srfi-27/](https://srfi.schemers.org/srfi-27/) |
| <span id="SRFI33">[SRFI 33]</span> | Olin Shivers: Integer Bitwise-operation Library. [http://srfi.schemers.org/srfi-33/](https://srfi.schemers.org/srfi-33/) |
| <span id="SRFI39">[SRFI 39]</span> | Marc Feeley: Parameter objects. [http://srfi.schemers.org/srfi-39/](https://srfi.schemers.org/srfi-39/) |
| <span id="SRFI40">[SRFI 40]</span> | Philip L. Bewig: A Library of Streams. [http://srfi.schemers.org/srfi-40/](https://srfi.schemers.org/srfi-40/) |
| <span id="Eli">[Eli]</span> | Eli Barzilay: Documentation for "misc.ss". 2002. <http://www.cs.cornell.edu/eli/Swindle/misc-doc.html#collect> |
| <span id="Folds">[Folds]</span> | John David Stone: Folds and reductions. Posting in relation to [[SRFI 1]](#SRFI1) on 8-Jan-1999. [http://srfi.schemers.org/srfi-1/mail-archive/msg00021.html](https://srfi.schemers.org/srfi-1/mail-archive/msg00021.html) |
| <span id="Haskell">[Haskell]</span> | Simon L. Peyton Jones, John Hughes: The Haskell 98 Report 1 February 1999. Section 3.11 "List Comprehensions". <http://www.haskell.org/onlinereport/exps.html#sect3.11> |
| <span id="Python">[Python]</span> | Guido van Rossum, Fred L. Drake Jr. (eds.): Python Reference Manual. Section 5.2.4 "List displays". Release 2.2, December 21, 2001. <http://python.org/doc/2.2/ref/lists.html> |
| <span id="SICP">[SICP]</span> | Harold Abelson, Gerald J. Sussman, Julie Sussman: Structure and Interpretation of Computer Programs. MIT Press, 1985. <http://mitpress.mit.edu/sicp/> |
| <span id="IFPL">[IFPL]</span> | Philip Wadler: List Comprehensions (Chapter 7). In: Simon L. Peyton Jones: The Implementation of Functional Programming Languages. Prentice Hall, 1987. |
| <span id="Scheme48">[Scheme48]</span> | Richard Kelsey, Jonathan Rees: Scheme48 Release 0.57 (July 15, 2001). <http://s48.org/> |
| <span id="SCM">[SCM]</span> | Aubrey Jaffer: SCM Scheme Implementation. Version 5d7 (November 27, 2002). <http://www.swiss.ai.mit.edu/~jaffer/SCM.html> |
| <span id="PLT">[PLT]</span> | PLT People: PLT Scheme, DrScheme Version 203. <http://www.plt-scheme.org/> |
| <span id="SCSH">[Scsh]</span> | Olin Shivers, Brian D. Carlstrom, Martin Gasbichler, Mike Sperber: Scsh Reference Manual. For scsh release 0.6.3. <http://scsh.net/> |

## Copyright

Copyright (C) Sebastian Egner (2003). All Rights Reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

______________________________________________________________________

Author: [Sebastian Egner](mailto:sebastian.egner@philips.com)

Editor: [Francisco Solsona](mailto:srfi%20minus%20editors%20at%20srfi%20dot%20schemers%20dot%20org)

Last modified: Sun Jan 28 13:40:34 MET 2007
