<!-- SPDX-License-Identifier: MIT -->

<!-- SPDX-FileCopyrightText: SRFI document authors -->

# Title

SRFI Libraries

# Author

David Van Horn

# Status

This SRFI is currently in *final* status. Here is
[an explanation](https://srfi.schemers.org/srfi-process.html) of each status
that a SRFI can hold. To provide input on this SRFI, please send email to
[`srfi-97@`<span class="antispam">`nospam`</span>`srfi.schemers.org`](mailto:srfi+minus+97+at+srfi+dotschemers+dot+org).
To subscribe to the list, follow
[these instructions](https://srfi.schemers.org/srfi-list-subscribe.html). You
can access previous messages via the mailing list
[archive](https://srfi-email.schemers.org/srfi-97).

- Received: [2008-03-25](https://srfi.schemers.org/srfi-97/srfi-97-1.1.html)
- Draft: 2008-03-25--2008-05-24
- Revised: [2008-07-22](https://srfi.schemers.org/srfi-97/srfi-97-1.2.html)
- Draft extended: 2008-07-22--2008-08-22
- Revised: [2008-12-22](https://srfi.schemers.org/srfi-97/srfi-97-1.3.html)
- Post-finalization note (added 2019-12-29):\
  The standardized library names from this SRFI, as well as the library names of
  newer SRFIs, are now kept in the `library-name` attribute of the SRFI database
  file at
  <a href="https://github.com/scheme-requests-for-implementation/srfi-common/blob/master/admin/srfi-data.scm" class="eponymous">https://github.com/scheme-requests-for-implementation/srfi-common/blob/master/admin/srfi-data.scm</a>.

# Table of contents

- [Abstract](#abstract)
- [Rationale](#rationale)
- [Specification](#specification)
- - [Referencing SRFI Libraries](#referencing)
  - [Naming convention](#naming)
  - [Included SRFIs](#included)
  - [Omitted SRFIs](#omitted)
  - [Withdrawn SRFIs](#withdrawn)
  - [Future SRFIs](#future)
  - [Existing SRFIs and R<sup>6</sup>RS](#existing)
  - [Relation to SRFIs 0 and 7](#relation)
- [Implementation](#implementation)
- [Acknowledgments](#acknowledgements)
- [References](#references)
- [Copyright](#copyright)

# <span id="abstract">Abstract</span>

Over the past ten years, numerous libraries have been specified via the Scheme
Requests for Implementation process. Yet until the recent ratification of the
Revised<sup>6</sup> Report on the Algorithmic Language Scheme, there has been no
standardized way of distributing or relying upon library code. Now that such a
library system exists, there is a real need to organize these existing SRFI
libraries so that they can be portably referenced.

This SRFI is designed to facilitate the writing and distribution of code that
relies on SRFI libraries. It identifies a subset of existing SRFIs that specify
features amenable to provision (and possibly implementation) as libraries (SRFI
Libraries) and proposes a naming convention for this subset so that these
libraries may be referred to by name or by number.

# <span id="rationale">Rationale</span>

With the advent of R<sup>6</sup>RS, it has become possible to write and
distribute portable Scheme code as libraries. However, there is no agreed upon
way to refer to SRFI libraries, leaving implementors to create their own
conventions thus thwarting portability of code which relies on SRFIs. So there
is an immediate and obvious need for standardized SRFI library names.

The naming convention proposed in this document enjoys the following properties:

1. it fully conforms with the R<sup>6</sup>RS library reference syntax,
1. it is consistent with the naming convention employed by R<sup>6</sup>RS
   Standard Libraries,
1. it is based on SRFI numbers so that names for libraries can be chosen simply
   and without conflict,
1. it allows (optional) mnemonic based references for readability and
   sub-libraries,
1. it ensures uniqueness of names over time,
1. it avoids the need for a naming authority,
1. and it represents a consensus among several Scheme implementors at the time.

# <span id="specification">Specification</span>

This specification includes the following: a library referencing scheme for all
past and future SRFI libraries, a naming convention for selecting library names,
and enumeration of library names selected for all currently finalized SRFIs that
specify libraries.

Although R<sup>6</sup>RS's notion of a library is the one used here, this SRFI
attempts to minimize assumptions made about a Scheme system's conformance to
R<sup>6</sup>RS so that systems may support SRFI Libraries without needing to
support all of the R<sup>6</sup>RS library system. In particular, the `for`
clause is not needed for any existing SRFI Library, and versioning information
is not used. This is important for systems such as ERR<sup>5</sup>RS, which do
not support these features.

## <span id="referencing">Referencing SRFI Libraries</span>

The purpose of this SRFI is to name SRFI libraries in a consistent and uniform
manner, both in the case of existing SRFIs and in the case of SRFIs yet to be
written.

A SRFI library reference consists of two required components:

- the identifier `srfi`,
- and the SRFI number, represented as the identifier `:`*`n`*.

*Discussion:* Several current Scheme implementations supporting SRFIs use names
consisting of `srfi` and the relevant SRFI number. For example, Larceny, PLT
Scheme, Scheme 48 all do. Use of these components also has precedents in SRFIs 0
and 7.

*Discussion:* Since this SRFI is *only concerned* with the naming of SRFI
libraries, the `srfi` prefix is included to clearly distinguish it as a SRFI
reference, and the number component is included to disambiguate among SRFIs,
while allowing for simple naming without clashes or authorities. During the
discussion period, it was made clear some would prefer libraries not be
distinguished as SRFIs and that names be strictly mnemonic. Such a requirement
broadens the scope of this proposal from a convention for SRFI libraries to the
more general case of Scheme libraries and poses a much more difficult problem to
solve. Instead, the particular problem is solved in such a way as to hopefully
not interfere with future more general naming conventions.

Additionally, a SRFI library reference consists of one or more optional mnemonic
components following the naming convention described below.

A SRFI library reference has the following form,

> `(srfi :`*`<uinteger 10>`*` `*`<identifier>`*` ...)`,

where *`<identifier>`* is one of the included SRFI library names defined below,
and *`<uinteger 10>`* is a SRFI number. The non-terminals `<uinteger 10>` and
`<identifier>` are defined as given in R<sup>6</sup>RS
[Chapter 4, Lexical syntax](http://www.r6rs.org/final/html/r6rs/r6rs-Z-H-7.html#node_chap_4).

*Discussion:* The colon (`:`) prefix is used in order to make the SRFI number
component an identifier, as required by R<sup>6</sup>RS. Several Scheme
implementors expressed the importance of R<sup>6</sup>RS conformance and
supported the colon prefix as a reasonable, if somewhat arbitrary, way to render
the number as an identifier. The issue of mapping library references to file
paths is left completely unspecified by this SRFI and R<sup>6</sup>RS.

A SRFI Library can be referenced by number, as in

> `(srfi :1)`,

or equivalently using the library's name, as in

> `(srfi :1 lists)`.

*Discussion:* Even though the latter uses a library name, the SRFI number must
still be supplied. This is done to ensure *fairness* and *uniqueness*—a SRFI
should not be able to prevent other SRFIs from using the same name, but at the
same time, SRFI library references should remain unambiguous.

*Discussion:* Since the number-only naming scheme ensures both *uniqueness* and
*fairness*, the named-library scheme is redundant, but it is included to make
library imports more readable. Although the same could be achieved via a
comment, comments are not checked. The named-library scheme can thus be used to
increase the likelihood that the correct library is imported.

The remaining identifier subforms are used to name sublibraries within a SRFI
Library. For example, SRFI 41, Streams, defines `primitive` and `derived`
libraries within the `streams` library. These can be referenced as

> `(srfi :41 streams primitive)`,\
> `(srfi :41 streams derived)`.

## <span id="naming">Naming convention</span>

Mnemonic library names are chosen according to the following conventions:
Libraries that define datatypes are typically pluralized (e.g., `arrays`,
`basic-string-ports`). Libraries that provide new expression forms are named by
the name of their new form (e.g., `let-values`, `rec`, `and-let*`). Libraries
that define a single procedure (or that have a primary procedure) are given the
name of the procedure (e.g., `error`, `cat`). Libraries that provide a large API
of syntaxes and values are named in a descriptive manner derived from their
title (e.g., `lightweight-testing`, `real-time-multithreading`). This naming
convention is consistent with the names chosen in the R<sup>6</sup>RS Standard
Libraries.

*Discussion:* Some authors specified names that should be used for libraries.
These names are not used here. Instead, a consistent naming scheme is used that
happens to differ from the authors' originally chosen names.

*Discussion:* There is opportunity for grouping related SRFIs together. For
example, SRFI 28, Basic Format Strings, and SRFI 48, Intermediate Format
Strings, could be grouped into a common `format` library with `simple` and
`intermediate` components. This has been avoided, preferring instead to follow a
*one SRFI, one (top-level) library* convention. Although within a single SRFI,
several sub-libraries can be defined, thus achieving grouping. This simplifies
the naming convention and prevents the need for a naming authority which decides
what shall and shall not be grouped together. Instead, grouping must be achieved
by the SRFI process, as it should.

## <span id="included">Included SRFIs</span>

The criterion for inclusion in the set of SRFI Libraries is that the finalized
SRFI only specify a set of bindings which can be provided as a library. SRFI
Libraries need not be implementable as an R<sup>6</sup>RS library, but they must
specify an interface which could be used *as if it were*. This means, for
example, that lexical syntax extensions cannot be a part of a SRFI Library.
SRFIs that specify global semantic changes to Scheme also cannot be SRFI
Libraries. For example, a Lazy Scheme SRFI or a SRFI that fixed order of
evaluation in procedure application could not be a SRFI Library because these
features cannot be provided as a set of bindings.

Some SRFIs specify alternative semantics to standard Scheme bindings. In some
cases, such as SRFI 5's `let`, it's clear that making the alternative binding
for `let` available as a library binding is desirable. Authors that wish to use
SRFI 5's `let`, rather than R<sup>6</sup>RS's `let`, simply import the SRFI 5
binding and exclude the R<sup>6</sup>RS binding for `let` (or rename to avoid
the clash).

Other SRFIs, however, define alternative bindings that are intended to be used
throughout a Scheme system. For example, SRFI 63's `equal?` and most of SRFI 70,
Numbers, are defined like this. But if the author intends for these bindings to
*replace* the standard bindings, then there is no way of making this feature
available as a library, so the SRFI cannot be a SRFI Library.

The approach taken in this SRFI is that a SRFI is excluded as a SRFI Library if
it explicitly states the binding is to replace the standard one. For example,
SRFI 70, Numbers, is excluded because it explicitly revises the text of
R<sup>5</sup>RS, thus intending to make a global semantic change to the language
which cannot be provided as a library. On the other hand, SRFI 63, Homogeneous
and Heterogeneous Arrays, is included and provides a binding for `equal?`
because the SRFI 63 document does not explicitly state this should replace the
standard `equal?` binding.

The following SRFI library names are defined:

| SRFI | Library names | Title | |----|----|----| | 1 | lists | List Library | |
2 | and-let\* | AND-LET\*: an AND with local bindings, a guarded LET\* special
form | | 5 | let | A compatible let form with signatures and rest arguments | |
6 | basic-string-ports | Basic String Ports | | 8 | receive | `receive`: Binding
to multiple values | | 9 | records | Defining Record Types | | 11 | let-values |
Syntax for receiving multiple values | | 13 | strings | String Libraries | | 14
| char-sets | Character-Set Library | | 16 | case-lambda | Syntax for procedures
of variable arity | | 17 | generalized-set! | Generalized set! | | 18 |
multithreading | Multithreading support | | 19 | time | Time Data Types and
Procedures | | 21 | real-time-multithreading | Real-time multithreading support
| | 23 | error | Error reporting mechanism | | 25 | multi-dimensional-arrays |
Multi-dimensional Array Primitives | | 26 | cut | Notation for Specializing
Parameters without Currying | | 27 | random-bits | Sources of Random Bits | | 28
| basic-format-strings | Basic Format Strings | | 29 | localization |
Localization | | 31 | rec | A special form for recursive evaluation | | 38 |
with-shared-structure | External Representation for Data With Shared Structure |
| 39 | parameters | Parameter objects | | 41 | streams, streams primitive,
streams derived | Streams | | 42 | eager-comprehensions | Eager Comprehensions |
| 43 | vectors | Vector Library | | 44 | collections | Collections | | 45 | lazy
| Primitives for expressing iterative lazy algorithms | | 46 | syntax-rules |
Basic Syntax-rules Extensions | | 47 | arrays | Array | | 48 |
intermediate-format-strings | Intermediate Format Strings | | 51 | rest-values |
Handling rest list | | 54 | cat | Formatting | | 57 | records | Records | | 59 |
vicinities | Vicinity | | 60 | integer-bits | Integers as Bits | | 61 | cond | A
more general `cond` clause | | 63 | arrays | Homogeneous and Heterogeneous
Arrays | | 64 | testing | A Scheme API for test suites | | 66 | octet-vectors |
Octet Vectors | | 67 | compare-procedures | Compare Procedures | | 69 |
basic-hash-tables | Basic hash tables | | 71 | let | `LET`-syntax for multiple
values | | 74 | blobs | Octet-Addressed Binary Blocks | | 78 |
lightweight-testing | Lightweight testing | | 86 | mu-and-nu | MU and NU
simulating VALUES & CALL-WITH-VALUES, and their related LET-syntax | | 87 | case
| => in case clauses | | 95 | sorting-and-merging | Sorting and Merging |

For the purposes of R<sup>6</sup>RS conforming systems, export levels are
assumed to be 0 for all exported bindings of all SRFIs, *except* SRFI-46: Basic
syntax-rules extensions, which should export `syntax-rules` for level 1. This
allows all existing SRFI Libraries to be portably imported and used without use
of the R<sup>6</sup>RS `for` clause.

## <span id="omitted">Omitted SRFIs</span>

SRFIs are not libraries, they are requests for *features*. Thus, several SRFIs
specify features which cannot be provided as a library and those SRFIs are
intentionally omitted here. For example, SRFIs which specify extensions to
concrete syntax or extensions to the semantics of top-level programs cannot be
provided as libraries and are therefore omitted from this SRFI. The following
table lists omitted (finalized) SRFIs and the reason for their omission.

| SRFI | Title | Reason for omission | |----|----|----| | 0 | Feature-based
conditional expansion construct | Modifies semantics of top-level programs. | |
4 | Homogeneous numeric vector datatypes | Modifies lexical syntax. | | 7 |
Feature-based program configuration language | Defines a configuration language
distinct from Scheme. | | 10 | `#,` external form | Modifies lexical syntax. | |
22 | Running Scheme Scripts on Unix | Does not specify a library. | | 30 |
Nested Multi-line Comments | Modifies lexical syntax (subsumed by
R<sup>6</sup>RS). | | 34 | Exception Handling for Programs | Subsumed by
R<sup>6</sup>RS. | | 36 | I/O Conditions | Subsumed by R<sup>6</sup>RS. | | 37 |
args-fold: a program argument processor | Does not specify a library. | | 40 | A
Library of Streams | Deprecated by SRFI 41, Streams. | | 49 |
Indentation-sensitive syntax | Modifies lexical syntax. | | 55 |
`require-extension` | Modifies semantics of top-level programs. | | 58 | Array
Notation | Modifies lexical syntax. | | 62 | S-expression comments | Modifies
lexical syntax (subsumed by R<sup>6</sup>RS). | | 70 | Numbers | Modifies
standard semantics for number system. | | 72 | Hygienic macros | Modifies macro
expansion semantics. | | 88 | Keyword objects | Modifies lexical syntax. | | 89
| Optional positional and named parameters | Modifies syntax and semantics of
application, which cannot be provided by a library. Dependent on lexical syntax
modification (SRFI 88). | | 90 | Extensible hash table constructor | Dependent
on lexical syntax modification (SRFI 88). | | 94 | Type-Restricted Numerical
Functions | Dependent on number system modification (SRFI 70). |

## <span id="withdrawn">Withdrawn SRFIs</span>

Withdrawn SRFIs are considered outside the scope of this proposal, so their
names are not considered.

## <span id="future">Future SRFIs</span>

Authors of future SRFIs that specify libraries may choose names as they please,
but they are encouraged to use library names following the naming convention of
this SRFI. If names are chosen that are not compatible with the referencing
scheme given here, authors should specify alternative names that can be used to
refer to the library consistent with this specification.

SRFI 41, Streams, for example, specifies that its libraries are named by
`(streams)`, `(streams primitive)`, and `(streams derived)`, but according to
this SRFI, they must also be named with the prefix `(srfi :41 *)`.

## <span id="existing">Issues with existing SRFIs and R<sup>6</sup>RS</span>

There are many issues involved in the use and implementation of some of the
existing SRFIs in an R<sup>6</sup>RS or related system. This SRFI resolves none
of them.

See the discussion archive and previous revisions of this document for a list of
some of these issues.

## <span id="relation">Relation to SRFIs 0 and 7</span>

Both SRFI 0, Feature-based conditional expansion construct, and SRFI 7,
Feature-based program configuration language, use *feature identifiers* of the
form `srfi-N`, with the expectation "that features will eventually be assigned
meaningful names (aliases) by the SRFI editors to make reading and writing code
less tedious than when using `srfi-N` feature identifiers."

It is recommended that implementations which support SRFIs 0 or 7 use the SRFI
names defined here as aliases. SRFI feature identifiers are constructed by

1. interpolating library references with a hyphen (`-`),
1. interpreting the SRFI number component of a library reference "`:`*`n`*" as
   "*`n`*".

For example, the feature identifier for SRFI 1, List Library, is `srfi-1`, or
equivalently, `srfi-1-lists`. Feature identifiers for sub-libraries are
constructed in the same way, so for example the feature identifier for the
streams primitive library is `srfi-41-streams-primitive`.

# <span id="implementation">Implementation</span>

There is no reference implementation as this SRFI only specifies a naming
convention.

# <span id="acknowledgements">Acknowledgments</span>

For discussions, I thank Will Clinger, Aziz Ghuloum, Dave Herman, Olin Shivers,
Andre van Tonder, and my fellow SRFI editors. I also thank all those who
participated during the draft period of this SRFI.

# <span id="references">References</span>

Revised<sup>6</sup> Report on the Algorithmic Language Scheme\
Michael Sperber, *et al.* (Editors)\
<http://www.r6rs.org/>

A proposal for an Extended R<sup>5</sup>RS Scheme\
William Clinger, *et al.*\
<https://web.archive.org/web/20080529074808/http://scheme-punks.cyber-rush.org/wiki/index.php?title=ERR5RS:Charter>

Ikarus Scheme\
<https://web.archive.org/web/20090311103900/http://www.cs.indiana.edu/~aghuloum/ikarus/>

Larceny\
<https://www.larcenists.org/>

PLT Scheme\
<https://plt-scheme.org/>

Scheme 48\
<https://www.s48.org/>

# <span id="copyright">Copyright</span>

Copyright (C) David Van Horn 2008. All Rights Reserved.

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

Editor: [Donovan Kolbly](mailto:srfi+minus+editors+at+srfi+dot+schemers+dot+org)
