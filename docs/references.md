# Scheme References

This document collects external references that are useful while building
Consent Scheme: Scheme-language references for the runtime core; in
[REPL and Interactive-Environment References](#repl-and-interactive-environment-references)
prior art on REPLs and interactive programming environments for the Chunk 0.16
interactive-surface work; and in
[Agentic Harness and Language-Agent References](#agentic-harness-and-language-agent-references)
prior art on agentic harnesses and language agents for the Chunk 0.17 Milestone M2
*REPL Agent Harness — Minimal Loop* work. Keep project-specific decisions in this
repository's own design docs; use these references for language context, historical
grounding, and implementation techniques.

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
- [Model Context Protocol specification](https://modelcontextprotocol.io/specification)
  and its [announcement](https://www.anthropic.com/news/model-context-protocol)
  define the open protocol for exposing tools/resources/prompts to model clients.
  The project's intended external tool boundary; MCP is a wire encoding over
  Scheme-readable result/event datums, not the canonical internal model.

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
