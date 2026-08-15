# Scheme References

This document collects external references that are useful while building
Consent Scheme: Scheme-language references for the runtime core; in
[R7RS-Large References](#r7rs-large-references), orientation material for the
optional SRFI/R7RS-large library shelves; in
[REPL and Interactive-Environment References](#repl-and-interactive-environment-references)
prior art on REPLs and interactive programming environments for the Chunk 0.16
interactive-surface work; and in
[Agentic Harness and Language-Agent References](#agentic-harness-and-language-agent-references)
prior art on agentic harnesses and language agents for the Chunk 0.17
Milestone M2 *REPL Agent Harness — Minimal Loop* work; and in
[Scheme and Lisp Type Annotation References](#scheme-and-lisp-type-annotation-references)
prior art for typed documentation metadata, library-edge contract hints, and
type-related context for coding agents; in
[Runtime Heap and Native-Boundary References](#runtime-heap-and-native-boundary-references),
established handle-lifetime, root, and mutation-barrier designs for the owned
datum heap and borrowed-host ABI; in
[Hash-table references](#hash-tables-identity-and-persistent-map-references),
moving-collector identity hashing, weak reachability, persistent hash mappings,
and collision resistance; and in
[Scheme and Lisp Prior-Art Corpus](scheme-lisp-prior-art.md), the broader
Scheme/Lisp application, library, tooling, runtime, and book-code corpus that
should inform Consent Scheme without becoming normative. Keep
project-specific decisions in this
repository's own design docs; use these references for language context,
historical grounding, and implementation techniques.

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

### Unicode Character Data

- [Unicode 17.0.0](https://www.unicode.org/versions/Unicode17.0.0/) is the
  release pinned by Consent Scheme's generated character tables.
- [UAX #44: Unicode Character Database](https://www.unicode.org/reports/tr44/)
  defines the UCD file formats, property model, case-mapping sources, and
  versioning rules used by the generator.
- [Unicode 17.0.0 UCD](https://www.unicode.org/Public/17.0.0/ucd/) is the
  versioned source directory for `UnicodeData.txt`,
  `DerivedCoreProperties.txt`, `PropList.txt`, `SpecialCasing.txt`, and
  `CaseFolding.txt`. The pinned repository copies and hashes live under
  `vendor/unicode/17.0.0/`.
- [Unicode licensing FAQ](https://www.unicode.org/faq/unicode_license.html)
  identifies the Unicode License v3 as `Unicode-3.0`; the repository carries
  its full text in `LICENSES/Unicode-3.0.txt`.

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

## Runtime Heap and Native-Boundary References

These references ground Consent Scheme's owned-datum heap and borrowed-host
boundary. They are implementation prior art rather than additions to Scheme's
language semantics. The recurring pattern is a short-lived local reference
scope, explicit promotion for durable references, and mutation-indexed work
instead of repeated scans of historical heap state.

- The [JNI design overview](https://docs.oracle.com/en/java/javase/25/docs/specs/jni/design.html#global-and-local-references)
  makes local references valid for one native call and deletes that call's
  registry when it returns. Global references require explicit creation and
  deletion. Its array API similarly permits a temporary copy or pin and then
  requires an explicit release that reconciles and frees the borrowed storage.
- The [V8 embedder guide](https://v8.dev/docs/embed#handles-and-garbage-collection)
  puts local handles in a `HandleScope`, deletes them together when the scope
  ends, and reserves persistent handles for values that must survive calls.
  Persistent handles have explicit reset or weak-lifetime mechanisms.
- The [OCaml foreign-function interface](https://ocaml.org/manual/4.07/intfc.html#ss:c-gc-harmony)
  distinguishes local roots from registered global roots. Generational global
  roots must be changed through `caml_modify_generational_global_root`, allowing
  the collector to avoid repeatedly scanning roots that did not change.
- Detlefs, Knippel, Clinger, and Jacob's
  [Concurrent Remembered Set Refinement in Generational Garbage Collection](https://www.usenix.org/conference/java-vm-02/concurrent-remembered-set-refinement-generational-garbage-collection)
  surveys write barriers and remembered sets and describes update logs and
  refinement whose work follows mutations rather than the size of old heap
  regions. Consent's mutation observer is not a collector, but it follows the
  same ownership rule: record writes at the write gateway instead of
  rediscovering them by scanning unrelated history.

## Hash Tables, Identity, and Persistent-Map References

These references separate concerns that should not collapse into one table
implementation: public mutable APIs, identity hashing under a moving collector,
weak reachability, persistent hash mappings, and collision resistance for
attacker-controlled keys. Consent's current fixed-policy identity tables use
stable owned identifiers or a host-provided stable identity hash; collector
techniques below are prior art for the eventual standalone runtime, not a claim
that the portable implementation uses address hashing or collector hooks.

### Scheme identity hashing and weak reachability

- Abdulaziz Ghuloum and R. Kent Dybvig's
  [Generation-Friendly Eq Hash Tables](https://www.schemeworkshop.org/2007/procPaper3.pdf)
  (Scheme and Functional Programming 2007) addresses identity hashes under a
  moving generational collector. Its transport-link-cell design makes repair
  work follow keys that actually move rather than the total size of every live
  identity table.
- The [MIT/GNU Scheme hash-table manual](https://www.gnu.org/software/mit-scheme/documentation/stable/mit-scheme-ref/Hash-Tables.html)
  documents a contrasting address-hash design: tables declare that hashes can
  change, and the runtime rehashes them after collection. It also records why
  SRFI 69's callback and hash-stability contract prevents that optimization
  from being exposed portably without additional constraints.
- [SRFI 69](https://srfi.schemers.org/srfi-69/),
  [SRFI 125](https://srfi.schemers.org/srfi-125/),
  [SRFI 126](https://srfi.schemers.org/srfi-126/), and
  [SRFI 250](https://srfi.schemers.org/srfi-250/) define the mutable Scheme
  hash-table lineage scheduled around `(scheme hash-table)`. Their rationales
  distinguish the basic compatibility surface, implementation-selected
  identity hashing, R6RS naming, and insertion-order semantics.
- Barry Hayes's
  [Ephemerons: A New Finalization Mechanism](https://doi.org/10.1145/263698.263733)
  (OOPSLA 1997) explains why an ordinary weak key/value pair is insufficient
  when a value can retain its key. [SRFI 254](https://srfi.schemers.org/srfi-254/)
  carries ephemerons and guardians into a current Scheme library contract and
  makes the required collector cooperation explicit.

### Persistent hash mappings

- Phil Bagwell's
  [Ideal Hash Trees](https://infoscience.epfl.ch/entities/publication/b892b2ce-7bf0-41d2-b68c-fb44a3c64a33)
  (2001) introduces the hash-array mapped trie family used by many persistent
  map implementations.
- Michael J. Steindorfer and Jurgen J. Vinju's
  [Optimizing Hash-Array Mapped Tries for Fast and Lean Immutable JVM Collections](https://doi.org/10.1145/2814270.2814312)
  (OOPSLA 2015) develops compact, cache-conscious HAMT layouts and evaluates
  representation size as well as lookup, iteration, and equality costs.
- Sona Torosyan, Jon Zeppieri, and Matthew Flatt's
  [Runtime and Compiler Support for HAMTs](https://doi.org/10.1145/3486602.3486931)
  (DLS 2021) describes Racket's stencil-vector support for compact HAMTs. It is
  the most direct Lisp-family reference for deciding which representation help
  belongs in portable Scheme and which belongs in a future runtime or compiler.

### Collision resistance for untrusted keys

- Scott A. Crosby and Dan S. Wallach's
  [Denial of Service via Algorithmic Complexity Attacks](https://www.usenix.org/conference/12th-usenix-security-symposium/denial-service-algorithmic-complexity-attacks)
  (USENIX Security 2003) demonstrates that attacker-selected collisions can
  force ordinary expected-constant-time tables into worst-case behavior.
- Jean-Philippe Aumasson and Daniel J. Bernstein's
  [SipHash: a fast short-input PRF](https://eprint.iacr.org/2012/351.pdf)
  (INDOCRYPT 2012) designs a keyed short-input function specifically suited to
  defending content-keyed tables against hash flooding. It is relevant when a
  public table accepts attacker-controlled strings or symbols; it is not a
  replacement for fixed-policy object-identity hashing.

## R7RS-Large References

Consent Scheme targets R7RS-small first. Optional R7RS-large and SRFI shelves
must preserve that source-of-truth hierarchy: released Scheme reports and
ratified SRFI documents define normative behavior for adopted libraries, while
working repositories, dockets, ballots, and proposals provide planning context,
dependency discovery, and historical notes.

- [Scheme Standards](https://standards.scheme.org/) remains the canonical
  starting point for official Scheme reports and standardization material.
- [Scheme Requests for Implementation](https://srfi.schemers.org/) remains the
  canonical archive for ratified and draft SRFI documents. Use individual SRFI
  documents as the normative source when a ticket adopts a specific SRFI.
- [johnwcowan/r7rs-work](https://github.com/johnwcowan/r7rs-work) collects
  R7RS-large project notes, dockets, proposal writeups, ballots, and
  implementation pointers. Treat it as non-normative orientation unless a ticket
  explicitly names one of its files as planning input.
- [Committee B dockets](https://github.com/johnwcowan/r7rs-work/blob/master/CommitteeBDockets.md)
  organize portable-library candidates into R7RS-large docket groups. This is a
  high-signal guide for SRFI/R7RS-large issue labels, dependency discovery, and
  implementation planning, not a conformance requirement by itself.
- [Red Edition ballot archive](https://github.com/johnwcowan/r7rs-work/blob/master/RedEdition.md)
  records the voted Red data-structure libraries and their intended
  `(scheme ...)` names.
- [Tangerine Edition definition](https://github.com/johnwcowan/r7rs-work/blob/master/TangerineEdition.md)
  records the voted Tangerine mapping, regex, generator, numeric, vector,
  bytevector, and formatting libraries and their intended `(scheme ...)` names.
- The local roadmap issue
  [#53](https://github.com/tahoma/consent/issues/53) is Consent Scheme's
  scheduling source of truth for when optional SRFI and R7RS-large shelves land.
  Do not infer roadmap placement from upstream docket order.

## Scheme and Lisp Type Annotation References

These collect prior art for typed docstring metadata, especially the Chunk 0.17
typed parameter and return metadata work (#604). They are grounding for
vocabulary and tradeoffs, not authority over Consent Scheme's source syntax. The
near-term design goal is an advisory, Scheme-readable metadata vocabulary for
public library edges that can later lower into contracts, capability admission
checks, and tool schemas without changing the source metadata shape.

- [Typed Racket Guide: Specifying Types](https://docs.racket-lang.org/ts-guide/more.html)
  and [Types in Typed Racket](https://docs.racket-lang.org/ts-guide/types.html)
  show top-level and local annotation forms, function types, unions, recursive
  types, structure types, polymorphism, and type aliases. Typed Racket uses
  `Any` as a top type in examples, which is useful prior art for an explicit
  "intentionally unconstrained" metadata type.
- [Typed Racket Guide: Occurrence Typing](https://docs.racket-lang.org/ts-guide/occurrence-typing.html)
  and [The Design and Implementation of Typed Scheme](https://www2.ccs.neu.edu/racket/pubs/popl08-thf.pdf)
  document predicate-sensitive narrowing, true union types, recursive types,
  subtyping, polymorphism, and local inference for a Scheme-family language.
  This is the closest research lineage for typed metadata that should support
  ordinary Scheme idioms rather than force algebraic-datatype-only style.
- [Typed Racket Guide: Typed-Untyped Interaction](https://docs.racket-lang.org/ts-guide/typed-untyped-interaction.html)
  separates typed/untyped boundary annotation from runtime enforcement choices:
  deep contracts, shallow shape checks, and optional no-runtime-check modes. This
  is the key caution for #604: defining metadata should not silently decide an
  enforcement model.
- [Racket Guide: Contracts](https://docs.racket-lang.org/guide/contracts.html)
  is useful when later work considers lowering documentation metadata into
  runtime boundary checks. Keep it separate from the metadata vocabulary itself:
  a type descriptor can be advisory even when a related contract language exists.
- [Contracts for Higher-Order Functions](https://www2.ccs.neu.edu/racket/pubs/icfp2002-ff.pdf)
  (Findler and Felleisen) is the classic higher-order contract reference behind
  the Racket lineage. It is especially relevant for procedure-valued parameters,
  delayed checking, boundary identity, and blame assignment.
- [Soft Contract Verification for Higher-Order Stateful Programs](https://arxiv.org/abs/1711.03620)
  shows that contract information can feed static verification as well as
  runtime monitors. It is useful prior art for metadata that serves static
  analysis, contract lowering, and agent-facing explanations from one source.
- [CHICKEN 5 Manual: Types](https://wiki.call-cc.org/man/5/Types)
  documents Scheme-readable optional type declarations such as `(: name type)`,
  `(the TYPE expr)`, `(or ...)`, procedure types, `(list-of ...)`, `(forall ...)`,
  and `*` for any value. It is close to Consent Scheme's likely data shape and
  also shows a useful split: compiled analysis may use declarations while the
  interpreter can ignore them.
- [Bigloo Manual: Explicit typing](https://www-sop.inria.fr/indes/fp/Bigloo/doc/bigloo-27.html)
  documents result, formal-parameter, and local-variable annotations in a Scheme
  compiler. Missing annotations default to the generic `obj` type and the
  interpreter ignores annotations, which is useful contrast for Consent Scheme:
  the metadata reader can default omission to `any`, while the project-specific
  linter can still require public metadata to spell a type explicitly or use
  shorthand that means intentional `any`.
- [Common Lisp HyperSpec: Type Specifiers](https://www.lispworks.com/documentation/HyperSpec/Body/04_bc.htm)
  and [DECLARE](https://www.lispworks.com/documentation/HyperSpec/Body/s_declar.htm)
  standardize symbol and list type specifiers, local declaration placement,
  `type`, `ftype`, `the`, `deftype`, and compound forms such as `or`, `and`,
  `not`, `member`, `satisfies`, `values`, `function`, `cons`, and `vector`.
  Common Lisp's universal type is
  [`t`](https://www.lispworks.com/documentation/HyperSpec/Body/t_t.htm).
- [Practical Optional Types for Clojure](https://arxiv.org/abs/1812.03571)
  describes Typed Clojure as a Lisp-family optional type system that adapts
  occurrence typing to Clojure idioms, Java interop, multimethods, nullability,
  and heterogeneous dictionaries. It is less directly Scheme-like, but useful
  prior art for agent-facing metadata that may need to describe host interop and
  dictionary-shaped data later.

Across these systems, the top type is spelled differently: Typed Racket uses
`Any`, CHICKEN uses `*`, Bigloo uses `obj`, and Common Lisp uses `t`. That spread
argues for documenting Consent Scheme's spelling explicitly rather than assuming
a reader will infer it from another Lisp. It also supports keeping the first
metadata vocabulary small: ordinary predicates and analyzers can consume
symbols, unions, list/vector forms, procedure forms, and an explicit top type
before the project commits to dependent, refinement, or flow-sensitive typing.

### Type Context and Structured Metadata for Coding Agents

These references support the agent-facing motivation for #604 with a narrow
claim: precise, machine-readable type context, dependency context, and
static-analysis feedback can help LLM-based coding systems generate, repair, or
validate code. They do not prove that stronger type annotations are always
better, nor that every annotation should become a prompt token. The useful
lesson for Consent Scheme is to keep typed metadata structured and lowerable, so
tools can choose the right projection for a given task.

- [Statically Contextualizing Large Language Models with Typed Holes](https://arxiv.org/abs/2409.00921)
  integrates LLM code generation with a language server that exposes type and
  binding context. The Hazel and TypeScript experiments are useful prior art for
  treating language-server-readable type metadata as compact, semantically local
  context for code completion.
- [CATCODER: Repository-Level Code Generation with Relevant Code and Type
  Context](https://arxiv.org/abs/2406.03283) combines retrieved code with type
  dependencies from static analyzers for Java and Rust repository-level
  generation. Its reported improvement over RepoCoder is direct evidence that
  type context can matter at repository boundaries.
- [STALL+: Boosting LLM-based Repository-level Code Completion with Static
  Analysis](https://arxiv.org/abs/2406.10018) studies where static-analysis
  information helps in repository completion pipelines. Its distinction between
  prompting, decoding, and post-processing is a useful caution for #604: typed
  metadata should remain reusable data, not one hardcoded prompt format.
- [Less Is More: Measuring How LLM Involvement affects Chatbot Accuracy in
  Static Analysis](https://arxiv.org/abs/2604.21746) compares direct query
  generation, a schema-constrained intermediate representation, and a more
  agentic tool-use loop for static-analysis tasks. The structured intermediate
  result is the relevant prior art for Scheme-readable metadata lowering: keep
  the formal representation deterministic and let the model operate at the edge.
- [CodePlan: Repository-level Coding using LLMs and
  Planning](https://arxiv.org/abs/2309.12499) frames repository-wide changes as
  planning over dependency and may-impact analyses. It explicitly names adding
  type annotations, adding specifications, and fixing static-analysis reports as
  repository-level coding tasks, making it useful background for agent workflows
  that need stable metadata instead of local-only snippets.
- [Generative Type Inference for Python](https://arxiv.org/abs/2307.09163)
  uses static domain knowledge and type-dependency graphs to guide LLM type
  inference. This is not evidence that agents perform better when given stronger
  annotations, but it does show that type structure is recoverable and useful
  enough to be modeled explicitly.
- [Helping LLMs Improve Code Generation Using Feedback from Testing and Static
  Analysis](https://arxiv.org/abs/2412.14841) and [Static Analysis as a Feedback
  Loop: Enhancing LLM-Generated Code Beyond Correctness](https://arxiv.org/abs/2508.14419)
  show that analyzer and test feedback can improve generated code or repairs.
  They motivate keeping #604 metadata consumable by static-analysis tools, while
  stopping short of making metadata itself an enforcement mechanism.
- [Compiler generated feedback for Large Language
  Models](https://arxiv.org/abs/2403.14714) is useful negative evidence: compiler
  feedback produced only modest gains in its LLVM optimization setting, and
  sampling outperformed feedback at larger sample counts. It is a reminder to
  measure each metadata consumer rather than assuming more formal feedback is
  always helpful.
- [Unmasking the Genuine Type Inference Capabilities of LLMs for Java Code
  Snippets](https://arxiv.org/abs/2503.04076) reports benchmark-leakage and
  robustness concerns for LLM type inference. It is a good caution for future
  evaluation of type-aware agents: use leakage-resistant fixtures and
  semantics-preserving transformations before treating type-related scores as
  evidence of real understanding.

### Chez Scheme and Indiana Compiler Lineage

The [publications related to Chez Scheme](https://www.scheme.com/pubs/) index
collects work from the Indiana University period of Chez development. These
references do not form a typed annotation system, but they are relevant to
library-edge metadata that may later feed static analysis, contract lowering,
and compiler passes.

- [Automatic cross-library optimization](https://www.scheme.com/pubs/auto-xlib-opt.pdf)
  describes Chez Scheme's expander and source optimizer collaborating across
  library boundaries. It is useful background for treating public metadata as
  boundary information rather than only as documentation.
- [Enabling cross-library optimization and compile-time error checking in the
  presence of procedural macros](https://www.scheme.com/pubs/library-groups.pdf)
  introduces library groups and compile-time checking across library/program
  boundaries. It is relevant to #604's goal of making exported signatures
  analyzable before native tool/function calling consumes them.
- [A nanopass framework for commercial compiler development](https://www.scheme.com/pubs/commercial-nanopass.pdf)
  describes the pass-oriented infrastructure used by Chez Scheme's compiler.
  Future static checks or contract-lowering passes should preserve the same
  spirit: small, explicit transforms over Scheme-readable intermediate data.
- [Ftypes: Structured foreign types](https://www.scheme.com/pubs/ftypes.pdf)
  documents Chez Scheme's structured foreign-object mechanism. It is useful
  background for future host interop and capability metadata, where a type
  descriptor may need to name structured data that is not purely R7RS.

### Related Systems and Prior Art

These are non-Scheme (or Scheme-adjacent) systems whose designs recur as prior art
for the content-addressed library store / inter-agent exchange work
([design note](content-addressed-library-store.md)).

- [Library Surface and Manifests](library-surface.md) records the current
  manifest-schema prior-art boundary for R7RS/R6RS/SRFI library metadata,
  Guile/Racket/CHICKEN/ASDF package metadata, and Guix/Nix provenance. It is the
  repository reference for what belongs in manifest metadata versus #50 resolver
  behavior.
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

## Scheme and Lisp Prior-Art Corpus

[Scheme and Lisp Prior-Art Corpus](scheme-lisp-prior-art.md) preserves the
broader issue #654 research map: runtime comparison systems, major applications
and libraries, interactive tooling, and book-code corpora. It is non-normative
prior art for design pressure and coverage discovery; Consent Scheme's own
R7RS-small, portable-core, and explicit-capability documents remain
authoritative.

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
[repl.md](repl.md), [portable-repl.md](portable-repl.md),
[control-loop.md](control-loop.md),
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

## Agentic Harness and Language-Agent References

These collect external prior art on agentic harnesses and language agents,
grounding the Chunk 0.17 Milestone M2 *REPL Agent Harness — Minimal Loop* work —
the minimal task runner control loop, agent abstraction/registry/selection, the
`(agent prompt)` REPL verbs, the consent/capability/audit loop they run inside,
and the harness quick-start guide. They are prior art for grounding and
technique, **not** authority. Consent Scheme's distinctive stance — Lisp-first
internal data, explicit host capabilities, inspectable Scheme-readable agent
state, and consent/approval gating — stays defined in this repository's own
design docs ([control-loop.md](control-loop.md) and the *Agent Layer* section of
[architecture.md](architecture.md), plus [session-lifecycle.md](session-lifecycle.md)
and the capability and approval material in [architecture.md](architecture.md)).
For a non-normative synthesis of how these references inform the project — an
idea bank of experiments, features, and design decisions for the M2 harness —
see [Agentic-Harness and Language-Agent Prior-Art Synthesis](agentic-harness-ideas.md).

### Foundations and Surveys

- [Cognitive Architectures for Language Agents (CoALA)](https://arxiv.org/abs/2309.02427)
  (Sumers, Yao, Narasimhan, Griffiths) frames a language agent as modular memory
  (working + long-term), an action space split into internal and external
  actions, and a planning/execution decision loop. The closest external map to
  the project's agent-layer split between session memory, host capabilities, and
  the task control loop.
- [The Rise and Potential of Large Language Model Based Agents: A Survey](https://arxiv.org/abs/2309.07864)
  (Xi et al.) is a broad landscape survey (brain, perception, action) for
  orienting and locating subtopics.
- [A Survey on Large Language Model based Autonomous Agents](https://arxiv.org/abs/2308.11432)
  (Wang et al.) organizes agent construction along profile/memory/planning/
  action and catalogs evaluation strategies; a complementary index.

### Reasoning and Acting Loop

- [ReAct: Synergizing Reasoning and Acting in Language Models](https://arxiv.org/abs/2210.03629)
  (Yao et al., ICLR 2023) interleaves reasoning traces with environment-affecting
  actions in one loop; the canonical shape behind the reason/act/observe cycle
  and the `agent-yield` observation channel.
- [Reflexion: Language Agents with Verbal Reinforcement Learning](https://arxiv.org/abs/2303.11366)
  (Shinn et al., NeurIPS 2023) has agents reflect on failures in natural language
  and store reflections in episodic memory; relevant to scoped session memory
  and self-correction without weight updates.
- [Tree of Thoughts: Deliberate Problem Solving with Large Language Models](https://arxiv.org/abs/2305.10601)
  (Yao et al., NeurIPS 2023) generalizes chain-of-thought into a searchable tree
  with self-evaluation; for when a control loop needs lookahead/backtracking.

### Tool Use and Function Calling

- [Toolformer: Language Models Can Teach Themselves to Use Tools](https://arxiv.org/abs/2302.04761)
  (Schick et al.) is an early demonstration of deciding which API to call, when,
  and with what arguments; the tool-invocation problem the capability layer
  gates.
- [Gorilla: Large Language Model Connected with Massive APIs](https://arxiv.org/abs/2305.15334)
  (Patil et al., NeurIPS 2024) addresses accurate selection from large, changing
  tool/API sets via retrieval; its
  [Berkeley Function-Calling Leaderboard](https://github.com/ShishirPatil/gorilla)
  is a running evaluation of tool-calling behavior.

### Agent Protocol and Transport Specifications

- [Model Context Protocol specification](https://modelcontextprotocol.io/specification)
  and its
  [transports](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)
  define the open protocol for exposing tools, resources, and prompts to model
  clients. The project's intended external tool boundary; MCP is a wire encoding
  over Scheme-readable result/event datums, not the canonical internal model.
- [Agent2Agent Protocol specification](https://a2a-protocol.org/latest/specification/)
  defines a JSON-RPC-based agent-to-agent task and message protocol, with
  explicit parts, artifacts, streaming updates, and push notifications. Useful
  prior art for cross-agent handoff and long-running task state, even though
  Consent Scheme should keep its internal task state as Scheme-readable data.
- [Agent Client Protocol overview](https://agentclientprotocol.com/protocol/v1/overview)
  and its
  [transports](https://agentclientprotocol.com/protocol/v1/transports) describe
  a JSON-RPC protocol between editors/clients and coding agents. Relevant to
  editor-facing session control, thread/session identity, tool-call lifecycle
  events, and transport boundaries around an interactive agent runtime.
- [AG-UI](https://docs.ag-ui.com/introduction) defines an event protocol for
  connecting agents to user interfaces; see also its
  [protocol comparison](https://docs.ag-ui.com/agentic-protocols),
  [events](https://docs.ag-ui.com/concepts/events), and
  [serialization](https://docs.ag-ui.com/concepts/serialization) references.
  Useful when designing streamed UI state and human-visible agent events without
  treating the UI protocol as canonical agent memory.
- [Apertus Chat Format Specification](https://github.com/swiss-ai/apertus-format/blob/main/docs/format.md)
  documents a structured chat-template format with assistant blocks for
  thoughts, tool calls, tool outputs, and public responses. Useful prior art for
  model-facing prompt serialization and local chat-template renderers, while
  Consent Scheme keeps call IDs, provenance, policy gates, and canonical
  Scheme-readable tool/result datums outside the template edge.

### Provider Tool-Calling and Model API Surfaces

- [OpenAI function calling](https://platform.openai.com/docs/guides/function-calling)
  and the
  [Responses API reference](https://platform.openai.com/docs/api-reference/responses)
  document the provider surface for tool schemas, tool calls, and response
  items. Relevant to local OpenAI-compatible transport adapters while keeping
  provider JSON as an edge encoding.
- [Anthropic Claude tool use](https://docs.anthropic.com/en/docs/agents-and-tools/tool-use/overview)
  and the
  [Messages API](https://docs.anthropic.com/en/api/messages) document the
  provider-native messages and tool-use protocol. Relevant prior art for an
  Anthropic transport adapter with `tool_use` and `tool_result` blocks.
- [OpenRouter API reference](https://openrouter.ai/docs/api-reference/overview),
  [Ollama OpenAI compatibility](https://docs.ollama.com/openai), and the
  [vLLM OpenAI-compatible server](https://docs.vllm.ai/en/latest/serving/openai_compatible_server/)
  document common OpenAI-compatible local and aggregator model-provider
  surfaces. Relevant to one hardened OpenAI-compatible edge that can span local
  servers and hosted routing providers.

### Protocol Encoding and Streaming Substrates

- [JSON-RPC 2.0](https://www.jsonrpc.org/specification) is the RPC envelope
  shared by several agent/client protocols; useful as transport prior art, not
  as an internal runtime representation.
- [Server-Sent Events](https://html.spec.whatwg.org/multipage/server-sent-events.html)
  is the browser and HTTP streaming substrate used by many provider and agent
  protocols for incremental events.
- [JSON Patch (RFC 6902)](https://www.rfc-editor.org/rfc/rfc6902) and
  [JSON Canonicalization Scheme (RFC 8785)](https://www.rfc-editor.org/rfc/rfc8785)
  are useful references for structured deltas, fixtures, signatures, and audit
  trails at JSON protocol edges.

### Code as Action and Agent-Computer Interfaces

Closest prior art to the REPL-as-agent-surface thesis: the action space is
executable code in a live interpreter.

- [Executable Code Actions Elicit Better LLM Agents (CodeAct)](https://arxiv.org/abs/2402.01030)
  (Wang et al., ICML 2024) argues the action space should be executable code in
  an interpreter rather than per-call JSON, with multi-turn observe-and-revise;
  the central external argument for a Scheme REPL as the agent harness.
- [SWE-agent: Agent-Computer Interfaces Enable Automated Software Engineering](https://arxiv.org/abs/2405.15793)
  (Yang et al., NeurIPS 2024) finds a deliberately designed agent-computer
  interface dominates raw model capability; prior art for the REPL interaction
  contract and `(agent ...)` verb surface.
- [Voyager: An Open-Ended Embodied Agent with Large Language Models](https://arxiv.org/abs/2305.16291)
  (Wang et al.) builds an ever-growing library of executable, composable skills
  with iterative self-verification; a model for promoting validated helper
  libraries.

### Memory and Reflection

- [Generative Agents: Interactive Simulacra of Human Behavior](https://arxiv.org/abs/2304.03442)
  (Park et al., UIST 2023) runs an observation/planning/reflection loop over a
  retrievable memory stream; how reflection synthesizes durable memory.
- [MemGPT: Towards LLMs as Operating Systems](https://arxiv.org/abs/2310.08560)
  (Packer et al.) treats tiered memory under explicit control flow; analogy for
  keeping canonical Scheme-readable memory distinct from rebuildable
  in-context sets.

### Agentic Session Memory and Development-Flow Memory

These non-normative references collect development-flow memory prior art for
durable procedural guidance, cross-session recall, MCP/tool memory, and
repo-owned memory artifacts. For Consent Scheme, they are useful comparisons
for keeping reviewed Scheme-readable memory canonical while treating generated
summaries, vector indexes, graph stores, and hosted services as advisory or
rebuildable layers.

- [Codex Memories](https://developers.openai.com/codex/memories) and
  [Chronicle](https://developers.openai.com/codex/memories/chronicle) document
  opt-in Codex memory surfaces for turning prior thread and screen context into
  local memory files. Useful product prior art for separating personal/session
  continuity from repository-owned rules and source-controlled artifacts.
- [Codex AGENTS.md](https://developers.openai.com/codex/guides/agents-md) and
  [Agent Skills](https://developers.openai.com/codex/skills) document durable
  procedural memory through checked-in instructions, reusable workflows, scripts,
  and supporting references. Closest prior art for keeping hard agent rules and
  repeatable procedures inspectable instead of hidden in model state.
- [Codex MCP](https://developers.openai.com/codex/mcp) and the
  [Model Context Protocol specification](https://modelcontextprotocol.io/specification)
  document the tool/resource/prompt boundary used by many memory servers.
  Relevant when exposing memory through capability-gated external tools while
  retaining Scheme-readable data as the canonical store.
- [Mem0 Codex integration](https://docs.mem0.ai/integrations/codex) and
  [OpenMemory](https://mem0.ai/openmemory) document memory services for coding
  agents and MCP-compatible workflows. Useful prior art for cross-session recall,
  preference capture, and shared tool memory, provided authority and privacy
  boundaries stay explicit.
- [Supermemory MCP](https://supermemory.ai/docs/supermemory-mcp/introduction)
  and [MemoryGraph](https://memorygraph.dev/docs/) document hosted/project-scoped
  memory and local-first graph memory for AI assistants. Useful contrast between
  hosted recall, local SQLite/graph storage, and Consent's append-only memory
  model.
- [Cognee MCP](https://docs.cognee.ai/cognee-mcp/mcp-overview),
  [Zep Memory](https://help.getzep.com/v2/memory), and
  [Graphiti](https://help.getzep.com/graphiti/getting-started/welcome) document
  heavier persistent-memory, context-engineering, and temporal-knowledge-graph
  systems. Useful when evaluating organization-scale or multi-agent recall, not
  as requirements for the minimal harness.
- [Chroma Agentic Memory](https://docs.trychroma.com/guides/build/agentic-memory)
  describes semantic, procedural, and episodic memory over a vector collection
  with phase-specific retrieval. Useful DIY prior art for repo-backed ADR,
  agent-notes, and skills-style memory where embeddings help retrieval but
  remain rebuildable indexes over reviewed source artifacts.

### Multi-Agent and Orchestration

- [AutoGen: Enabling Next-Gen LLM Applications via Multi-Agent Conversation](https://arxiv.org/abs/2308.08155)
  (Wu et al.) models applications as conversations among customizable agents
  mixing model calls, tools, and human input; multi-agent / human-in-the-loop
  prior art.
- [Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)
  (Anthropic engineering) draws the workflows-vs-agents distinction, lists
  composable patterns, and biases toward the simplest design that works;
  applicable to scoping the minimal harness.

### Evaluation and Benchmarks

- [SWE-bench: Can Language Models Resolve Real-World GitHub Issues?](https://arxiv.org/abs/2310.06770)
  (Jimenez et al., ICLR 2024) runs end-to-end code-editing agents against real
  issues and their tests; outcome-based, execution-verified evaluation.
- [GAIA: a benchmark for General AI Assistants](https://arxiv.org/abs/2311.12983)
  (Mialon et al.) poses questions simple for humans but requiring multi-step
  tool use, browsing, and multimodality.
- [τ-bench: A Benchmark for Tool-Agent-User Interaction in Real-World Domains](https://arxiv.org/abs/2406.12045)
  (Sierra) scores agents on following domain rules/policy during multi-turn user
  interaction, final-state correctness, and reliability across trials; closely
  aligned with the project's policy-following and auditable-behavior emphasis.
