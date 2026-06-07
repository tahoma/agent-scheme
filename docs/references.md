# Scheme References

This document collects external references that are useful while building
Consent Scheme: Scheme-language references for the runtime core, and — in
[REPL and Interactive-Environment References](#repl-and-interactive-environment-references)
— prior art on REPLs and interactive programming environments for the Chunk 0.16
interactive-surface work. Keep project-specific decisions in this repository's
own design docs; use these references for language context, historical grounding,
and implementation techniques.

## Canonical External Scheme References

### Standards and Specifications

- [Scheme Standards](https://standards.scheme.org/) indexes the RnRS reports,
  errata-corrected editions, and related standards material.
- [R7RS-small, official PDF](https://standards.scheme.org/official/r7rs.pdf)
  is the released small-language report. The local Markdown rendering lives in
  [R7RS-small report reference](r7rs-small-report.md).
- [R7RS-small, errata-corrected HTML](https://standards.scheme.org/corrected-r7rs/)
  is useful for browser-based lookup and cross-reference checks.
- [R6RS](https://r6rs.org/) is useful when comparing library systems, conditions,
  Unicode behavior, `syntax-case`, and more fully specified error behavior.
- [R5RS](https://standards.scheme.org/corrected-r5rs/r5rs.html) remains the
  compact classic reference for Scheme's core syntax, procedures, and
  `syntax-rules` baseline.
- [Scheme Requests for Implementation](https://srfi.schemers.org/) is the
  extension-specification archive. Use SRFIs only when a ticket explicitly
  adopts non-core behavior or needs compatibility research.

### Books and Guides

- [The Scheme Programming Language, 2nd edition](https://www.scheme.com/tspl2d/intro.html)
  by R. Kent Dybvig is a practical Scheme guide from the R4RS/R5RS transition
  era, useful for reader syntax, evaluation examples, and idiomatic Scheme.
- [The Scheme Programming Language, 4th edition](https://scheme.com/tspl4/)
  is the R6RS-era edition of the same guide, useful for comparing the newer
  library and macro model with R7RS-small.
- [Structure and Interpretation of Computer Programs](https://mitp-content-server.mit.edu/books/content/sectbyfn/books_pres_0/6515/sicp.zip/full-text/book/book.html)
  by Harold Abelson, Gerald Jay Sussman, and Julie Sussman is the original
  Scheme edition of SICP. Its metacircular evaluator, explicit-control
  evaluator, and compiler chapters are especially relevant.
- [SICP Scheme source code](https://mitp-content-server.mit.edu/books/content/sectbyfn/books_pres_0/6515/sicp.zip/code/index.html)
  collects the book's runnable Scheme examples.
- [Essentials of Programming Languages](https://mitpress.mit.edu/9780262062794/essentials-of-programming-languages/)
  by Daniel P. Friedman, Mitchell Wand, and Christopher T. Haynes is useful for
  interpreter structure, denotational and operational instincts, and language
  feature growth through small evaluators.
- [EoPL 3rd edition support site](https://eopl3.com/) collects related support
  material for the book.
- [Lisp in Small Pieces](https://www.cambridge.org/core/books/lisp-in-small-pieces/66FD2BE3EDDDC68CA87D652C82CF849E)
  by Christian Queinnec is a deeper implementation reference for Lisp and
  Scheme-family evaluators, compilers, continuations, and runtime structure.

### Catalogs and Historical Material

- [Scheme Books](https://books.scheme.org/) is the broadest curated catalog for
  Scheme books, including SICP, EoPL, TSPL, and implementation-focused texts.
- [Scheme Documentation](https://docs.scheme.org/) is the current documentation
  portal for Scheme community material.
- [Scheme Implementations](https://get.scheme.org/) indexes active Scheme
  implementations and their reported RnRS coverage.
- [The Lambda Papers](https://research.scheme.org/lambda-papers/) collect the
  early Steele and Sussman papers that introduced Scheme, continuations, and
  lambda-centered implementation ideas.

### Documentation Metadata Influences

- [Guile procedure properties](https://www.gnu.org/software/guile/manual/html_node/Procedure-Properties.html)
  document literal procedure-property metadata and string docstrings in
  procedure bodies. Consent Scheme's
  [Docstring Metadata Convention](docstring-metadata.md) is influenced by that
  shape but defines its own R7RS-compatible public behavior and
  Scheme-readable metadata records.

### Related Systems and Prior Art

These are non-Scheme (or Scheme-adjacent) systems whose designs recur as prior art
for the content-addressed library store / inter-agent exchange work
([design note](content-addressed-library-store.md)).

- [GNU Guix](https://guix.gnu.org/) is a functional package manager written in
  **Guile Scheme**, with a hash-addressed immutable store, profiles/generations as
  a mutable name→store indirection, and atomic rollback. The closest OS-level
  prior art to a Scheme content-addressed library system — and directly readable,
  being Scheme. (Classic store paths are input-addressed; treat content-addressing
  parallels accordingly.)
- [Nix](https://nixos.org/) is Guix's sibling and origin of the functional /
  hash-addressed-store model; useful for the OS-level "ended DLL hell" parallel
  and for content-addressed derivations.
- [Unison](https://www.unison-lang.org/) for content-addressed definitions
  (hash = identity, alpha-normalized, references-by-hash) and the abilities
  effect system — the closest semantic-level model for definition identity.

## Additional Candidates

These are worth keeping in mind, but they should only become project references
when a ticket benefits from them directly.

- [*How to Design Programs*](https://htdp.org/) for teaching-oriented design
  method and Scheme-family pedagogy.
- [*The Little Schemer*](https://mitpress.mit.edu/9780262560993/the-little-schemer/)
  series for small-step recursion, reasoning, and relational programming style.
- [*Programming Languages: Application and Interpretation*](https://www.plai.org/)
  for interpreter and language-design pedagogy on the Racket side of the Scheme
  family.
- [*An Introduction to Scheme and its Implementation*](https://docs.scheme.org/schintro/)
  for implementation details that complement SICP and Lisp in Small Pieces.
- [*Software Design for Flexibility*](https://mitpress.mit.edu/9780262045490/software-design-for-flexibility)
  for modern Sussman/Hanson design patterns that may inform agent-facing Scheme
  libraries later.

## REPL and Interactive-Environment References

These collect external prior art on REPLs and interactive programming
environments, grounding the Chunk 0.16 interactive-surface work — the functional
R7RS terminal REPL, cross-host parity, the interaction contract, chrome, and
reader recovery. They are prior art for grounding and technique, **not**
authority. Consent Scheme's distinctive REPL stance — a host-neutral record
stream as the canonical surface, host-specific chrome as presentation, a shared
user+agent session, Scheme-readable replayable transcripts, and errors-as-data
reader recovery — stays defined in this repository's own design docs
([repl-interaction-contract.md](repl-interaction-contract.md),
[portable-repl.md](portable-repl.md), [control-loop.md](control-loop.md),
[transcripts.md](transcripts.md), [session-lifecycle.md](session-lifecycle.md),
and [debugger.md](debugger.md)).

### Interactive Lisp/Scheme REPL Environments

- [SLIME / SWANK](https://slime.common-lisp.dev/) splits Emacs↔Lisp interaction
  into an Emacs client and an in-image SWANK server over a wire protocol; direct
  prior art for the editor↔running-runtime separation and the interaction
  contract. Supports Common Lisp, Clojure, and Scheme images.
- [nREPL](https://nrepl.org/) is Clojure's network REPL: a documented
  client/server protocol where many tools connect to one runtime (the inverse of
  SLIME's one-client-many-Lisps). Relevant to a host-neutral REPL protocol and to
  the agent and user sharing one session.
- [Geiser](https://www.nongnu.org/geiser/) is Emacs Scheme interaction spanning
  Guile/Racket/Chicken/MIT/Chibi/Chez; the closest analog to one REPL front-end
  over multiple Scheme implementations, relevant to cross-host parity.
- [DrScheme: A Programming Environment for Scheme](https://www2.ccs.neu.edu/racket/pubs/jfp01-fcffksf.pdf)
  (Findler, Flanagan, Flatt, Krishnamurthi, Felleisen) describes a functional
  read-eval-print loop with language levels, an algebraically sensible printer,
  and an integrated editor; reference for REPL semantics and structured output
  rendering. See also [The Racket Manifesto](https://www2.ccs.neu.edu/racket/pubs/manifesto.pdf)
  for the language-plus-environment design principles.

### History and Concept

- [Read–eval–print loop](https://en.wikipedia.org/wiki/Read%E2%80%93eval%E2%80%93print_loop)
  is a history pointer for the term and its lineage (Deutsch & Berkeley's 1964
  PDP-1 Lisp; McCarthy's interactive `eval`). For historical grounding only.

### Image-Based and Live Environments

- [Smalltalk-80: The Language and its Implementation](http://stephane.ducasse.free.fr/FreeBooks/BlueBook/Bluebook.pdf)
  (Goldberg & Robson, the "Blue Book") is the canonical live, image-based
  environment where the editor and running system are one; reference for a
  persistent shared live session and image/snapshot semantics
  ([session-lifecycle.md](session-lifecycle.md)).

### Notebooks and Literate Computing

- [IPython / Jupyter](https://ipython.org/) — Pérez & Granger, "IPython: A System
  for Interactive Scientific Computing"
  ([CiSE 2007](https://doi.org/10.1109/MCSE.2007.53)) and the later
  language-agnostic kernel/client architecture; reference for a host-neutral REPL
  message protocol, rich/structured results, and "literate computing" narratives
  anchored in live computation ([transcripts.md](transcripts.md)).

### Structured Interaction, Errors, and Recovery

- [Condition Handling in the Lisp Language Family](https://www.nhplace.com/kent/Papers/Condition-Handling-2001.html)
  (Kent Pitman, 2001) covers interactive restarts and condition handling: the
  Lisp model for recoverable, interactive error handling. Directly relevant to
  reader recovery / errors-as-data, the debugger
  ([debugger.md](debugger.md)), and graceful REPL resync.
