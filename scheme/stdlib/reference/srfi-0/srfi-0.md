<!-- SPDX-License-Identifier: MIT -->

<!-- SPDX-FileCopyrightText: SRFI document authors -->

# Title

Feature-based conditional expansion construct

# Author

Marc Feeley

# Status

This SRFI is currently in *final* status. Here is
[an explanation](https://srfi.schemers.org/srfi-process.html) of each status
that a SRFI can hold. To provide input on this SRFI, please send email to
[`srfi-0@`<span class="antispam">`nospam`</span>`srfi.schemers.org`](mailto:srfi+minus+0+at+srfi+dotschemers+dot+org).
To subscribe to the list, follow
[these instructions](https://srfi.schemers.org/srfi-list-subscribe.html). You
can access previous messages via the mailing list
[archive](https://srfi-email.schemers.org/srfi-0).

- Received: 1998-11-17
- Draft: 1999-01-05--1999-04-04
- Revised: 1999-04-20
- Final: 1999-05-07

# Abstract

It is desirable that programs which depend on additions to standard Scheme name
those additions. SRFIs provide the specifications of these additions
("features"), and SRFI 0 provides the means to actually check that these
features are present in the Scheme system by means of the `cond-expand`
construct. It is anticipated that there will be two main classes of features:

- sets of value and syntax bindings
- reader syntax extensions

("Reader syntax" refers to aspects of the syntax described by the grammars in
the Scheme reports.)

The former class of features will probably include most SRFIs, exemplified by
the list library specified in [SRFI 1](../srfi-1/). The latter class includes
Unicode source code support and different kinds of parentheses.

Control over the presence of individual features will vary over different Scheme
systems. A given feature may be absent or provided by default in some Scheme
systems and in others some mechanism (such as an "import" clause in the code or
a program configuration file, a command line option, a dependency declaration in
a module definition, etc.) will be required for the feature to be present in the
system.

Moreover, in some systems a given feature may be in effect throughout the entire
program if it is in effect anywhere at all. Other systems may have more precise
mechanisms to control the scope of a feature (this might be the case for example
when a module system is supported). In general it is thus possible that a
feature is in effect in some parts of the program and not in others. This allows
conflicting SRFIs to be present in a given program as long as their scope do not
intersect.

SRFI 0 does not prescribe a particular mechanism for controlling the presence of
a feature as it is our opinion that this should be the role of a module system.
We expect that future module system SRFIs will need to extend the semantics of
SRFI 0 for their purposes, for example by defining feature scoping rules or by
generalizing the feature testing construct.

# Rationale

Most Scheme systems extend the language with some additional features (such as
the ability to manipulate Unicode characters and strings, to do binary I/O, or
to handle asynchronous interrupts). Such features may be provided in a variety
of ways including new procedures, new program syntax, and extended behavior of
standard procedures and special-forms. A particular functionality may exist in
several or even most Scheme systems but its API may be different (use of a
procedure or special-form, name, number of parameters, etc). To write code that
will run on several Scheme systems, it is useful to have a common construct to
enable or disable sections of code based on the existence or absence of a
feature in the Scheme system being used. For example, the construct could be
used to check if a particular binary I/O procedure is present, and if not, load
a portable library which implements that procedure.

Features are identified by *feature identifiers*. In order for the semantics of
this construct to be well-defined, the feature identifier must of course refer
to a feature which has a well-defined meaning. There is thus a need for a
registry, independent of this SRFI, to keep track of the formal specification
associated with each valid feature-identifier. The SRFI registry is used for
this purpose. It is expected that features will eventually be assigned
meaningful names (aliases) by the SRFI editors to make reading and writing code
less tedious than when using "srfi-N" feature identifiers.

Another issue is the binding time of this construct (i.e. the moment when it
operates). It is important that the binding time be early so that a compiler can
discard the sections of code that are not needed, and perform better static
analyses. Expressing this construct through a procedure returning a boolean,
such as `(feature-implemented? 'srfi-5)`, would not achieve this goal, as its
binding time is too late (i.e. program run-time). A read-time construct, such as
Common Lisp's `#+` read-macro, is very early but would require non-trivial
changes to the reader of existing Scheme systems and the syntax is not
particularly human friendly. Instead, a macro-expansion-time construct is used.

The construct is restricted to the top level of a program in order to simplify
its implementation and to force a more disciplined use of the construct (to
facilitate reading and understanding programs) and to avoid (some)
misunderstandings related to the scope of features. These restrictions can of
course be lifted by some Scheme systems or by other SRFIs (in particular module
system SRFIs).

# Specification

Syntax:

```
<command or definition>
    --> <command>
      | <definition>
      | <syntax definition>
      | (begin <command or definition>+)
      | <conditional expansion form>
<conditional expansion form>
    --> (cond-expand <cond-expand clause>+)
      | (cond-expand <cond-expand clause>* (else <command or definition>*))
<cond-expand clause>
    --> (<feature requirement> <command or definition>*)
<feature requirement>
    --> <feature identifier>
      | (and <feature requirement>*)
      | (or <feature requirement>*)
      | (not <feature requirement>)
<feature identifier>
    --> a symbol which is the name or alias of a SRFI
```

The `cond-expand` form tests for the existence of features at macro-expansion
time. It either expands into the body of one of its clauses or signals an error
during syntactic processing. `cond-expand` expands into the body of the first
clause whose feature requirement is currently satisfied (the `else` clause, if
present, is selected if none of the previous clauses is selected).

A feature requirement has an obvious interpretation as a logical formula, where
the `<feature identifier>` variables have meaning TRUE if the feature
corresponding to the feature identifier, as specified in the SRFI registry, is
in effect at the location of the `cond-expand` form, and FALSE otherwise. A
feature requirement is satisfied if its formula is true under this
interpretation.

Examples:

```
  (cond-expand
    ((and srfi-1 srfi-10)
     (write 1))
    ((or srfi-1 srfi-10)
     (write 2))
    (else))

  (cond-expand
    (command-line
     (define (program-name) (car (argv)))))
```

The second example assumes that `command-line` is an alias for some feature
which gives access to command line arguments. Note that an error will be
signaled at macro-expansion time if this feature is not present.

# Implementation

The simplest implementation of SRFI 0 assumes that all existent features are
built-in (here we assume `srfi-0` and `srfi-5` are present):

```
(define-syntax cond-expand
  (syntax-rules (and or not else srfi-0 srfi-5)
    ((cond-expand) (syntax-error "Unfulfilled cond-expand"))
    ((cond-expand (else body ...))
     (begin body ...))
    ((cond-expand ((and) body ...) more-clauses ...)
     (begin body ...))
    ((cond-expand ((and req1 req2 ...) body ...) more-clauses ...)
     (cond-expand
       (req1
         (cond-expand
           ((and req2 ...) body ...)
           more-clauses ...))
       more-clauses ...))
    ((cond-expand ((or) body ...) more-clauses ...)
     (cond-expand more-clauses ...))
    ((cond-expand ((or req1 req2 ...) body ...) more-clauses ...)
     (cond-expand
       (req1
        (begin body ...))
       (else
        (cond-expand
           ((or req2 ...) body ...)
           more-clauses ...))))
    ((cond-expand ((not req) body ...) more-clauses ...)
     (cond-expand
       (req
         (cond-expand more-clauses ...))
       (else body ...)))
    ((cond-expand (srfi-0 body ...) more-clauses ...)
       (begin body ...))
    ((cond-expand (srfi-5 body ...) more-clauses ...)
       (begin body ...))
    ((cond-expand (feature-id body ...) more-clauses ...)
       (cond-expand more-clauses ...))))
```

Note that the specification requires a macro-expansion time error to be
signalled if a `cond-expand` form has no fulfilled clause. There is no standard
way to do that, so this implementation uses the `syntax-error` form, with the
assumption that an actual implementation would provide some way to do this.

# Copyright

Copyright (C) Marc Feeley (1999). All Rights Reserved.

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

[Through 2005](https://srfi-email.schemers.org/srfi-announce/msg/2652023/), the
following license was the sole license.

This document and translations of it may be copied and furnished to others, and
derivative works that comment on or otherwise explain it or assist in its
implementation may be prepared, copied, published and distributed, in whole or
in part, without restriction of any kind, provided that the above copyright
notice and this paragraph are included on all such copies and derivative works.
However, this document itself may not be modified in any way, such as by
removing the copyright notice or references to the Scheme Request For
Implementation process or editors, except as needed for the purpose of
developing SRFIs in which case the procedures for copyrights defined in the SRFI
process must be followed, or as required to translate it into languages other
than English.

The limited permissions granted above are perpetual and will not be revoked by
the authors or their successors or assigns.

This document and the information contained herein is provided on an "AS IS"
basis and THE AUTHOR AND THE SRFI EDITORS DISCLAIM ALL WARRANTIES, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTY THAT THE USE OF THE
INFORMATION HEREIN WILL NOT INFRINGE ANY RIGHTS OR ANY IMPLIED WARRANTIES OF
MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE.

______________________________________________________________________

Editor: [Mike Sperber](mailto:srfi+minus+editors+at+srfi+dot+schemers+dot+org)

Last modified: Sun Jan 28 13:40:26 MET 2007
