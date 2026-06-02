# Scheme References

This document collects external Scheme references that are useful while building
Consent Scheme. Keep project-specific decisions in this repository's own design
docs; use these references for language context, historical grounding, and
implementation techniques.

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
