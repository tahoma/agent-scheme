<!-- SPDX-License-Identifier: MIT -->

<!-- SPDX-FileCopyrightText: SRFI document authors -->

# [<img src="https://srfi.schemers.org/srfi-logo.svg" class="srfi-logo" alt="SRFI surfboard logo" />](https://srfi.schemers.org/)1: List Library

by Olin Shivers

## Status

This SRFI is currently in *final* status. Here is [an explanation](https://srfi.schemers.org/srfi-process.html) of each status that a SRFI can hold. To provide input on this SRFI, please send email to [`srfi-1 @`<span class="antispam">`nospam`</span>`srfi.schemers.org`](mailto:srfi+minus+1%20%20+at+srfi+dotschemers+dot+org). To subscribe to the list, follow [these instructions](https://srfi.schemers.org/srfi-list-subscribe.html). You can access previous messages via the mailing list [archive](https://srfi-email.schemers.org/srfi-1).

- Received: 1998-11-08
- Draft: 1998-12-22--1999-03-09
- Revised: several times
- Final: 1999-10-09
- Revised to fix errata:
  - 2016-08-27 (Clarify Booleans.)
  - 2018-10-08 (Remove extra parenthesis.)
  - 2019-10-25 (Fix broken links.)
  - 2020-06-02 (Add [note](#lset%3D-element-equality-order) about order of arguments to `lset=`.)
  - 2022-10-22 (Fixed [definition of `reduce-right`](#reduce-right). See [discussion in archive](https://srfi-email.schemers.org/srfi-1/msg/18561246/).)
  - 2022-11-21 (Add missing ellipsis in signature of [`count`](#count).)
  - 2023-04-27 (Fix return type of [`circular-list`](#circular-list).)
  - 2025-09-02 (Fix [example](#right-example) of `drop-right` and `take-right`.)

## Table of contents

- [Abstract](#Abstract)
- [Rationale](#Rationale)
- [Procedure index](#ProcedureIndex)
- [General discussion](#GeneralDiscussion)
  - ["Linear update" procedures](#LinearUpdateProcedures)
  - [Improper lists](#ImproperLists)
  - [Errors](#Errors)
  - [Not included in this library](#NotIncludedInThisLibrary)
- [The procedures](#TheProcedures)
  - [Constructors](#Constructors)
  - [Predicates](#Predicates)
  - [Selectors](#Selectors)
  - [Miscellaneous: length, append, reverse, zip & count](#Miscellaneous)
  - [Fold, unfold, and map](#FoldUnfoldMap)
  - [Filtering & partitioning](#FilteringPartitioning)
  - [Searching](#Searching)
  - [Deletion](#Deletion)
  - [Association lists](#AssociationLists)
  - [Set operations on lists](#SetOperationsOnLists)
  - [Primitive side-effects](#PrimitiveSideEffects)
- [Acknowledgements](#Acknowledgements)
- [References & links](#ReferencesLinks)
- [Copyright](#Copyright)

## Abstract

<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span> Scheme has an impoverished set of list-processing utilities, which is a problem for authors of portable code. This <span class="abbr" title="Scheme Request for Implementation">SRFI</span> proposes a coherent and comprehensive set of list-processing procedures; it is accompanied by a reference implementation of the spec. The reference implementation is

- portable
- efficient
- completely open, public-domain source

## Rationale

The set of basic list and pair operations provided by R4RS/<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span> Scheme is far from satisfactory. Because this set is so small and basic, most implementations provide additional utilities, such as a list-filtering function, or a "left fold" operator, and so forth. But, of course, this introduces incompatibilities -- different Scheme implementations provide different sets of procedures.

I have designed a full-featured library of procedures for list processing. While putting this library together, I checked as many Schemes as I could get my hands on. (I have a fair amount of experience with several of these already.) I missed Chez -- no on-line manual that I can find -- but I hit most of the other big, full-featured Schemes. The complete list of list-processing systems I checked is:

<div class="indent">

<span class="abbr" title="Revised^4 Report on Scheme">R4RS</span>/<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span> Scheme, MIT Scheme, Gambit, RScheme, MzScheme, slib, [Common Lisp](#CommonLisp), Bigloo, guile, T, APL and the SML standard basis

</div>

As a result, the library I am proposing is fairly rich.

Following this initial design phase, this library went through several months of discussion on the SRFI mailing lists, and was altered in light of the ideas and suggestions put forth during this discussion.

In parallel with designing this API, I have also written a reference implementation. I have placed this source on the Net with an unencumbered, "open" copyright. A few notes about the reference implementation:

- Although I got procedure names and specs from many Schemes, I wrote this code myself. Thus, there are *no* entanglements. Any Scheme implementor can pick this library up with no worries about copyright problems -- both commercial and non-commercial systems.

- The code is written for portability and should be trivial to port to any Scheme. It has only four deviations from <span class="abbr" title="Revised^4 Report on Scheme">R4RS</span>, clearly discussed in the comments:

  - Use of an `error` procedure;
  - Use of the <span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span> `values` and a simple `receive` macro for producing and consuming multiple return values;
  - Use of simple `:optional` and `let-optionals` macros for optional argument parsing and defaulting;
  - Use of a simple `check-arg` procedure for argument checking.

- It is written for clarity and well-commented. The current source is 768 lines of source code and 826 lines of comments and white space.

- It is written for efficiency. Fast paths are provided for common cases. Side-effecting procedures such as `filter!` avoid unnecessary, redundant `set-cdr!`s which would thrash a generational GC's write barrier and the store buffers of fast processors. Functions reuse longest common tails from input parameters to construct their results where possible. Constant-space iterations are used in preference to recursions; local recursions are used in preference to consing temporary intermediate data structures.

  This is not to say that the implementation can't be tuned up for a specific Scheme implementation. There are notes in comments addressing ways implementors can tune the reference implementation for performance.

In short, I've written the reference implementation to make it as painless as possible for an implementor -- or a regular programmer -- to adopt this library and get good results with it.

## Procedure Index

Here is a short list of the procedures provided by the list-lib package. [R5RS](#R5RS) procedures are shown in <span class="r5rs-proc">bold</span>; extended [R5RS](#R5RS) procedures, in <span class="r5rs-procx">bold italic</span>.

<div class="indent">

Constructors

```proc-index

cons list
xcons cons* make-list list-tabulate
list-copy circular-list iota
```

Predicates

```proc-index

pair? null?
proper-list? circular-list? dotted-list?
not-pair? null-list?
list=
```

Selectors

```proc-index

car cdr ... cddadr cddddr list-ref
first second third fourth fifth sixth seventh eighth ninth tenth
car+cdr
take       drop
take-right drop-right
take!      drop-right!
split-at   split-at!
last last-pair
```

Miscellaneous: length, append, concatenate, reverse, zip & count

```proc-index

length length+
append  concatenate  reverse
append! concatenate! reverse!
append-reverse append-reverse!
zip unzip1 unzip2 unzip3 unzip4 unzip5
count
```

Fold, unfold & map

```proc-index

map for-each
fold       unfold       pair-fold       reduce
fold-right unfold-right pair-fold-right reduce-right
append-map append-map!
map! pair-for-each filter-map map-in-order
```

Filtering & partitioning

```proc-index

filter  partition  remove
filter! partition! remove!
```

Searching

```proc-index

member memq memv
find find-tail
any every
list-index
take-while drop-while take-while!
span break span! break!
```

Deleting

```proc-index

delete  delete-duplicates
delete! delete-duplicates!
```

Association lists

```proc-index

assoc assq assv
alist-cons alist-copy
alist-delete alist-delete!
```

Set operations on lists

```proc-index

lset<= lset= lset-adjoin
lset-union            lset-union!
lset-intersection      lset-intersection!
lset-difference              lset-difference!
lset-xor            lset-xor!
lset-diff+intersection          lset-diff+intersection!
```

Primitive side-effects

```proc-index

set-car! set-cdr!
```

</div>

Four <span class="abbr" title="Revised^4 Report on Scheme">R4RS</span>/<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span> list-processing procedures are extended by this library in backwards-compatible ways:

<div class="indent">

| | |
|----------------|------------------------------------------------------|
| `map for-each` | (Extended to take lists of unequal length) |
| `member assoc` | (Extended to take an optional comparison procedure.) |

</div>

The following <span class="abbr" title="Revised^4 Report on Scheme">R4RS</span>/<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span> list- and pair-processing procedures are also part of list-lib's exports, as defined by the <span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span>:

<div class="indent">

```
cons pair? null?
car cdr ... cdddar cddddr
set-car! set-cdr!
list append reverse
length list-ref
memq memv assq assv
```

</div>

The remaining two <span class="abbr" title="Revised^4 Report on Scheme">R4RS</span>/<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span> list-processing procedures are *not* part of this library:

<div class="indent">

| | |
|-------------|-----------------------------------------------------------|
| `list-tail` | (renamed `drop`) |
| `list?` | (see `proper-list?`, `circular-list?` and `dotted-list?`) |

</div>

## General discussion

A set of general criteria guided the design of this library.

I don't require "destructive" (what I call "linear update") procedures to alter and recycle cons cells from the argument lists. They are allowed to, but not required to. (And the reference implementations I have written *do* recycle the argument lists.)

List-filtering procedures such as `filter` or `delete` do not disorder lists. Elements appear in the answer list in the same order as they appear in the argument list. This constrains implementation, but seems like a desirable feature, since in many uses of lists, order matters. (In particular, disordering an alist is definitely a bad idea.)

Contrariwise, although the reference implementations of the list-filtering procedures share longest common tails between argument and answer lists, it not is part of the spec.

Because lists are an inherently sequential data structure (unlike, say, vectors), list-inspection functions such as `find`, `find-tail`, `for-each`, `any` and `every` commit to a left-to-right traversal order of their argument list.

However, constructor functions, such as `list-tabulate` and the mapping procedures (`append-map`, `append-map!`, `map!`, `pair-for-each`, `filter-map`, `map-in-order`), do *not* specify the dynamic order in which their procedural argument is applied to its various values.

Predicates return useful true values wherever possible. Thus `any` must return the true value produced by its predicate, and `every` returns the final true value produced by applying its predicate argument to the last element of its argument list.

Functionality is provided both in pure and linear-update (potentially destructive) forms wherever this makes sense.

No special status accorded Scheme's built-in equality functions. Any functionality provided in terms of `eq?`, `eqv?`, `equal?` is also available using a client-provided equality function.

Proper design counts for more than backwards compatibility, but I have tried, *ceteris paribus*, to be as backwards-compatible as possible with existing list-processing libraries, in order to facilitate porting old code to run as a client of the procedures in this library. Name choices and semantics are, for the most part, in agreement with existing practice in many current Scheme systems. I have indicated some incompatibilities in the following text.

These procedures are *not* "sequence generic" -- *i.e.*, procedures that operate on either vectors and lists. They are list-specific. I prefer to keep the library simple and focussed.

I have named these procedures without a qualifying initial "list-" lexeme, which is in keeping with the existing set of list-processing utilities in Scheme. I follow the general Scheme convention (vector-length, string-ref) of placing the type-name before the action when naming procedures -- so we have `list-copy` and `pair-for-each` rather than the perhaps more fluid, but less consistent, `copy-list` or `for-each-pair`.

I have generally followed a regular and consistent naming scheme, composing procedure names from a set of basic lexemes.

## <span id="LinearUpdateProcedures">"Linear update" procedures</span>

Many procedures in this library have "pure" and "linear update" variants. A "pure" procedure has no side-effects, and in particular does not alter its arguments in any way. A "linear update" procedure is allowed -- but *not* required -- to side-effect its arguments in order to construct its result. "Linear update" procedures are typically given names ending with an exclamation point. So, for example, `(append! list1 list2)` is allowed to construct its result by simply using `set-cdr!` to set the cdr of the last pair of `list`<sub>`1`</sub> to point to `list`<sub>`2`</sub>, and then returning `list`<sub>`1`</sub> (unless `list`<sub>`1`</sub> is the empty list, in which case it would simply return `list`<sub>`2`</sub>). However, `append!` may also elect to perform a pure append operation -- this is a legal definition of `append!`:

```code-example

(define append! append)
```

This is why we do not call these procedures "destructive" -- because they aren't *required* to be destructive. They are *potentially* destructive.

What this means is that you may only apply linear-update procedures to values that you know are "dead" -- values that will never be used again in your program. This must be so, since you can't rely on the value passed to a linear-update procedure after that procedure has been called. It might be unchanged; it might be altered.

The "linear" in "linear update" doesn't mean "linear time" or "linear space" or any sort of multiple-of-n kind of meaning. It's a fancy term that type theorists and pure functional programmers use to describe systems where you are only allowed to have exactly one reference to each variable. This provides a guarantee that the value bound to a variable is bound to no other variable. So when you *use* a variable in a variable reference, you "use it up." Knowing that no one else has a pointer to that value means the a system primitive is free to side-effect its arguments to produce what is, observationally, a pure-functional result.

In the context of this library, "linear update" means you, the programmer, know there are *no other* live references to the value passed to the procedure -- after passing the value to one of these procedures, the value of the old pointer is indeterminate. Basically, you are licensing the Scheme implementation to alter the data structure if it feels like it -- you have declared you don't care either way.

You get no help from Scheme in checking that the values you claim are "linear" really are. So you better get it right. Or play it safe and use the non-! procedures -- it doesn't do any good to compute quickly if you get the wrong answer.

Why go to all this trouble to define the notion of "linear update" and use it in a procedure spec, instead of the more common notion of a "destructive" operation? First, note that destructive list-processing procedures are almost always used in a linear-update fashion. This is in part required by the special case of operating upon the empty list, which can't be side-effected. This means that destructive operators are not pure side-effects -- they have to return a result. Second, note that code written using linear-update operators can be trivially ported to a pure, functional subset of Scheme by simply providing pure implementations of the linear-update operators. Finally, requiring destructive side-effects ruins opportunities to parallelise these operations -- and the places where one has taken the trouble to spell out destructive operations are usually exactly the code one would want a parallelising compiler to parallelise: the efficiency-critical kernels of the algorithm. Linear-update operations are easily parallelised. Going with a linear-update spec doesn't close off these valuable alternative implementation techniques. This list library is intended as a set of low-level, basic operators, so we don't want to exclude these possible implementations.

The linear-update procedures in this library are

<div class="indent">

`take! drop-right! split-at! append! concatenate! reverse! append-reverse! append-map! map! filter! partition! remove! take-while! span! break! delete! alist-delete! delete-duplicates! lset-union! lset-intersection! lset-difference! lset-xor! lset-diff+intersection!`

</div>

## <span id="ImproperLists">Improper Lists</span>

Scheme does not properly have a list type, just as C does not have a string type. Rather, Scheme has a binary-tuple type, from which one can build binary trees. There is an *interpretation* of Scheme values that allows one to treat these trees as lists. Further complications ensue from the fact that Scheme allows side-effects to these tuples, raising the possibility of lists of unbounded length, and trees of unbounded depth (that is, circular data structures).

However, there is a simple view of the world of Scheme values that considers every value to be a list of some sort. that is, every value is either

- a "proper list" -- a finite, nil-terminated list, such as:\
  `(a b c)`\
  `()`\
  `(32)`\\
- a "dotted list" -- a finite, non-nil terminated list, such as:\
  `(a b c . d)`\
  `(x . y)`\
  `42`\
  `george`\\
- or a "circular list" -- an infinite, unterminated list.

Note that the zero-length dotted lists are simply all the non-null, non-pair values.

This view is captured by the predicates `proper-list?`, `dotted-list?`, and `circular-list?`. List-lib users should note that dotted lists are not commonly used, and are considered by many Scheme programmers to be an ugly artifact of Scheme's lack of a true list type. However, dotted lists do play a noticeable role in the *syntax* of Scheme, in the "rest" parameters used by n-ary lambdas: `(lambda (x y . rest) ...)`.

Dotted lists are *not* fully supported by list-lib. Most procedures are defined only on proper lists -- that is, finite, nil-terminated lists. The procedures that will also handle circular or dotted lists are specifically marked. While this design decision restricts the domain of possible arguments one can pass to these procedures, it has the benefit of allowing the procedures to catch the error cases where programmers inadvertently pass scalar values to a list procedure by accident, *e.g.*, by switching the arguments to a procedure call.

## <span id="Errors">Errors</span>

Note that statements of the form "it is an error" merely mean "don't do that." They are not a guarantee that a conforming implementation will "catch" such improper use by, for example, raising some kind of exception. Regrettably, <span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span> Scheme requires no firmer guarantee even for basic operators such as `car` and `cdr`, so there's little point in requiring these procedures to do more. Here is the relevant section of the <span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span>:

> When speaking of an error situation, this report uses the phrase "an error is signalled" to indicate that implementations must detect and report the error. If such wording does not appear in the discussion of an error, then implementations are not required to detect or report the error, though they are encouraged to do so. An error situation that implementations are not required to detect is usually referred to simply as "an error."
>
> For example, it is an error for a procedure to be passed an argument that the procedure is not explicitly specified to handle, even though such domain errors are seldom mentioned in this report. Implementations may extend a procedure's domain of definition to include such arguments.

## <span id="NotIncludedInThisLibrary">Not included in this library</span>

The following items are not in this library:

- Sort routines
- Destructuring/pattern-matching macro
- Tree-processing routines

They should have their own <span class="abbr" title="Scheme Request for Implementation">SRFI</span> specs.

## The procedures

In a Scheme system that has a module or package system, these procedures should be contained in a module named "list-lib".

The templates given below obey the following conventions for procedure formals:

| | |
|:-------------------|--------------------------------------------------------|
| `list` | A proper (finite, nil-terminated) list |
| `clist` | A proper or circular list |
| `flist` | A finite (proper or dotted) list |
| `pair` | A pair |
| `x`, `y`, `d`, `a` | Any value |
| `object`, `value` | Any value |
| `n`, `i` | A natural number (an integer >= 0) |
| `proc` | A procedure |
| `pred` | A procedure whose return value is treated as a boolean |
| `=` | A boolean procedure taking two arguments |

It is an error to pass a circular or dotted list to a procedure not defined to accept such an argument.

## Constructors

<span id="cons"></span> `cons` `a d -> pair`\
\[<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span>\] The primitive constructor. Returns a newly allocated pair whose car is `a` and whose cdr is `d`. The pair is guaranteed to be different (in the sense of `eqv?`) from every existing object.

```code-example

(cons 'a '())        => (a)
(cons '(a) '(b c d)) => ((a) b c d)
(cons "a" '(b c))    => ("a" b c)
(cons 'a 3)          => (a . 3)
(cons '(a b) 'c)     => ((a b) . c)
```

<span id="list"></span> `list` `object ... -> list`\
\[<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span>\] Returns a newly allocated list of its arguments.

```code-example

(list 'a (+ 3 4) 'c) =>  (a 7 c)
(list)               =>  ()
```

<span id="xcons"></span> `xcons` `d a -> pair`

```
(lambda (d a) (cons a d))
```

Of utility only as a value to be conveniently passed to higher-order procedures.

```code-example

(xcons '(b c) 'a) => (a b c)
```

The name stands for "eXchanged CONS."

``` cons*`` elt ```<sub>`1`</sub>` elt`<sub>`2`</sub>` ... -> object`\
Like `list`, but the last argument provides the tail of the constructed list, returning

<div class="indent">

```  (cons ``elt ```<sub>`1`</sub>```  (cons ``elt ```<sub>`2`</sub>```  (cons ... ``elt ```<sub>`n`</sub>`))) `

</div>

This function is called `list*` in [Common Lisp](#CommonLisp) and about half of the Schemes that provide it, and `cons*` in the other half.

```code-example

(cons* 1 2 3 4) => (1 2 3 . 4)
(cons* 1) => 1
```

`make-list` `n [fill] -> list`\
Returns an `n`-element list, whose elements are all the value `fill`. If the `fill` argument is not given, the elements of the list may be arbitrary values.

```code-example

(make-list 4 'c) => (c c c c)
```

``` list-tabulate`` n init-proc -> list ```\
Returns an `n`-element list. Element `i` of the list, where 0 \<= `i` < `n`, is produced by ``` (``init-proc`` ``i``) ```. No guarantee is made about the dynamic order in which `init-proc` is applied to these indices.

```code-example

(list-tabulate 4 values) => (0 1 2 3)
```

``` list-copy`` flist -> flist ```\
Copies the spine of the argument.

``` circular-list`` elt ```<sub>`1`</sub>` elt`<sub>`2`</sub>` ... -> clist`\
Constructs a circular list of the elements.

```code-example

(circular-list 'z 'q) => (z q z q z q ...)
```

``` iota`` count [start step] -> list ```\
Returns a list containing the elements

```code-example

(start start+step ... start+(count-1)*step)
```

The `start` and `step` parameters default to 0 and 1, respectively. This procedure takes its name from the APL primitive.

```code-example

(iota 5) => (0 1 2 3 4)
(iota 5 0 -0.1) => (0 -0.1 -0.2 -0.3 -0.4)
```

## <span id="Predicates">Predicates</span>

Note: the predicates `proper-list?`, `circular-list?`, and `dotted-list?` partition the entire universe of Scheme values.

``` proper-list?`` x -> boolean ``` <span id="proper-list-p"></span>\
Returns true iff `x` is a proper list -- a finite, nil-terminated list.

More carefully: The empty list is a proper list. A pair whose cdr is a proper list is also a proper list:

```
<proper-list> ::= ()                            (Empty proper list)
              |   (cons <x> <proper-list>)      (Proper-list pair)
```

Note that this definition rules out circular lists. This function is required to detect this case and return false.

Nil-terminated lists are called "proper" lists by <span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span> and [Common Lisp](#CommonLisp). The opposite of proper is improper.

<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span> binds this function to the variable `list?`.

```
(not (proper-list? x)) = (or (dotted-list? x) (circular-list? x))
```

``` circular-list?`` x -> boolean ```\
True if `x` is a circular list. A circular list is a value such that for every `n` >= 0, cdr<sup>`n`</sup>(`x`) is a pair.

Terminology: The opposite of circular is finite.

```
(not (circular-list? x)) = (or (proper-list? x) (dotted-list? x))
```

``` dotted-list?`` x -> boolean ```\
True if `x` is a finite, non-nil-terminated list. That is, there exists an `n` >= 0 such that cdr<sup>`n`</sup>(`x`) is neither a pair nor (). This includes non-pair, non-() values (*e.g.* symbols, numbers), which are considered to be dotted lists of length 0.

```
(not (dotted-list? x)) = (or (proper-list? x) (circular-list? x))
```

``` pair?`` object -> boolean ```\
\[<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span>\] Returns #t if `object` is a pair; otherwise, #f.

```code-example

(pair? '(a . b)) =>  #t
(pair? '(a b c)) =>  #t
(pair? '())      =>  #f
(pair? '#(a b))  =>  #f
(pair? 7)        =>  #f
(pair? 'a)       =>  #f
```

``` null?`` object -> boolean ```\
\[<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span>\] Returns #t if `object` is the empty list; otherwise, #f.

``` null-list?`` list -> boolean ```\
`List` is a proper or circular list. This procedure returns true if the argument is the empty list (), and false otherwise. It is an error to pass this procedure a value which is not a proper or circular list.

This procedure is recommended as the termination condition for list-processing procedures that are not defined on dotted lists.

<span id="not-pair-p"></span> ``` not-pair?`` x -> boolean ```\
(lambda (x) (not (pair? x)))

Provided as a procedure as it can be useful as the termination condition for list-processing procedures that wish to handle all finite lists, both proper and dotted.

<span id="list="></span> ``` list=`` elt= list ```<sub>`1`</sub>` ... -> boolean`\
Determines list equality, given an element-equality procedure. Proper list `A` equals proper list `B` if they are of the same length, and their corresponding elements are equal, as determined by `elt=`. If the element-comparison procedure's first argument is from `list`<sub>`i`</sub>, then its second argument is from `list`<sub>`i+1`</sub>, *i.e.* it is always called as ``` (``elt=`` ``a`` ``b``) ``` for `a` an element of list `A`, and `b` an element of list `B`.

In the `n`-ary case, every `list`<sub>`i`</sub> is compared to `list`<sub>`i+1`</sub> (as opposed, for example, to comparing `list`<sub>`1`</sub> to every `list`<sub>`i`</sub>, for `i`>1). If there are no list arguments at all, `list=` simply returns true.

It is an error to apply `list=` to anything except proper lists. While implementations may choose to extend it to circular lists, note that it cannot reasonably be extended to dotted lists, as it provides no way to specify an equality procedure for comparing the list terminators.

Note that the dynamic order in which the `elt=` procedure is applied to pairs of elements is not specified. For example, if `list=` is applied to three lists, `A`, `B`, and `C`, it may first completely compare `A` to `B`, then compare `B` to `C`, or it may compare the first elements of `A` and `B`, then the first elements of `B` and `C`, then the second elements of `A` and `B`, and so forth.

The equality procedure must be consistent with `eq?`. That is, it must be the case that

<div class="indent">

``` (eq? ``x`` ``y``) ``` => ``` (``elt=`` ``x`` ``y``) ```.

</div>

Note that this implies that two lists which are `eq?` are always `list=`, as well; implementations may exploit this fact to "short-cut" the element-by-element comparisons.

```code-example

(list= eq?) => #t       ; Trivial cases
(list= eq? '(a)) => #t
```

## Selectors

``` car`` pair -> value ```\
``` cdr`` pair -> value ```\
\[<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span>\] These functions return the contents of the car and cdr field of their argument, respectively. Note that it is an error to apply them to the empty list.

```code-example

(car '(a b c))     =>  a             (cdr '(a b c))     =>  (b c)
(car '((a) b c d)) =>  (a)        (cdr '((a) b c d)) =>  (b c d)
(car '(1 . 2))     =>  1      (cdr '(1 . 2))     =>  2
(car '())          =>  *error*        (cdr '())          =>  *error*
```

``` caar`` pair -> value ```\
``` cadr`` pair -> value ```\
`:`\
``` cddadr`` pair -> value ```\
``` cdddar`` pair -> value ```\
``` cddddr`` pair -> value ```\
\[<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span>\] These procedures are compositions of `car` and `cdr`, where for example `caddr` could be defined by

```code-example

(define caddr (lambda (x) (car (cdr (cdr x))))).
```

Arbitrary compositions, up to four deep, are provided. There are twenty-eight of these procedures in all.

``` list-ref`` clist i -> value ```\
\[<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span>\] Returns the `i`<sup>th</sup> element of `clist`. (This is the same as the car of ``` (drop ``clist`` ``i``) ```.) It is an error if `i` >= `n`, where `n` is the length of `clist`.

```code-example

(list-ref '(a b c d) 2) => c
```

<span id="first"></span> ``` first   ``pair -> object  ```\
<span id="second"></span> ``` second  ``pair -> object  ```\
<span id="third"></span> ``` third   ``pair -> object  ```\
<span id="fourth"></span> ``` fourth  ``pair -> object  ```\
<span id="fifth"></span> ``` fifth   ``pair -> object  ```\
<span id="sixth"></span> ``` sixth   ``pair -> object  ```\
<span id="seventh"></span> ``` seventh ``pair -> object  ```\
<span id="eighth"></span> ``` eighth  ``pair -> object  ```\
<span id="ninth"></span> ``` ninth   ``pair -> object  ```\
<span id="tenth"></span> ``` tenth   ``pair -> object  ```\
Synonyms for `car`, `cadr`, `caddr`, ...

```code-example

(third '(a b c d e)) => c
```

<span id="car+cdr"></span> ``` car+cdr`` pair -> [x y] ```\
The fundamental pair deconstructor:

```code-example

(lambda (p) (values (car p) (cdr p)))
```

This can, of course, be implemented more efficiently by a compiler.

<span id="take"></span> ``` take`` x i -> list ```\
<span id="drop"></span> ``` drop`` x i -> object ```\
`take` returns the first `i` elements of list `x`.\
`drop` returns all but the first `i` elements of list `x`.

```code-example

(take '(a b c d e)  2) => (a b)
(drop '(a b c d e)  2) => (c d e)
```

`x` may be any value -- a proper, circular, or dotted list:

```code-example

(take '(1 2 3 . d) 2) => (1 2)
(drop '(1 2 3 . d) 2) => (3 . d)
(take '(1 2 3 . d) 3) => (1 2 3)
(drop '(1 2 3 . d) 3) => d
```

For a legal `i`, `take` and `drop` partition the list in a manner which can be inverted with `append`:

```code-example

(append (take x i) (drop x i)) = x
```

`drop` is exactly equivalent to performing `i` cdr operations on `x`; the returned value shares a common tail with `x`. If the argument is a list of non-zero length, `take` is guaranteed to return a freshly-allocated list, even in the case where the entire list is taken, *e.g.* `(take lis (length lis))`.

<span id="take-right"></span> ``` take-right`` flist i -> object ```\
<span id="drop-right"></span> ``` drop-right`` flist i -> list ```\
`take-right` returns the last `i` elements of `flist`.\
`drop-right` returns all but the last `i` elements of `flist`.

```code-example

(take-right '(a b c d e) 2) => (d e)
(drop-right '(a b c d e) 2) => (a b c)
```

The returned list may share a common tail with the argument list.

`flist` may be any finite list, either proper or dotted:

```code-example

(take-right '(1 2 3 . d) 2) => (2 3 . d)
(drop-right '(1 2 3 . d) 2) => (1)
(take-right '(1 2 3 . d) 0) => d
(drop-right '(1 2 3 . d) 0) => (1 2 3)
```

For a legal `i`, `take-right` and `drop-right` partition the list in a manner which can be inverted with `append`:

```code-example

(append (drop-right flist i) (take-right flist i)) = flist
```

`take-right`'s return value is guaranteed to share a common tail with `flist`. If the argument is a list of non-zero length, `drop-right` is guaranteed to return a freshly-allocated list, even in the case where nothing is dropped, *e.g.* `(drop-right lis 0)`.

<span id="take!"></span> ``` take!`` x i -> list ```\
<span id="drop-right!"></span> ``` drop-right!`` flist i -> list ```\
`take!` and `drop-right!` are "linear-update" variants of `take` and `drop-right`: the procedure is allowed, but not required, to alter the argument list to produce the result.

If `x` is circular, `take!` may return a shorter-than-expected list:

```code-example

(take! (circular-list 1 3 5) 8) => (1 3)
(take! (circular-list 1 3 5) 8) => (1 3 5 1 3 5 1 3)
```

<span id="split-at"></span> ``` split-at `` x i -> [list object] ```\
<span id="split-at!"></span> ``` split-at!`` x i -> [list object] ```\
`split-at` splits the list `x` at index `i`, returning a list of the first `i` elements, and the remaining tail. It is equivalent to

```code-example

(values (take x i) (drop x i))
```

`split-at!` is the linear-update variant. It is allowed, but not required, to alter the argument list to produce the result.

```code-example

(split-at '(a b c d e f g h) 3) =>
    (a b c)
    (d e f g h)
```

<span id="last"></span> ``` last`` pair -> object ```\
<span id="last-pair"></span> ``` last-pair`` pair -> pair ```\
`last` returns the last element of the non-empty, finite list `pair`. `last-pair` returns the last pair in the non-empty, finite list `pair`.

```code-example

(last '(a b c)) => c
(last-pair '(a b c)) => (c)
```

## <span id="Miscellaneous">Miscellaneous: length, append, concatenate, reverse, zip & count</span>

<span id="length"></span> ``` length  ``list -> integer ```\
<span id="length+"></span> ``` length+ ``clist -> integer or #f ```\
Both `length` and `length+` return the length of the argument. It is an error to pass a value to `length` which is not a proper list (finite and nil-terminated). In particular, this means an implementation may diverge or signal an error when `length` is applied to a circular list.

`length+`, on the other hand, returns `#F` when applied to a circular list.

The length of a proper list is a non-negative integer `n` such that `cdr` applied `n` times to the list produces the empty list.

<span id="append"></span> ``` append `` list ```<sub>`1`</sub>` ... -> list`\
<span id="append!"></span> ``` append!`` list ```<sub>`1`</sub>` ... -> list`\
\[<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span>\] `append` returns a list consisting of the elements of `list`<sub>`1`</sub> followed by the elements of the other list parameters.

```code-example

(append '(x) '(y))        =>  (x y)
(append '(a) '(b c d))    =>  (a b c d)
(append '(a (b)) '((c)))  =>  (a (b) (c))
```

The resulting list is always newly allocated, except that it shares structure with the final `list`<sub>`i`</sub> argument. This last argument may be any value at all; an improper list results if it is not a proper list. All other arguments must be proper lists.

```code-example

(append '(a b) '(c . d))  =>  (a b c . d)
(append '() 'a)           =>  a
(append '(x y))           =>  (x y)
(append)                  =>  ()
```

`append!` is the "linear-update" variant of `append` -- it is allowed, but not required, to alter cons cells in the argument lists to construct the result list. The last argument is never altered; the result list shares structure with this parameter.

<span id="concatenate"></span> ``` concatenate `` list-of-lists -> value ```\
<span id="concatenate!"></span> ``` concatenate!`` list-of-lists -> value ```\
These functions append the elements of their argument together. That is, `concatenate` returns

```code-example

(apply append list-of-lists)
```

or, equivalently,

```code-example

(reduce-right append '() list-of-lists)
```

`concatenate!` is the linear-update variant, defined in terms of `append!` instead of `append`.

Note that some Scheme implementations do not support passing more than a certain number (*e.g.*, 64) of arguments to an n-ary procedure. In these implementations, the `(apply append ...)` idiom would fail when applied to long lists, but `concatenate` would continue to function properly.

As with `append` and `append!`, the last element of the input list may be any value at all.

<span id="reverse"></span> ``` reverse `` list -> list ```\
<span id="reverse!"></span> ``` reverse!`` list -> list ```\
\[<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span>\] `reverse` returns a newly allocated list consisting of the elements of `list` in reverse order.

```code-example

(reverse '(a b c)) =>  (c b a)
(reverse '(a (b c) d (e (f))))
    =>  ((e (f)) d (b c) a)
```

`reverse!` is the linear-update variant of `reverse`. It is permitted, but not required, to alter the argument's cons cells to produce the reversed list.

<span id="append-reverse"></span> ``` append-reverse  ``rev-head tail -> list ```\
<span id="append-reverse!"></span> ``` append-reverse! ``rev-head tail -> list ```\
`append-reverse` returns ``` (append (reverse ``rev-head``) ``tail``) ```. It is provided because it is a common operation -- a common list-processing style calls for this exact operation to transfer values accumulated in reverse order onto the front of another list, and because the implementation is significantly more efficient than the simple composition it replaces. (But note that this pattern of iterative computation followed by a reverse can frequently be rewritten as a recursion, dispensing with the `reverse` and `append-reverse` steps, and shifting temporary, intermediate storage from the heap to the stack, which is typically a win for reasons of cache locality and eager storage reclamation.)

`append-reverse!` is just the linear-update variant -- it is allowed, but not required, to alter `rev-head`'s cons cells to construct the result.

`zip` `clist`<sub>`1`</sub>` clist`<sub>`2`</sub>` ... -> list`\
(lambda lists (apply map list lists))

If `zip` is passed `n` lists, it returns a list as long as the shortest of these lists, each element of which is an `n`-element list comprised of the corresponding elements from the parameter lists.

```code-example

(zip '(one two three)
     '(1 2 3)
     '(odd even odd even odd even odd even))
    => ((one 1 odd) (two 2 even) (three 3 odd))

(zip '(1 2 3)) => ((1) (2) (3))
```

At least one of the argument lists must be finite:

```code-example

(zip '(3 1 4 1) (circular-list #f #t))
    => ((3 #f) (1 #t) (4 #f) (1 #t))
```

``` unzip1`` list -> list ```\
``` unzip2`` list -> [list list] ```\
``` unzip3`` list -> [list list list] ```\
``` unzip4`` list -> [list list list list] ```\
``` unzip5`` list -> [list list list list list] ```\
`unzip1` takes a list of lists, where every list must contain at least one element, and returns a list containing the initial element of each such list. That is, it returns `(map car lists)`. `unzip2` takes a list of lists, where every list must contain at least two elements, and returns two values: a list of the first elements, and a list of the second elements. `unzip3` does the same for the first three elements of the lists, and so forth.

```code-example

(unzip2 '((1 one) (2 two) (3 three))) =>
    (1 2 3)
    (one two three)
```

<span id="count"></span> ``` count`` pred clist ```<sub>`1`</sub>` clist`<sub>`2`</sub>` ... -> integer`\
`pred` is a procedure taking as many arguments as there are lists and returning a single value. It is applied element-wise to the elements of the `list`s, and a count is tallied of the number of elements that produce a true value. This count is returned. `count` is "iterative" in that it is guaranteed to apply `pred` to the `list` elements in a left-to-right order. The counting stops when the shortest list expires.

```code-example

(count even? '(3 1 4 1 5 9 2 5 6)) => 3
(count < '(1 2 4 8) '(2 4 6 8 10 12 14 16)) => 3
```

At least one of the argument lists must be finite:

```code-example

(count < '(3 1 4 1) (circular-list 1 10)) => 2
```

## Fold, unfold & map

<span id="fold"></span> ``` fold`` kons knil clist ```<sub>`1`</sub>` clist`<sub>`2`</sub>` ... -> value`\
The fundamental list iterator.

First, consider the single list-parameter case. If `clist`<sub>`1`</sub> = (`e`<sub>`1`</sub> `e`<sub>`2`</sub> ... `e`<sub>`n`</sub>), then this procedure returns

<div class="indent">

``` (``kons`` ``e ```<sub>`n`</sub>```  ... (``kons`` ``e ```<sub>`2`</sub>```  (``kons`` ``e ```<sub>`1`</sub>```  ``knil``)) ... ) ```

</div>

That is, it obeys the (tail) recursion

```code-example

(fold kons knil lis) = (fold kons (kons (car lis) knil) (cdr lis))
(fold kons knil '()) = knil
```

Examples:

```code-example

(fold + 0 lis)          ; Add up the elements of LIS.

(fold cons '() lis)     ; Reverse LIS.

(fold cons tail rev-head)   ; See APPEND-REVERSE.

;; How many symbols in LIS?
(fold (lambda (x count) (if (symbol? x) (+ count 1) count))
      0
      lis)

;; Length of the longest string in LIS:
(fold (lambda (s max-len) (max max-len (string-length s)))
      0
      lis)
```

If `n` list arguments are provided, then the `kons` function must take `n`+1 parameters: one element from each list, and the "seed" or fold state, which is initially `knil`. The fold operation terminates when the shortest list runs out of values:

```code-example

(fold cons* '() '(a b c) '(1 2 3 4 5)) => (c 3 b 2 a 1)
```

At least one of the list arguments must be finite.

<span id="fold-right"></span> ``` fold-right`` kons knil clist ```<sub>`1`</sub>` clist`<sub>`2`</sub>` ... -> value`\
The fundamental list recursion operator.

First, consider the single list-parameter case. If `clist`<sub>`1`</sub> = ``` (``e ```<sub>`1`</sub>```  ``e ```<sub>`2`</sub>```  ... ``e ```<sub>`n`</sub>`)`, then this procedure returns

<div class="indent">

```  (``kons`` ``e ```<sub>`1`</sub>```  (``kons`` ``e ```<sub>`2`</sub>```  ... (``kons`` ``e ```<sub>`n`</sub>``` ``knil``))) ```

</div>

That is, it obeys the recursion

```code-example

(fold-right kons knil lis) = (kons (car lis) (fold-right kons knil (cdr lis)))
(fold-right kons knil '()) = knil
```

Examples:

```code-example

(fold-right cons '() lis)       ; Copy LIS.

;; Filter the even numbers out of LIS.
(fold-right (lambda (x l) (if (even? x) (cons x l) l)) '() lis))
```

If `n` list arguments are provided, then the `kons` function must take `n`+1 parameters: one element from each list, and the "seed" or fold state, which is initially `knil`. The fold operation terminates when the shortest list runs out of values:

```code-example

(fold-right cons* '() '(a b c) '(1 2 3 4 5)) => (a 1 b 2 c 3)
```

At least one of the list arguments must be finite.

<span id="pair-fold"></span> ``` pair-fold`` kons knil clist ```<sub>`1`</sub>` clist`<sub>`2`</sub>` ... -> value`\
Analogous to `fold`, but `kons` is applied to successive sublists of the lists, rather than successive elements -- that is, `kons` is applied to the pairs making up the lists, giving this (tail) recursion:

```code-example

(pair-fold kons knil lis) = (let ((tail (cdr lis)))
                              (pair-fold kons (kons lis knil) tail))
(pair-fold kons knil '()) = knil
```

For finite lists, the `kons` function may reliably apply `set-cdr!` to the pairs it is given without altering the sequence of execution.

Example:

```code-example

;;; Destructively reverse a list.
(pair-fold (lambda (pair tail) (set-cdr! pair tail) pair) '() lis)
```

At least one of the list arguments must be finite.

<span id="pair-fold-right"></span> ``` pair-fold-right`` kons knil clist ```<sub>`1`</sub>` clist`<sub>`2`</sub>` ... -> value`\
Holds the same relationship with `fold-right` that `pair-fold` holds with `fold`. Obeys the recursion

```code-example

(pair-fold-right kons knil lis) =
    (kons lis (pair-fold-right kons knil (cdr lis)))
(pair-fold-right kons knil '()) = knil
```

Example:

```code-example

(pair-fold-right cons '() '(a b c)) => ((a b c) (b c) (c))
```

At least one of the list arguments must be finite.

<span id="reduce"></span> ``` reduce`` f ridentity list -> value ```\
`reduce` is a variant of `fold`.

`ridentity` should be a "right identity" of the procedure `f` -- that is, for any value `x` acceptable to `f`,

```code-example

(f x ridentity) = x
```

`reduce` has the following definition:

<div class="indent">

If `list` = (), return `ridentity`;\
Otherwise, return ``` (fold ``f`` (car ``list``) (cdr ``list``)) ```.

</div>

...in other words, we compute ``` (fold ``f`` ``ridentity`` ``list``) ```.

Note that `ridentity` is used *only* in the empty-list case. You typically use `reduce` when applying `f` is expensive and you'd like to avoid the extra application incurred when `fold` applies `f` to the head of `list` and the identity value, redundantly producing the same value passed in to `f`. For example, if `f` involves searching a file directory or performing a database query, this can be significant. In general, however, `fold` is useful in many contexts where `reduce` is not (consider the examples given in the `fold` definition -- only one of the five folds uses a function with a right identity. The other four may not be performed with `reduce`).

Note: MIT Scheme and Haskell flip F's arg order for their `reduce` and `fold` functions.

```code-example

;; Take the max of a list of non-negative integers.
(reduce max 0 nums) ; i.e., (apply max 0 nums)
```

<span id="reduce-right"></span> ``` reduce-right`` f ridentity list -> value ```\
`reduce-right` is the fold-right variant of `reduce`. It obeys the following definition:

```code-example

(reduce-right f ridentity '()) = ridentity
(reduce-right f ridentity '(e1)) = (f e1 ridentity) = e1
(reduce-right f ridentity '(e1 e2 ...)) =
    (fold-right f e1 '(e2 ...))
```

... in other words, we compute ``` (fold-right ``f`` ``ridentity`` ``list``) ```, but as with `reduce`, only use `ridentity` in the empty-list case.

```code-example

;; Append a bunch of lists together.
;; I.e., (apply append list-of-lists)
(reduce-right append '() list-of-lists)
```

<span id="unfold"></span> ``` unfold`` p f g seed [tail-gen] -> list ```\
`unfold` is best described by its basic recursion:

```code-example

(unfold p f g seed) =
    (if (p seed) (tail-gen seed)
        (cons (f seed)
              (unfold p f g (g seed))))
```

`p`\
Determines when to stop unfolding.

`f`\
Maps each seed value to the corresponding list element.

`g`\
Maps each seed value to next seed value.

`seed`\
The "state" value for the unfold.

`tail-gen`\
Creates the tail of the list; defaults to `(lambda (x) '())`

In other words, we use `g` to generate a sequence of seed values

<div class="indent">

`seed`, `g`(`seed`), `g`<sup>`2`</sup>(`seed`), `g`<sup>`3`</sup>(`seed`), ...

</div>

These seed values are mapped to list elements by `f`, producing the elements of the result list in a left-to-right order. `P` says when to stop.

`unfold` is the fundamental recursive list constructor, just as `fold-right` is the fundamental recursive list consumer. While `unfold` may seem a bit abstract to novice functional programmers, it can be used in a number of ways:

```code-example

;; List of squares: 1^2 ... 10^2
(unfold (lambda (x) (> x 10))
        (lambda (x) (* x x))
    (lambda (x) (+ x 1))
    1)

(unfold null-list? car cdr lis) ; Copy a proper list.

;; Read current input port into a list of values.
(unfold eof-object? values (lambda (x) (read)) (read))

;; Copy a possibly non-proper list:
(unfold not-pair? car cdr lis
              values)

;; Append HEAD onto TAIL:
(unfold null-list? car cdr head
              (lambda (x) tail))
```

Interested functional programmers may enjoy noting that `fold-right` and `unfold` are in some sense inverses. That is, given operations `knull?`, `kar`, `kdr`, `kons`, and `knil` satisfying

<div class="indent">

``` (``kons`` (``kar`` ``x``) (``kdr`` ``x``)) ``` = `x` and ``` (``knull?`` ``knil``) ``` = `#t`

</div>

then

<div class="indent">

``` (fold-right ``kons`` ``knil`` (unfold ``knull?`` ``kar`` ``kdr`` ``x``)) ``` = `x`

</div>

and

<div class="indent">

``` (unfold ``knull?`` ``kar`` ``kdr`` (fold-right ``kons`` ``knil`` ``x``)) ``` = `x`.

</div>

This combinator sometimes is called an "anamorphism;" when an explicit `tail-gen` procedure is supplied, it is called an "apomorphism."

<span id="unfold-right"></span> ``` unfold-right`` p f g seed [tail] -> list ```\
`unfold-right` constructs a list with the following loop:

```code-example

(let lp ((seed seed) (lis tail))
  (if (p seed) lis
      (lp (g seed)
          (cons (f seed) lis))))
```

`p`\
Determines when to stop unfolding.

`f`\
Maps each seed value to the corresponding list element.

`g`\
Maps each seed value to next seed value.

`seed`\
The "state" value for the unfold.

`tail`\
list terminator; defaults to `'()`.

In other words, we use `g` to generate a sequence of seed values

<div class="indent">

`seed`, `g`(`seed`), `g`<sup>`2`</sup>(`seed`), `g`<sup>`3`</sup>(`seed`), ...

</div>

These seed values are mapped to list elements by `f`, producing the elements of the result list in a right-to-left order. `P` says when to stop.

`unfold-right` is the fundamental iterative list constructor, just as `fold` is the fundamental iterative list consumer. While `unfold-right` may seem a bit abstract to novice functional programmers, it can be used in a number of ways:

```code-example

;; List of squares: 1^2 ... 10^2
(unfold-right zero?
              (lambda (x) (* x x))
              (lambda (x) (- x 1))
              10)

;; Reverse a proper list.
(unfold-right null-list? car cdr lis)

;; Read current input port into a list of values.
(unfold-right eof-object? values (lambda (x) (read)) (read))

;; (append-reverse rev-head tail)
(unfold-right null-list? car cdr rev-head tail)
```

Interested functional programmers may enjoy noting that `fold` and `unfold-right` are in some sense inverses. That is, given operations `knull?`, `kar`, `kdr`, `kons`, and `knil` satisfying

<div class="indent">

``` (``kons`` (``kar`` ``x``) (``kdr`` ``x``)) ``` = `x` and ``` (``knull?`` ``knil``) ``` = `#t`

</div>

then

<div class="indent">

``` (fold ``kons`` ``knil`` (unfold-right ``knull?`` ``kar`` ``kdr`` ``x``)) ``` = `x`

</div>

and

<div class="indent">

``` (unfold-right ``knull?`` ``kar`` ``kdr`` (fold ``kons`` ``knil`` ``x``)) ``` = `x`.

</div>

This combinator presumably has some pretentious mathematical name; interested readers are invited to communicate it to the author.

<span id="map"></span> ``` map`` proc clist ```<sub>`1`</sub>` clist`<sub>`2`</sub>` ... -> list`\
\[<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span>+\] `proc` is a procedure taking as many arguments as there are list arguments and returning a single value. `map` applies `proc` element-wise to the elements of the lists and returns a list of the results, in order. The dynamic order in which `proc` is applied to the elements of the lists is unspecified.

```code-example

(map cadr '((a b) (d e) (g h))) =>  (b e h)

(map (lambda (n) (expt n n))
     '(1 2 3 4 5))
    =>  (1 4 27 256 3125)

(map + '(1 2 3) '(4 5 6)) =>  (5 7 9)

(let ((count 0))
  (map (lambda (ignored)
         (set! count (+ count 1))
         count)
       '(a b))) =>  (1 2) or (2 1)
```

This procedure is extended from its <span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span> specification to allow the arguments to be of unequal length; it terminates when the shortest list runs out.

At least one of the argument lists must be finite:

```code-example

(map + '(3 1 4 1) (circular-list 1 0)) => (4 1 5 1)
```

<span id="for-each"></span> ``` for-each`` proc clist ```<sub>`1`</sub>` clist`<sub>`2`</sub>` ... -> unspecified`\
\[<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span>+\]

The arguments to `for-each` are like the arguments to `map`, but `for-each` calls `proc` for its side effects rather than for its values. Unlike `map`, `for-each` is guaranteed to call `proc` on the elements of the lists in order from the first element(s) to the last, and the value returned by `for-each` is unspecified.

```code-example

(let ((v (make-vector 5)))
  (for-each (lambda (i)
              (vector-set! v i (* i i)))
            '(0 1 2 3 4))
  v)  =>  #(0 1 4 9 16)
```

This procedure is extended from its <span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span> specification to allow the arguments to be of unequal length; it terminates when the shortest list runs out.

At least one of the argument lists must be finite.

<span id="append-map"></span> ``` append-map  ``f clist ```<sub>`1`</sub>` clist`<sub>`2`</sub>` ... -> value`\
<span id="append-map!"></span> ``` append-map! ``f clist ```<sub>`1`</sub>` clist`<sub>`2`</sub>` ... -> value`\
Equivalent to

<div class="indent">

```  (apply append (map ``f`` ``clist ```<sub>`1`</sub>```  ``clist ```<sub>`2`</sub>`...))`

</div>

and

<div class="indent">

```  (apply append! (map ``f`` ``clist ```<sub>`1`</sub>```  ``clist ```<sub>`2`</sub>`...))`

</div>

Map `f` over the elements of the lists, just as in the `map` function. However, the results of the applications are appended together to make the final result. `append-map` uses `append` to append the results together; `append-map!` uses `append!`.

The dynamic order in which the various applications of `f` are made is not specified.

Example:

```code-example

(append-map! (lambda (x) (list x (- x))) '(1 3 8))
    => (1 -1 3 -3 8 -8)
```

At least one of the list arguments must be finite.

<span id="map!"></span> ``` map!`` f list ```<sub>`1`</sub>` clist`<sub>`2`</sub>` ... -> list`\
Linear-update variant of `map` -- `map!` is allowed, but not required, to alter the cons cells of `list`<sub>`1`</sub> to construct the result list.

The dynamic order in which the various applications of `f` are made is not specified.

In the n-ary case, `clist`<sub>`2`</sub>, `clist`<sub>`3`</sub>, ... must have at least as many elements as `list`<sub>`1`</sub>.

<span id="map-in-order"></span> ``` map-in-order ``f ``` `clist`<sub>`1`</sub>` clist`<sub>`2`</sub>` ... -> list`\
A variant of the `map` procedure that guarantees to apply `f` across the elements of the `list`<sub>`i`</sub> arguments in a left-to-right order. This is useful for mapping procedures that both have side effects and return useful values.

At least one of the list arguments must be finite.

<span id="pair-for-each"></span> ``` pair-for-each ``f clist ```<sub>`1`</sub>` clist`<sub>`2`</sub>` ... -> unspecific`\
Like `for-each`, but `f` is applied to successive sublists of the argument lists. That is, `f` is applied to the cons cells of the lists, rather than the lists' elements. These applications occur in left-to-right order.

The `f` procedure may reliably apply `set-cdr!` to the pairs it is given without altering the sequence of execution.

```code-example

(pair-for-each (lambda (pair) (display pair) (newline)) '(a b c)) ==>
    (a b c)
    (b c)
    (c)
```

At least one of the list arguments must be finite.

<span id="filter-map"></span> ``` filter-map`` f clist ```<sub>`1`</sub>` clist`<sub>`2`</sub>` ... -> list`\
Like `map`, but only true values are saved.

```code-example

(filter-map (lambda (x) (and (number? x) (* x x))) '(a 1 b 3 c 7))
    => (1 9 49)
```

The dynamic order in which the various applications of `f` are made is not specified.

At least one of the list arguments must be finite.

## Filtering & partitioning

<span id="filter"></span> ``` filter`` pred list -> list ```\
Return all the elements of `list` that satisfy predicate `pred`. The list is not disordered -- elements that appear in the result list occur in the same order as they occur in the argument list. The returned list may share a common tail with the argument list. The dynamic order in which the various applications of `pred` are made is not specified.

```code-example

(filter even? '(0 7 8 8 43 -4)) => (0 8 8 -4)
```

<span id="partition"></span> ``` partition`` pred list -> [list list] ```\
Partitions the elements of `list` with predicate `pred`, and returns two values: the list of in-elements and the list of out-elements. The list is not disordered -- elements occur in the result lists in the same order as they occur in the argument list. The dynamic order in which the various applications of `pred` are made is not specified. One of the returned lists may share a common tail with the argument list.

```code-example

(partition symbol? '(one 2 3 four five 6)) =>
    (one four five)
    (2 3 6)
```

<span id="remove"></span> ``` remove`` pred list -> list ```\
Returns `list` without the elements that satisfy predicate `pred`:

```code-example

(lambda (pred list) (filter (lambda (x) (not (pred x))) list))
```

The list is not disordered -- elements that appear in the result list occur in the same order as they occur in the argument list. The returned list may share a common tail with the argument list. The dynamic order in which the various applications of `pred` are made is not specified.

```code-example

(remove even? '(0 7 8 8 43 -4)) => (7 43)
```

<span id="filter!"></span> ``` filter!    ``pred list -> list ```\
<span id="partition!"></span> ``` partition! ``pred list -> [list list] ```\
<span id="remove!"></span> ``` remove!    ``pred list -> list ```\
Linear-update variants of `filter`, `partition` and `remove`. These procedures are allowed, but not required, to alter the cons cells in the argument list to construct the result lists.

## Searching

The following procedures all search lists for a leftmost element satisfying some criteria. This means they do not always examine the entire list; thus, there is no efficient way for them to reliably detect and signal an error when passed a dotted or circular list. Here are the general rules describing how these procedures work when applied to different kinds of lists:

Proper lists:\
The standard, canonical behavior happens in this case.

Dotted lists:\
It is an error to pass these procedures a dotted list that does not contain an element satisfying the search criteria. That is, it is an error if the procedure has to search all the way to the end of the dotted list. However, this <span class="abbr" title="Scheme Request for Implementation">SRFI</span> does *not* specify anything at all about the behavior of these procedures when passed a dotted list containing an element satisfying the search criteria. It may finish successfully, signal an error, or perform some third action. Different implementations may provide different functionality in this case; code which is compliant with this <span class="abbr" title="Scheme Request for Implementation">SRFI</span> may not rely on any particular behavior. Future <span class="abbr" title="Scheme Request for Implementation">SRFI</span>'s may refine SRFI-1 to define specific behavior in this case.

In brief, SRFI-1 compliant code may not pass a dotted list argument to these procedures.

Circular lists:\
It is an error to pass these procedures a circular list that does not contain an element satisfying the search criteria. Note that the procedure is not required to detect this case; it may simply diverge. It is, however, acceptable to search a circular list *if the search is successful* -- that is, if the list contains an element satisfying the search criteria.

Here are some examples, using the `find` and `any` procedures as canonical representatives:

```code-example

;; Proper list -- success
(find even? '(1 2 3))   => 2
(any  even? '(1 2 3))   => #t

;; proper list -- failure
(find even? '(1 7 3))   => #f
(any  even? '(1 7 3))   => #f

;; Failure is error on a dotted list.
(find even? '(1 3 . x)) => error
(any  even? '(1 3 . x)) => error

;; The dotted list contains an element satisfying the search.
;; This case is not specified -- it could be success, an error,
;; or some third possibility.
(find even? '(1 2 . x)) => error/undefined
(any  even? '(1 2 . x)) => error/undefined ; success, error or other.

;; circular list -- success
(find even? (circular-list 1 6 3)) => 6
(any  even? (circular-list 1 6 3)) => #t

;; circular list -- failure is error. Procedure may diverge.
(find even? (circular-list 1 3)) => error
(any  even? (circular-list 1 3)) => error
```

<span id="find"></span> ``` find`` pred clist -> value ```\
Return the first element of `clist` that satisfies predicate `pred`; false if no element does.

```code-example

(find even? '(3 1 4 1 5 9)) => 4
```

Note that `find` has an ambiguity in its lookup semantics -- if `find` returns `#f`, you cannot tell (in general) if it found a `#f` element that satisfied `pred`, or if it did not find any element at all. In many situations, this ambiguity cannot arise -- either the list being searched is known not to contain any `#f` elements, or the list is guaranteed to have an element satisfying `pred`. However, in cases where this ambiguity can arise, you should use `find-tail` instead of `find` -- `find-tail` has no such ambiguity:

```code-example

(cond ((find-tail pred lis) => (lambda (pair) ...)) ; Handle (CAR PAIR)
      (else ...)) ; Search failed.
```

<span id="find-tail"></span> ``` find-tail`` pred clist -> pair or false ```\
Return the first pair of `clist` whose car satisfies `pred`. If no pair does, return false.

`find-tail` can be viewed as a general-predicate variant of the `member` function.

Examples:

```code-example

(find-tail even? '(3 1 37 -8 -5 0 0)) => (-8 -5 0 0)
(find-tail even? '(3 1 37 -5)) => #f

;; MEMBER X LIS:
(find-tail (lambda (elt) (equal? x elt)) lis)
```

In the circular-list case, this procedure "rotates" the list.

`Find-tail` is essentially `drop-while`, where the sense of the predicate is inverted: `Find-tail` searches until it finds an element satisfying the predicate; `drop-while` searches until it finds an element that *doesn't* satisfy the predicate.

<span id="take-while"></span> ``` take-while `` pred clist -> list ```\
<span id="take-while!"></span> ``` take-while!`` pred clist -> list ```\
Returns the longest initial prefix of `clist` whose elements all satisfy the predicate `pred`.

`Take-while!` is the linear-update variant. It is allowed, but not required, to alter the argument list to produce the result.

```code-example

(take-while even? '(2 18 3 10 22 9)) => (2 18)
```

<span id="drop-while"></span> ``` drop-while`` pred clist -> list ```\
Drops the longest initial prefix of `clist` whose elements all satisfy the predicate `pred`, and returns the rest of the list.

```code-example

(drop-while even? '(2 18 3 10 22 9)) => (3 10 22 9)
```

The circular-list case may be viewed as "rotating" the list.

<span id="span"></span> ``` span  `` pred clist -> [list clist] ```\
<span id="span!"></span> ``` span! `` pred list  -> [list list] ```\
<span id="break"></span> ``` break `` pred clist -> [list clist] ```\
<span id="break!"></span> ``` break!`` pred list  -> [list list] ```\
`Span` splits the list into the longest initial prefix whose elements all satisfy `pred`, and the remaining tail. `Break` inverts the sense of the predicate: the tail commences with the first element of the input list that satisfies the predicate.

In other words: `span` finds the intial span of elements satisfying `pred`, and `break` breaks the list at the first element satisfying `pred`.

`Span` is equivalent to

```code-example

(values (take-while pred clist)
        (drop-while pred clist))
```

`Span!` and `break!` are the linear-update variants. They are allowed, but not required, to alter the argument list to produce the result.

```code-example

(span even? '(2 18 3 10 22 9)) =>
  (2 18)
  (3 10 22 9)

(break even? '(3 1 4 1 5 9)) =>
  (3 1)
  (4 1 5 9)
```

<span id="any"></span> ``` any`` pred clist ```<sub>`1`</sub>` clist`<sub>`2`</sub>` ... -> value`\
Applies the predicate across the lists, returning true if the predicate returns true on any application.

If there are `n` list arguments `clist`<sub>`1`</sub> ... `clist`<sub>`n`</sub>, then `pred` must be a procedure taking `n` arguments and returning a single value, interpreted as a boolean (that is, `#f` means false, and any other value means true).

`any` applies `pred` to the first elements of the `clist`<sub>`i`</sub> parameters. If this application returns a true value, `any` immediately returns that value. Otherwise, it iterates, applying `pred` to the second elements of the `clist`<sub>`i`</sub> parameters, then the third, and so forth. The iteration stops when a true value is produced or one of the lists runs out of values; in the latter case, `any` returns `#f`. The application of `pred` to the last element of the lists is a tail call.

Note the difference between `find` and `any` -- `find` returns the element that satisfied the predicate; `any` returns the true value that the predicate produced.

Like `every`, `any`'s name does not end with a question mark -- this is to indicate that it does not return a simple boolean (`#t` or `#f`), but a general value.

```code-example

(any integer? '(a 3 b 2.7))   => #t
(any integer? '(a 3.1 b 2.7)) => #f
(any < '(3 1 4 1 5)
       '(2 7 1 8 2)) => #t
```

<span id="every"></span> ``` every`` pred clist ```<sub>`1`</sub>` clist`<sub>`2`</sub>` ... -> value`\
Applies the predicate across the lists, returning true if the predicate returns true on every application.

If there are `n` list arguments `clist`<sub>`1`</sub> ... `clist`<sub>`n`</sub>, then `pred` must be a procedure taking `n` arguments and returning a single value, interpreted as a boolean (that is, `#f` means false, and any other value means true).

`every` applies `pred` to the first elements of the `clist`<sub>`i`</sub> parameters. If this application returns false, `every` immediately returns false. Otherwise, it iterates, applying `pred` to the second elements of the `clist`<sub>`i`</sub> parameters, then the third, and so forth. The iteration stops when a false value is produced or one of the lists runs out of values. In the latter case, `every` returns the true value produced by its final application of `pred`. The application of `pred` to the last element of the lists is a tail call.

If one of the `clist`<sub>`i`</sub> has no elements, `every` simply returns `#t`.

Like `any`, `every`'s name does not end with a question mark -- this is to indicate that it does not return a simple boolean (`#t` or `#f`), but a general value.

<span id="list-index"></span> ``` list-index`` pred clist ```<sub>`1`</sub>` clist`<sub>`2`</sub>` ... -> integer or false`\
Return the index of the leftmost element that satisfies `pred`.

If there are `n` list arguments `clist`<sub>`1`</sub> ... `clist`<sub>`n`</sub>, then `pred` must be a function taking `n` arguments and returning a single value, interpreted as a boolean (that is, `#f` means false, and any other value means true).

`list-index` applies `pred` to the first elements of the `clist`<sub>`i`</sub> parameters. If this application returns true, `list-index` immediately returns zero. Otherwise, it iterates, applying `pred` to the second elements of the `clist`<sub>`i`</sub> parameters, then the third, and so forth. When it finds a tuple of list elements that cause `pred` to return true, it stops and returns the zero-based index of that position in the lists.

The iteration stops when one of the lists runs out of values; in this case, `list-index` returns `#f`.

```code-example

(list-index even? '(3 1 4 1 5 9)) => 2
(list-index < '(3 1 4 1 5 9 2 5 6) '(2 7 1 8 2)) => 1
(list-index = '(3 1 4 1 5 9 2 5 6) '(2 7 1 8 2)) => #f
```

<span id="member"></span> ``` member`` x list [=] -> list ```\
<span id="memq"></span> ``` memq`` x list -> list ```\
<span id="memv"></span> ``` memv`` x list -> list ```\
\[<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span>+\] These procedures return the first sublist of `list` whose car is `x`, where the sublists of `list` are the non-empty lists returned by ``` (drop ``list`` ``i``) ``` for `i` less than the length of `list`. If `x` does not occur in `list`, then `#f` is returned. `memq` uses `eq?` to compare `x` with the elements of `list`, while `memv` uses `eqv?`, and `member` uses `equal?`.

```code-example

    (memq 'a '(a b c))          =>  (a b c)
    (memq 'b '(a b c))          =>  (b c)
    (memq 'a '(b c d))          =>  #f
    (memq (list 'a) '(b (a) c)) =>  #f
    (member (list 'a)
            '(b (a) c))         =>  ((a) c)
    (memq 101 '(100 101 102))   =>  *unspecified*
    (memv 101 '(100 101 102))   =>  (101 102)
```

`member` is extended from its <span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span> definition to allow the client to pass in an optional equality procedure `=` used to compare keys.

The comparison procedure is used to compare the elements `e`<sub>`i`</sub> of `list` to the key `x` in this way:

<div class="indent">

```  (= ``x`` ``e ```<sub>`i`</sub>`) ; list is (E1 ... En) `

</div>

That is, the first argument is always `x`, and the second argument is one of the list elements. Thus one can reliably find the first element of `list` that is greater than five with ``` (member 5 ``list`` <) ```

Note that fully general list searching may be performed with the `find-tail` and `find` procedures, *e.g.*

```code-example

(find-tail even? list) ; Find the first elt with an even key.
```

## Deletion

<span id="delete"></span> ``` delete  ``x list [=] -> list ```\
<span id="delete!"></span> ``` delete! ``x list [=] -> list ```\
`delete` uses the comparison procedure =, which defaults to `equal?`, to find all elements of `list` that are equal to `x`, and deletes them from `list`. The dynamic order in which the various applications of `=` are made is not specified.

The list is not disordered -- elements that appear in the result list occur in the same order as they occur in the argument list. The result may share a common tail with the argument list.

Note that fully general element deletion can be performed with the `remove` and `remove!` procedures, *e.g.*:

```code-example

;; Delete all the even elements from LIS:
(remove even? lis)
```

The comparison procedure is used in this way: ``` (= ``x`` ``e ```<sub>`i`</sub>`)`. That is, `x` is always the first argument, and a list element is always the second argument. The comparison procedure will be used to compare each element of `list` exactly once; the order in which it is applied to the various `e`<sub>`i`</sub> is not specified. Thus, one can reliably remove all the numbers greater than five from a list with `(delete 5 list <)`

`delete!` is the linear-update variant of `delete`. It is allowed, but not required, to alter the cons cells in its argument list to construct the result.

<span id="delete-duplicates"></span> ``` delete-duplicates  ``list [=] -> list ```\
<span id="delete-duplicates!"></span> ``` delete-duplicates! ``list [=] -> list ```\
`delete-duplicates` removes duplicate elements from the list argument. If there are multiple equal elements in the argument list, the result list only contains the first or leftmost of these elements in the result. The order of these surviving elements is the same as in the original list -- `delete-duplicates` does not disorder the list (hence it is useful for "cleaning up" association lists).

The `=` parameter is used to compare the elements of the list; it defaults to `equal?`. If `x` comes before `y` in `list`, then the comparison is performed ``` (= ``x`` ``y``) ```. The comparison procedure will be used to compare each pair of elements in `list` no more than once; the order in which it is applied to the various pairs is not specified.

Implementations of `delete-duplicates` are allowed to share common tails between argument and result lists -- for example, if the list argument contains only unique elements, it may simply return exactly this list.

Be aware that, in general, `delete-duplicates` runs in time O(n<sup>2</sup>) for `n`-element lists. Uniquifying long lists can be accomplished in O(n lg n) time by sorting the list to bring equal elements together, then using a linear-time algorithm to remove equal elements. Alternatively, one can use algorithms based on element-marking, with linear-time results.

`delete-duplicates!` is the linear-update variant of `delete-duplicates`; it is allowed, but not required, to alter the cons cells in its argument list to construct the result.

```code-example

(delete-duplicates '(a b a c a b c z)) => (a b c z)

;; Clean up an alist:
(delete-duplicates '((a . 3) (b . 7) (a . 9) (c . 1))
                   (lambda (x y) (eq? (car x) (car y))))
    => ((a . 3) (b . 7) (c . 1))
```

## Association lists

An "association list" (or "alist") is a list of pairs. The car of each pair contains a key value, and the cdr contains the associated data value. They can be used to construct simple look-up tables in Scheme. Note that association lists are probably inappropriate for performance-critical use on large data; in these cases, hash tables or some other alternative should be employed.

<span id="assoc"></span> ``` assoc`` key alist [=] -> pair or #f ```\
<span id="assq"></span> ``` assq`` key alist -> pair or #f ```\
<span id="assv"></span> ``` assv`` key alist -> pair or #f ```\
\[<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span>+\] `alist` must be an association list -- a list of pairs. These procedures find the first pair in `alist` whose car field is `key`, and returns that pair. If no pair in `alist` has `key` as its car, then `#f` is returned. `assq` uses `eq?` to compare `key` with the car fields of the pairs in `alist`, while `assv` uses `eqv?` and `assoc` uses `equal?`.

```code-example

(define e '((a 1) (b 2) (c 3)))
(assq 'a e)                            =>  (a 1)
(assq 'b e)                            =>  (b 2)
(assq 'd e)                            =>  #f
(assq (list 'a) '(((a)) ((b)) ((c))))  =>  #f
(assoc (list 'a) '(((a)) ((b)) ((c)))) =>  ((a))
(assq 5 '((2 3) (5 7) (11 13)))    =>  *unspecified*
(assv 5 '((2 3) (5 7) (11 13)))    =>  (5 7)
```

`assoc` is extended from its <span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span> definition to allow the client to pass in an optional equality procedure `=` used to compare keys.

The comparison procedure is used to compare the elements `e`<sub>`i`</sub> of `list` to the `key` parameter in this way:

<div class="indent">

```  (= ``key`` (car ``e ```<sub>`i`</sub>`)) ; list is (E1 ... En) `

</div>

That is, the first argument is always `key`, and the second argument is one of the list elements. Thus one can reliably find the first entry of `alist` whose key is greater than five with ``` (assoc 5 ``alist`` <) ```

Note that fully general alist searching may be performed with the `find-tail` and `find` procedures, *e.g.*

```code-example

;; Look up the first association in alist with an even key:
(find (lambda (a) (even? (car a))) alist)
```

<span id="alist-cons"></span> ``` alist-cons`` key datum alist -> alist ```

```
(lambda (key datum alist) (cons (cons key datum) alist))
```

Cons a new alist entry mapping `key` -> `datum` onto `alist`.

<span id="alist-copy"></span> ``` alist-copy`` alist -> alist ```\
Make a fresh copy of `alist`. This means copying each pair that forms an association as well as the spine of the list, *i.e.*

```
(lambda (a) (map (lambda (elt) (cons (car elt) (cdr elt))) a))
```

<span id="alist-delete"></span> ``` alist-delete  ``key alist [=] -> alist ```\
<span id="alist-delete!"></span> ``` alist-delete! ``key alist [=] -> alist ```\
`alist-delete` deletes all associations from `alist` with the given `key`, using key-comparison procedure =, which defaults to `equal?`. The dynamic order in which the various applications of `=` are made is not specified.

Return values may share common tails with the `alist` argument. The alist is not disordered -- elements that appear in the result alist occur in the same order as they occur in the argument alist.

The comparison procedure is used to compare the element keys `k`<sub>`i`</sub> of `alist`'s entries to the `key` parameter in this way: ``` (= ``key`` ``k ```<sub>`i`</sub>`)`. Thus, one can reliably remove all entries of `alist` whose key is greater than five with ``` (alist-delete 5 ``alist`` <) ```

`alist-delete!` is the linear-update variant of `alist-delete`. It is allowed, but not required, to alter cons cells from the `alist` parameter to construct the result.

## Set operations on lists

These procedures implement operations on sets represented as lists of elements. They all take an `=` argument used to compare elements of lists. This equality procedure is required to be consistent with `eq?`. That is, it must be the case that

<div class="indent">

``` (eq? ``x`` ``y``) ``` => ``` (``=`` ``x`` ``y``) ```.

</div>

Note that this implies, in turn, that two lists that are `eq?` are also set-equal by any legal comparison procedure. This allows for constant-time determination of set operations on `eq?` lists.

Be aware that these procedures typically run in time O(`n` * `m`) for `n`- and `m`-element list arguments. Performance-critical applications operating upon large sets will probably wish to use other data structures and algorithms.

<span id="lset<="></span> ``` lset<=`` = list ```<sub>`1`</sub>` ... -> boolean`\
Returns true iff every `list`<sub>`i`</sub> is a subset of `list`<sub>`i+1`</sub>, using `=` for the element-equality procedure. List `A` is a subset of list `B` if every element in `A` is equal to some element of `B`. When performing an element comparison, the `=` procedure's first argument is an element of `A`; its second, an element of `B`.

```code-example

(lset<= eq? '(a) '(a b a) '(a b c c)) => #t

(lset<= eq?) => #t             ; Trivial cases
(lset<= eq? '(a)) => #t
```

<span id="lset="></span> ``` lset=`` = list ```<sub>`1`</sub>` list`<sub>`2`</sub>` ... -> boolean`\
Returns true iff every `list`<sub>`i`</sub> is set-equal to `list`<sub>`i+1`</sub>, using `=` for the element-equality procedure. "Set-equal" simply means that `list`<sub>`i`</sub> is a subset of `list`<sub>`i+1`</sub>, and `list`<sub>`i+1`</sub> is a subset of `list`<sub>`i`</sub>. The `=` procedure's first argument is an element of `list`<sub>`i`</sub>; its second is an element of `list`<sub>`i+1`</sub>.

```code-example

(lset= eq? '(b e a) '(a e b) '(e e b a)) => #t

(lset= eq?) => #t               ; Trivial cases
(lset= eq? '(a)) => #t
```

<u>*Note added on 2020-06-02:* The reference (sample) [implementation](#ReferencesLinks) had a bug that reversed the arguments to `=`. The implementation has been corrected to match the text above.</u>

<span id="lset-adjoin"></span> ``` lset-adjoin`` = list elt ```<sub>`1`</sub>` ... -> list`\
Adds the `elt`<sub>`i`</sub> elements not already in the list parameter to the result list. The result shares a common tail with the list parameter. The new elements are added to the front of the list, but no guarantees are made about their order. The `=` parameter is an equality procedure used to determine if an `elt`<sub>`i`</sub> is already a member of `list`. Its first argument is an element of `list`; its second is one of the `elt`<sub>`i`</sub>.

The list parameter is always a suffix of the result -- even if the list parameter contains repeated elements, these are not reduced.

```code-example

(lset-adjoin eq? '(a b c d c e) 'a 'e 'i 'o 'u) => (u o i a b c d c e)
```

<span id="lset-union"></span> ``` lset-union`` = list ```<sub>`1`</sub>` ... -> list`\
Returns the union of the lists, using `=` for the element-equality procedure.

The union of lists `A` and `B` is constructed as follows:

- If `A` is the empty list, the answer is `B` (or a copy of `B`).
- Otherwise, the result is initialised to be list `A` (or a copy of `A`).
- Proceed through the elements of list `B` in a left-to-right order. If `b` is such an element of `B`, compare every element `r` of the current result list to `b`: ``` (= ``r`` ``b``) ```. If all comparisons fail, `b` is consed onto the front of the result.

However, there is no guarantee that = will be applied to every pair of arguments from `A` and `B`. In particular, if `A` is `eq`? to `B`, the operation may immediately terminate.

In the n-ary case, the two-argument list-union operation is simply folded across the argument lists.

```code-example

(lset-union eq? '(a b c d e) '(a e i o u)) =>
    (u o i a b c d e)

;; Repeated elements in LIST1 are preserved.
(lset-union eq? '(a a c) '(x a x)) => (x a a c)

;; Trivial cases
(lset-union eq?) => ()
(lset-union eq? '(a b c)) => (a b c)
```

<span id="lset-intersection"></span> ``` lset-intersection`` = list ```<sub>`1`</sub>` list`<sub>`2`</sub>` ... -> list`\
Returns the intersection of the lists, using `=` for the element-equality procedure.

The intersection of lists `A` and `B` is comprised of every element of `A` that is `=` to some element of `B`: ``` (``=`` ``a`` ``b``) ```, for `a` in `A`, and `b` in `B`. Note this implies that an element which appears in `B` and multiple times in list `A` will also appear multiple times in the result.

The order in which elements appear in the result is the same as they appear in `list`<sub>`1`</sub> -- that is, `lset-intersection` essentially filters `list`<sub>`1`</sub>, without disarranging element order. The result may share a common tail with `list`<sub>`1`</sub>.

In the n-ary case, the two-argument list-intersection operation is simply folded across the argument lists. However, the dynamic order in which the applications of `=` are made is not specified. The procedure may check an element of `list`<sub>`1`</sub> for membership in every other list before proceeding to consider the next element of `list`<sub>`1`</sub>, or it may completely intersect `list`<sub>`1`</sub> and `list`<sub>`2`</sub> before proceeding to `list`<sub>`3`</sub>, or it may go about its work in some third order.

```code-example

(lset-intersection eq? '(a b c d e) '(a e i o u)) => (a e)

;; Repeated elements in LIST1 are preserved.
(lset-intersection eq? '(a x y a) '(x a x z)) => '(a x a)

(lset-intersection eq? '(a b c)) => (a b c)     ; Trivial case
```

<span id="lset-difference"></span> ``` lset-difference`` = list ```<sub>`1`</sub>` list`<sub>`2`</sub>` ... -> list`\
Returns the difference of the lists, using `=` for the element-equality procedure -- all the elements of `list`<sub>`1`</sub> that are not `=` to any element from one of the other `list`<sub>`i`</sub> parameters.

The `=` procedure's first argument is always an element of `list`<sub>`1`</sub>; its second is an element of one of the other `list`<sub>`i`</sub>. Elements that are repeated multiple times in the `list`<sub>`1`</sub> parameter will occur multiple times in the result. The order in which elements appear in the result is the same as they appear in `list`<sub>`1`</sub> -- that is, `lset-difference` essentially filters `list`<sub>`1`</sub>, without disarranging element order. The result may share a common tail with `list`<sub>`1`</sub>. The dynamic order in which the applications of `=` are made is not specified. The procedure may check an element of `list`<sub>`1`</sub> for membership in every other list before proceeding to consider the next element of `list`<sub>`1`</sub>, or it may completely compute the difference of `list`<sub>`1`</sub> and `list`<sub>`2`</sub> before proceeding to `list`<sub>`3`</sub>, or it may go about its work in some third order.

```code-example

(lset-difference eq? '(a b c d e) '(a e i o u)) => (b c d)

(lset-difference eq? '(a b c)) => (a b c) ; Trivial case
```

<span id="lset-xor"></span> ``` lset-xor`` = list ```<sub>`1`</sub>` ... -> list`\
Returns the exclusive-or of the sets, using `=` for the element-equality procedure. If there are exactly two lists, this is all the elements that appear in exactly one of the two lists. The operation is associative, and thus extends to the n-ary case -- the elements that appear in an odd number of the lists. The result may share a common tail with any of the `list`<sub>`i`</sub> parameters.

More precisely, for two lists `A` and `B`, `A` xor `B` is a list of

- every element `a` of `A` such that there is no element `b` of `B` such that ``` (``=`` ``a`` ``b``) ```, and
- every element `b` of `B` such that there is no element `a` of `A` such that ``` (``=`` ``b`` ``a``) ```.

However, an implementation is allowed to assume that `=` is symmetric -- that is, that

<div class="indent">

``` (``=`` ``a`` ``b``) ``` => ``` (``=`` ``b`` ``a``) ```.

</div>

This means, for example, that if a comparison ``` (``=`` ``a`` ``b``) ``` produces true for some `a` in `A` and `b` in `B`, both `a` and `b` may be removed from inclusion in the result.

In the n-ary case, the binary-xor operation is simply folded across the lists.

```code-example

(lset-xor eq? '(a b c d e) '(a e i o u)) => (d c b i o u)

;; Trivial cases.
(lset-xor eq?) => ()
(lset-xor eq? '(a b c d e)) => (a b c d e)
```

<span id="lset-diff+intersection"></span> ``` lset-diff+intersection`` = list ```<sub>`1`</sub>` list`<sub>`2`</sub>` ... -> [list list]`\
Returns two values -- the difference and the intersection of the lists. Is equivalent to

```code-example

(values (lset-difference = list1 list2 ...)
        (lset-intersection = list1
                             (lset-union = list2 ...)))
```

but can be implemented more efficiently.

The `=` procedure's first argument is an element of `list`<sub>`1`</sub>; its second is an element of one of the other `list`<sub>`i`</sub>.

Either of the answer lists may share a common tail with `list`<sub>`1`</sub>. This operation essentially partitions `list`<sub>`1`</sub>.

<span id="lset-union!"></span> ``` lset-union!             ``= list ```<sub>`1`</sub>` ... -> list`\
<span id="lset-intersection!"></span> ``` lset-intersection!      ``= list ```<sub>`1`</sub>` list`<sub>`2`</sub>` ... -> list`\
<span id="lset-difference!"></span> ``` lset-difference!        ``= list ```<sub>`1`</sub>` list`<sub>`2`</sub>` ... -> list`\
<span id="lset-xor!"></span> ``` lset-xor!               ``= list ```<sub>`1`</sub>` ... -> list`\
<span id="lset-diff+intersection!"></span> ``` lset-diff+intersection! ``= list ```<sub>`1`</sub>` list`<sub>`2`</sub>` ... -> [list list]`\
These are linear-update variants. They are allowed, but not required, to use the cons cells in their first list parameter to construct their answer. `lset-union!` is permitted to recycle cons cells from *any* of its list arguments.

## Primitive side-effects

These two procedures are the primitive, <span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span> side-effect operations on pairs.

<span id="set-car!"></span> ``` set-car!`` pair object -> unspecified ```\
<span id="set-cdr!"></span> ``` set-cdr!`` pair object -> unspecified ```\
\[<span class="abbr" title="Revised^5 Report on Scheme">[R5RS](#R5RS)</span>\] These procedures store `object` in the car and cdr field of `pair`, respectively. The value returned is unspecified.

```code-example

(define (f) (list 'not-a-constant-list))
(define (g) '(constant-list))
(set-car! (f) 3) =>  *unspecified*
(set-car! (g) 3) =>  *error*
```

## Acknowledgements

The design of this library benefited greatly from the feedback provided during the <span class="abbr" title="Scheme Request for Implementation">SRFI</span> discussion phase. Among those contributing thoughtful commentary and suggestions, both on the mailing list and by private discussion, were Mike Ashley, Darius Bacon, Alan Bawden, Phil Bewig, Jim Blandy, Dan Bornstein, Per Bothner, Anthony Carrico, Doug Currie, Kent Dybvig, Sergei Egorov, Doug Evans, Marc Feeley, Matthias Felleisen, Will Fitzgerald, Matthew Flatt, Dan Friedman, Lars Thomas Hansen, Brian Harvey, Erik Hilsdale, Wolfgang Hukriede, Richard Kelsey, Donovan Kolbly, Shriram Krishnamurthi, Dave Mason, Jussi Piitulainen, David Pokorny, Duncan Smith, Mike Sperber, Maciej Stachowiak, Harvey J. Stein, John David Stone, and Joerg F. Wittenberger. I am grateful to them for their assistance.

I am also grateful the authors, implementors and documentors of all the systems mentioned in the rationale. Aubrey Jaffer and Kent Pitman should be noted for their work in producing Web-accessible versions of the R5RS and [Common Lisp](#CommonLisp) spec, which was a tremendous aid.

This is not to imply that these individuals necessarily endorse the final results, of course.

## References & links

This document, in HTML:\
[https://srfi.schemers.org/srfi-1/srfi-1.html](srfi-1.html)

Source code for the reference implementation:\
[https://srfi.schemers.org/srfi-1/srfi-1-reference.scm](srfi-1-reference.scm)

Archive of SRFI-1 discussion-list email:\
<https://srfi-email.schemers.org/srfi-1>

SRFI web site:\
<https://srfi.schemers.org/>

<!-- -->

**<span id="CommonLisp">[CommonLisp]</span>**\
*Common Lisp: the Language*\
Guy L. Steele Jr. (editor).\
Digital Press, Maynard, Mass., second edition 1990.\
([Wikipedia entry](https://en.wikipedia.org/wiki/Common_Lisp_the_Language))

The Common Lisp "HyperSpec," produced by Kent Pitman, is essentially the ANSI spec for Common Lisp: <http://www.lispworks.com/documentation/HyperSpec/Front/index.htm>

**<span id="R5RS">[R5RS]</span>**\
Revised<sup>5</sup> report on the algorithmic language Scheme.\
R. Kelsey, W. Clinger, J. Rees (editors).\
Higher-Order and Symbolic Computation, Vol. 11, No. 1, September, 1998.\
and ACM SIGPLAN Notices, Vol. 33, No. 9, October, 1998.\
Available at <http://www.schemers.org/Documents/Standards/>.

## Copyright

Certain portions of this document -- the specific, marked segments of text describing the R5RS procedures -- were adapted with permission from the R5RS report.

All other text is copyright (C) Olin Shivers (1998, 1999). All Rights Reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

______________________________________________________________________

Editor: [Michael Sperber](mailto:srfi-editors+at+srfi+dot+schemers+dot+org)
