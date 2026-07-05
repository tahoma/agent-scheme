# Scheme and Lisp Prior-Art Corpus

This document preserves the Scheme and Lisp prior-art map for Consent Scheme.
The sources here are design pressure, study material, and coverage checklists.
They are not normative language references, and they do not supersede Consent
Scheme's own R7RS-small contract, portable-core ownership rule, or explicit
capability boundary. The corpus deliberately treats major applications or
libraries and bodies of example code from major Scheme/Lisp-based books as
first-class prior art, not afterthoughts behind implementation source trees.

The authoritative project stance remains in
[Architecture and threat model](architecture.md),
[Multi-Host Adapter and Bootstrap Strategy](multi-host-bootstrap.md),
[R7RS-small report reference](r7rs-small-report.md), and the canonical
[Scheme references](references.md). The earlier
[R7RS implementation test mining](r7rs-implementation-mining.md) report remains
the focused source for R7RS and near-R7RS test coverage discovery.

## Reading Posture

- Mine external systems for vocabulary, architecture pressure, documentation
  shape, test classes, and cautionary examples.
- Keep Consent Scheme's normative surface R7RS-small, host-neutral where
  possible, and explicit about capability grants, audit, and policy.
- Treat runtime and implementation references as comparison sources, not as a
  replacement module system, condition system, package model, or host API.
- Use third-party code and tests as coverage checklists unless a future change
  records license compatibility, attribution, and REUSE metadata.
- Write local examples and fixtures as original project-owned material unless
  a future issue explicitly scopes vendoring or close adaptation.

## Deep-Study Corpus

These sources map closely to Consent Scheme's core design tensions: effects and
state as inspectable data, live language boundaries, executable semantics,
sandboxing, structured documents, search, and shared editor/runtime sessions.

- [GNU Guix](https://guix.gnu.org/) and the
  [original Guix paper](https://arxiv.org/abs/1305.4584): mine for
  Scheme-readable package and system records, staged computation,
  g-expressions, provenance, profiles, generations, rollback, and effects
  represented as build data. Guix is one of the closest systems to Consent
  Scheme's preference for making host and system effects explicit as data.
- [Racket Redex](https://docs.racket-lang.org/redex/): mine for executable
  semantics, reduction relations, counterexample-driven checks, and language
  models that can be tested instead of only described in prose. It is useful
  for evaluator, macro, policy, and control-loop documentation.
- [Racket sandbox evaluator](https://docs.racket-lang.org/reference/Sandboxed_Evaluation.html):
  mine for evaluator factories, namespace restrictions, resource limits,
  timeout and memory controls, and containment of input, output, filesystem,
  and network access. Consent Scheme should keep its own capability grant and
  audit model instead of copying Racket's namespace model.
- [SXML, SSAX, SXPath, and related Scheme XML tools](https://okmij.org/ftp/Scheme/xml.html):
  mine for external structured formats represented as s-expressions, streaming
  parsers, tree transforms, query languages, and host-neutral document models.
  This is strong prior art for keeping canonical data Scheme-readable while
  treating XML, JSON, and other encodings as boundary formats.
- [miniKanren](https://minikanren.org/): mine for relational programming,
  unification, fair interleaving, search, and small embedded logic engines.
  It is relevant to future search, structural admission, pattern matching, and
  agent planning surfaces.
- [SLIME](https://slime.common-lisp.dev/) and SWANK: mine for an
  editor/runtime split, live evaluation over a wire protocol, inspectors,
  compiler notes, macroexpansion surfaces, and debugger UX.
- [SLY](https://joaotavora.github.io/sly/): mine for the modern Common Lisp
  successor to SLIME, especially inspector/debugger interaction, source
  annotations, and editor/runtime protocol refinements.
- [Geiser](https://www.nongnu.org/geiser/): mine for one Emacs Scheme
  interaction front-end over multiple Scheme implementations. It is directly
  relevant to cross-host parity and adapter boundaries.
- [nREPL](https://nrepl.org/): mine for a documented client/server REPL
  protocol, multi-client runtime interaction, middleware patterns, and a
  runtime that can be shared by tools.

The first-class book-code entries in [Book-Code Corpus](#book-code-corpus),
especially SICP and PAIP, also belong in the deep-study tier.

## Targeted-Mining Corpus

These sources are valuable for specific design questions, API shapes, examples,
and cautionary host-boundary lessons.

- [Rosette](https://emina.github.io/rosette/): mine for solver-aided language
  techniques, symbolic execution, synthesis, and constraint-driven validation.
  Treat this as long-term inspiration for policy analysis and fixture
  generation, not near-term runtime scope.
- [Scribble](https://docs.racket-lang.org/scribble/): mine for documentation as
  code, generated references, prose/code cross-linking, and source examples
  that can be evaluated or reflected.
- [Pollen](https://docs.racket-lang.org/pollen/): mine for publication
  pipelines driven by Lisp-family syntax and for keeping prose, code, and
  generated artifacts tied to one source.
- [GNU TeXmacs](https://www.texmacs.org/tmweb/home/welcome.en.html): mine for
  structured documents as trees, Scheme extension inside an interactive
  application, plugin output integration, and programmatic manipulation of rich
  document state.
- [LilyPond](https://lilypond.org/): mine for a mature domain-specific textual
  language, Scheme extension hooks, staged interpretation into rendered output,
  large input corpora, and user-facing diagnostics for domain experts.
- [GIMP Script-Fu](https://developer.gimp.org/resource/script-fu/): mine for
  application plug-in scripting, a host procedure database boundary, long-term
  compatibility pressure, and extension API migration pain. This is mostly a
  cautionary case for keeping Consent Scheme host capabilities small,
  explicit, auditable, and versioned.
- [Maxima](https://maxima.sourceforge.io/): mine for symbolic algebra, rewrite
  and simplification rules, exact arithmetic expectations, parser/printer
  behavior, and long-lived REPL-facing mathematical computation.
- [Nyxt](https://nyxt.atlas.engineer/): mine for programmable browser
  architecture, command buffers, live reconfiguration, Lisp-native user
  scripting, and exposure of live web/browser state through commands.
- [StumpWM](https://stumpwm.github.io/): mine for a small live programmable
  host state model, command dispatch, window-management capabilities, user
  configuration as Lisp, and REPL-driven customization.
- [McCLIM](https://mcclim.common-lisp.dev/): mine for presentation types,
  command loops, inspectors, and UI objects tied to semantic Lisp values.
- [SLIB](https://people.csail.mit.edu/jaffer/SLIB): mine for portable Scheme
  library conventions, compatibility layers, feature variance handling, and
  reference implementations. Do not import code without a license review.
- [SRFI archive](https://srfi.schemers.org/): mine for Scheme extension
  specifications, reference implementations, test suites, naming conventions,
  and compatibility vocabulary. A SRFI becomes normative only when a Consent
  Scheme issue explicitly adopts it.
- [ACL2](https://acl2.org/): mine for proof-oriented Common Lisp, executable
  logic, large community book corpora, disciplined subset design, and durable
  formal artifacts. It is not Scheme semantics authority.
- [Alexandria](https://common-lisp-libraries.readthedocs.io/alexandria/):
  mine for utility-library API shape, portability conventions, and
  documentation examples across Common Lisp implementations.
- [CFFI](https://cffi.common-lisp.dev/): mine for foreign-function boundary
  design, portability tradeoffs, and documentation of host interop hazards.
- [CL-PPCRE](https://edicl.github.io/cl-ppcre/): mine for regex and pattern
  APIs expressed in Lisp terms, plus performance/documentation tradeoffs for a
  nontrivial library.
- [Hunchentoot](https://edicl.github.io/hunchentoot/): mine for web server,
  request/session, and application-boundary API shapes in a Lisp system.

## Runtime Comparison Corpus

These systems remain useful comparison points for implementation strategy,
runtime shape, deployment, debugging, documentation, package ecosystems, and
cross-host portability. They are not replacements for the Consent Scheme
language contract.

- [Racket](https://racket-lang.org/): mine for language-oriented programming,
  macro tooling, source-location discipline, contracts, Typed Racket, DrRacket,
  generated documentation, and `#lang` as design pressure. Do not import
  Racket's broader language/module system into Consent Scheme's R7RS-small
  contract.
- [GNU Guile](https://www.gnu.org/software/guile/): mine for Scheme as an
  extension language, host embedding, C interop, module organization,
  documentation conventions, introspection, and host-effect surfaces. Consent
  Scheme should keep authority explicit and policy-gated.
- [Chez Scheme](https://cisco.github.io/ChezScheme/): mine for
  compiler/runtime structure, library management, expander/compiler
  cooperation, debugging, profiling, and possible future backend strategy.
  Chez is R6RS-oriented, so any backend use must preserve the R7RS-small user
  contract behind an adapter.
- [Chibi Scheme](https://github.com/ashinn/chibi-scheme): mine for small
  embeddable R7RS layering, `.sld` support, conformance tests, and optional
  external validation. Chibi is already covered in
  [R7RS implementation test mining](r7rs-implementation-mining.md).
- [Gambit](https://gambitscheme.org/): mine for compiled deployment,
  self-hosting path, daemon/runtime strategy, retargetable compilation, and
  static executable packaging ideas. Keep deployment lessons separate from
  language semantics.
- [Gerbil](https://cons.io/): mine for Gambit-hosted system organization,
  concurrency and actor-style abstractions, executable packaging, and
  practical large-system Scheme structure.
- [Gauche](https://practical-scheme.net/gauche/): mine for practical Scheme
  scripting, startup ergonomics, OS integration, Unicode, regex, SRFI coverage,
  command-line behavior, and library usability. Gauche is already covered in
  the implementation-mining report for several conformance areas.
- [CHICKEN Scheme](https://call-cc.org/): mine for Scheme-to-C deployment,
  extension packaging, FFI boundaries, optional type declarations, pragmatic
  compatibility, and ecosystem conventions.
- [Kawa](https://www.gnu.org/software/kawa/): mine for Scheme hosted on the
  JVM, host interop boundaries, and embedding Scheme into a large non-Scheme
  runtime ecosystem.
- [MIT/GNU Scheme](https://www.gnu.org/software/mit-scheme/): mine for classic
  interactive Scheme environment design, SICP lineage, debugger/editor
  integration history, and teaching-oriented runtime behavior.
- [Sagittarius Scheme](https://github.com/ktakashi/sagittarius-scheme): mine as
  an R7RS/R6RS comparison point and oracle-diversity source. Use the existing
  implementation-mining report for its current test-mining posture.
- [Cyclone Scheme](https://github.com/justinethier/cyclone): mine for compiled
  R7RS behavior, macro hygiene cases, bytevector coverage, and small
  regression-style tests. Use the existing implementation-mining report before
  doing new fixture work.
- [Racket R7RS](https://github.com/lexi-lambda/racket-r7rs): mine for
  Racket-hosted R7RS import semantics and library loading expectations. The
  implementation-mining report records the current license caution.
- [Portable standalone R7RS tests](https://gitea.scheme.org/Retropikzel/r7rs-tests):
  mine only as a coverage checklist until license status is clarified, as
  recorded in the implementation-mining report.
- [SBCL](https://www.sbcl.org/): mine for condition/debugger culture,
  performance tooling, image/runtime behavior, and implementation notes.
- [ECL](https://ecl.common-lisp.dev/): mine for Common Lisp embedding,
  compilation to C, runtime packaging, and host interop boundaries.
- [Clozure CL](https://ccl.clozure.com/): mine for Common Lisp implementation
  portability, runtime/debugger behavior, and image-based development history.
- [ASDF](https://asdf.common-lisp.dev/): mine for build/load planning,
  system definitions, dependency expression, and implementation portability
  conventions.
- [Quicklisp](https://www.quicklisp.org/beta/): mine for package index UX,
  distribution cadence, library discovery, and ecosystem maintenance posture.
- [Clojure](https://clojure.org/): mine for immutable data defaults,
  protocols, host interop, dynamic development, ClojureScript deployment, and
  nREPL ecosystem ideas. Treat it as Lisp-family adjacent, not Scheme
  semantics authority.
- [BiwaScheme](https://www.biwascheme.org/): mine for browser-hosted Scheme,
  JavaScript boundary choices, demos, and documentation possibilities.
- [LIPS](https://lips.js.org/): mine for JavaScript-hosted Lisp/Scheme
  embedding, browser constraints, and small runtime tradeoffs.
- [Janet](https://janet-lang.org/): mine for small batteries-included runtime
  design, embedding ergonomics, and host-boundary tradeoffs. Treat it as
  Lisp-family adjacent.

## Book-Code Corpus

These corpora are first-class prior art. They often matter more than another
implementation tree because they present evaluator, macro, search, compiler,
DSL, and symbolic-programming ideas in small readable programs.

- [Structure and Interpretation of Computer Programs](https://mitp-content-server.mit.edu/books/content/sectbyfn/books_pres_0/6515/sicp.zip/full-text/book/book.html)
  and [SICP Scheme source code](https://mitp-content-server.mit.edu/books/content/sectbyfn/books_pres_0/6515/sicp.zip/code/index.html):
  mine the metacircular evaluator, lazy evaluator, nondeterministic evaluator,
  query evaluator, streams, register-machine simulator, explicit-control
  evaluator, compiler chapters, and environment model explanations. Treat the
  code as study material unless a future license review says otherwise.
- [Paradigms of Artificial Intelligence Programming code](https://github.com/norvig/paip-lisp):
  mine pattern matching, search, GPS planning, ELIZA-style symbolic
  interaction, Prolog/unification, symbolic algebra, expert systems, parsers,
  games, and Scheme interpreter/compiler examples in Common Lisp. This is a
  high-value source for agent-loop vocabulary and symbolic AI history.
- [Essentials of Programming Languages](https://mitpress.mit.edu/9780262062794/essentials-of-programming-languages/)
  and the [EoPL3 support site](https://eopl3.com/): mine staged interpreter
  construction, environment/store models, CPS interpreters, type checkers,
  language feature growth by small deltas, and pedagogical tests.
- [The Scheme Programming Language, 2nd edition](https://www.scheme.com/tspl2d/intro.html)
  and [4th edition](https://www.scheme.com/tspl4/): mine idiomatic Scheme
  examples, library and macro discussions, Chez-lineage examples, and R5RS/R6RS
  comparison points.
- [Lisp in Small Pieces](https://www.cambridge.org/core/books/lisp-in-small-pieces/66FD2BE3EDDDC68CA87D652C82CF849E):
  mine evaluator and compiler architecture, closures, environments,
  continuations, object systems, compilation strategies, and implementation
  tradeoffs across Lisp and Scheme-family languages.
- [Programming Languages: Application and Interpretation](https://www.plai.org/):
  mine interpreter progression, testing pedagogy, feature explanations,
  Racket-based teaching examples, and approachable contributor-facing
  documentation patterns.
- [On Lisp](https://paulgraham.com/onlisp.html): mine macro patterns, embedded
  languages, bottom-up program design, continuation-oriented examples, and
  miniature object systems. Treat code as study material unless licensing
  permits reuse.
- [Practical Common Lisp](https://gigamonkeys.com/book/): mine real
  application chapters, a unit test framework, binary parsing, ID3 parsing,
  web programming, spam filtering, HTML generation, and idiomatic Common Lisp
  explanation.
- [How to Design Programs](https://htdp.org/): mine teaching-oriented design
  method, data definitions, examples, tests, and disciplined progression from
  data shape to functions.
- [The Little Schemer](https://mitpress.mit.edu/9780262560993/the-little-schemer/)
  series: mine recursion pedagogy, list-processing examples, reasoning style,
  and the relational-programming lineage through later books.
- [An Introduction to Scheme and its Implementation](https://docs.scheme.org/schintro/):
  mine implementation walkthroughs, evaluator details, macros, environments,
  interpreter mechanics, and compact explanatory examples.
- [Software Design for Flexibility](https://mitpress.mit.edu/9780262045490/software-design-for-flexibility):
  mine combinators, generic operations, propagation networks, flexible program
  organization, and modern Sussman/Hanson design patterns for future
  agent-facing Scheme libraries.

## License and Reuse Posture

This issue preserves a research map; it does not vendor code, copy tests, or
closely adapt third-party examples. Future work that wants to import,
translate, or closely follow external material must:

- file or use an issue that explicitly scopes the source and intended reuse;
- confirm license compatibility with this repository's
  [Licensing Policy](licensing.md);
- record attribution and provenance in the changed file or fixture metadata;
- add or update REUSE metadata for vendored third-party material;
- apply the `review:license-vendor` process when third-party material is
  checked in.

When no license review has been done, use a source as a checklist and write
small original Consent Scheme fixtures or examples from the underlying language
requirement instead of copying the upstream text.

## Cross-Links

- [Scheme references](references.md) remains the index for standards, Scheme
  books, type-annotation references, REPL references, and agentic-harness
  references.
- [R7RS implementation test mining](r7rs-implementation-mining.md) is the
  source for the earlier R7RS implementation and test-suite mining pass.
- The [REPL and Interactive-Environment References](references.md#repl-and-interactive-environment-references)
  section already covers SLIME, nREPL, Geiser, live environments, notebooks,
  and interactive error recovery in more detail.
- The [Agentic Harness and Language-Agent References](references.md#agentic-harness-and-language-agent-references)
  section covers model/tool/agent-loop systems that inform the M2 harness but
  are not Scheme/Lisp corpus entries themselves.
- The [Architecture and threat model](architecture.md) and
  [Multi-Host Adapter and Bootstrap Strategy](multi-host-bootstrap.md) documents
  define how to apply any prior-art lesson without weakening the portable
  R7RS-small, explicit-capability, Scheme-readable-data stance.
