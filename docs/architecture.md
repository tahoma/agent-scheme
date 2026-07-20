# Consent Scheme Architecture and Threat Model

Consent Scheme is an R7RS-small runtime for agentic scripting. Its first
host is Emacs, but Emacs is an adapter around the language, not the language's
semantic center.

The core promise is:

- standard Scheme inside a sandbox
- explicit host capabilities at the boundary
- inspectable Scheme-readable data for agent state
- ecosystem compatibility through Agent Skills packages

The old working name "Agent Lisp" should be treated as historical. Durable
project APIs, docs, tests, and examples should use "Consent Scheme".

## Design Rules

### R7RS First

Consent Scheme targets R7RS-small compliance rather than a Scheme-flavored Lisp
subset. The reader, datum validator, evaluator, macro expander, library system,
standard-library bindings, ports, writer, and conformance tests should be
designed against R7RS-small semantics.

This does not mean Scheme code receives unrestricted access to live Emacs. R7RS
evaluation and host authority are separate concerns:

- R7RS libraries define the portable language surface.
- Host-effecting R7RS libraries, such as `(scheme file)`, `(scheme load)`,
  `(scheme eval)`, `(scheme process-context)`, `(scheme read)`, and
  `(scheme write)`, are policy-gated where they touch host state.
- Emacs-specific behavior appears only through explicit capability libraries
  such as `(emacs buffer)`, `(emacs window)`, `(emacs command)`, and
  `(emacs project)`.

### Lisp-First Internals

Internal Consent Scheme APIs should think in Lisp and Scheme terms first. Prefer
s-expressions, symbols, datums, macros, REPL transcripts, and Scheme-readable
logs for internal examples and records.

JSON, HTTP, Markdown, MCP, and other encodings belong at protocol or document
boundaries. They may wrap or transport data, but they should not become the
canonical internal model.

For example, an evaluation response should conceptually look like Scheme data:

```scheme
(evaluation-result
  (status ok)
  (value (vector 1 2 3))
  (events
    ((yield (kind observation) (value (buffer-name "notes.scm")))
     (progress (phase reader) (message "parsed 12 datums"))))
  (budget (steps-used 42) (host-calls 1)))
```

An MCP response may encode that as JSON at the wire boundary, but the payload
shape remains a Scheme-readable datum.

### Portable Core, Severable Hosts

As much of the runtime as practical should be portable R7RS Scheme: helper
libraries, reference data, memory records, plans, tests, fixtures, skill
manifests, and agent workflows. Emacs Lisp should serve as a host adapter for
Emacs-specific capabilities, UI buffers, process integration, policy prompts,
and persistence plumbing.

This is a first-principles ownership rule, not a preference to revisit feature
by feature. A behavior that can be expressed as deterministic Scheme data,
library code, parser/encoder logic, protocol shaping, fixture data, or
host-neutral control flow belongs in portable Scheme. The dual-core surface is
the smallest irreducible subset that each bootstrap must implement separately:
reader and evaluator kernels, macro and library bootstrap machinery, primitive
dispatch, and host-effect adapters. Parallel Emacs Lisp and portable Scheme
implementations are a temporary constraint to justify, not an architecture to
grow.

The initial implementation may be hosted in Emacs Lisp while the project is
bootstrapping, but modules should keep the following boundary clear:

- portable core: reader, datums, evaluator, macro expander, libraries, writer,
  conformance fixtures, portable agent libraries, protocol datums, and
  host-neutral codecs
- host adapter: Emacs handles, buffers, windows, commands, policies, UI,
  process launch, local files, network calls, persistence, effectful streaming,
  and MCP registration

Future hosts should be able to reuse the core data model and libraries without
pretending to be Emacs.

The detailed multi-host adapter and bootstrap stance is recorded in
[Multi-Host Adapter and Bootstrap Strategy](multi-host-bootstrap.md). New host
or backend work should preserve that document's R7RS-small contract, portable
test path, and Scheme-readable adapter boundary.

The first planned non-Emacs host is the native CLI and daemon adapter. Its
Scheme-readable declaration, capability libraries, handle model, prompt
behavior, and process-boundary test strategy are recorded in
[Native CLI and Daemon Adapter Contract](native-cli-daemon-adapter.md).

The public versus internal library boundary is manifest-owned. The current
visibility vocabulary, seed manifest topology, optional host-adapter
availability model, primitive `implementation-id` routing, and source export
filtering semantics are recorded in
[Library Surface and Manifests](library-surface.md).

### First-Class Portable Scheme

The portable R7RS implementation under `scheme/consent/` is not a sample,
downstream mirror, or convenience test harness. It is a peer implementation of
the language core and the strategic path toward a self-hosted or native reader,
evaluator, emitter, and REPL. Emacs Lisp is the first host and useful
bootstrap implementation, but it must not become the sole architectural
reference.

Changes to reader, evaluator, macro, library, runtime, result, primitive
manifest, standard-library, conformance fixture, or public test behavior should
first ask whether the behavior can be single-sourced from portable Scheme. When
it can, the portable `.sld` is the canonical implementation and both bootstraps
load it. When it cannot, preserve architectural parity between
`lisp/consent-*.el` and `scheme/consent/*.sld` for the irreducible dual-core
slice. If a slice must land on one side first, the issue, commit, or pull
request should name the remaining parity work, explain why it cannot yet be
single-sourced, and the work should not be presented as architecturally complete
until both sides are handled or the duplication is collapsed into portable
Scheme.

The repository-owned agent instructions in [AGENTS.md](../AGENTS.md) codify
this as the standing contributor rule: libraries expressible over `(scheme
base)` are shared source libraries; mixed libraries single-source the pure
substrate and retain only host-effecting operations as primitives; the
parallel-update obligation applies to the irreducible reader/evaluator/macro,
base-primitive, and host-FFI layer.

This parity rule is no longer enforced by prose and reviewer diligence alone.
The `test-parity` gate (`make test-parity`, the `test-parity` CI job; #374) runs
the shared fixture corpus through both in-repo cores and fails on any result
divergence. Its scope is the irreducible dual core — the layers each host must
implement in its own language — so it explicitly excludes cases whose source
imports a library that is single-sourced from a portable `.sld` and loaded by
both bootstraps: such a library is one implementation, not two, and cannot
diverge from itself. The exclusion is keyed off the manifest-backed
single-sourced library inventory, so a newly single-sourced library drops out of
parity scope automatically as that migration proceeds.

### Inspectable Memory

Agent memory must always be inspectable as Lisp/Scheme data. Vector indexes,
search caches, database tables, embeddings, and host-side acceleration
structures are implementation caches over canonical Scheme-readable datums, not
the source of truth.

Canonical memory records should be ordinary datums, for example:

```scheme
(memory
  (id m-42)
  (scope project)
  (kind fact)
  (tags (architecture r7rs host-boundary))
  (value "Emacs is the first host adapter, not the semantic center.")
  (source (issue tahoma/consent 1))
  (confidence high))
```

Required scopes:

- `instance`: durable local/private memory across projects
- `session`: memory tied to a named agent REPL or conversation session
- `project`: memory tied to a `project.el` root, with safe defaults for public
  repositories

Project memory defaults to private local storage owned by the host adapter,
not to a tracked repository file. A project may opt in to tracked memory later,
but tracked storage must be explicit and visibly separate from private local
storage so public repositories do not accidentally capture personal memory.
Any tracked or indexed form remains a rebuildable view over canonical
Scheme-readable memory records.

### Agent-Layer Determinism and Cross-Host Parity

The First-Class Portable Scheme parity invariant above is a property of the
language core. **D7** extends it to the agent layer: the deterministic control
loop, its receipts, scoped memory, transcripts, skills, and any future search
records must be as reproducible and cross-host-identical as the reader and
evaluator already are. This decision is ratified by the agent-layer stance RFC
(#561); its rationale is the agentic prior-art synthesis
([§4](agentic-harness-ideas.md#4-design-tensions-to-decide-deliberately)), and
it constrains the Scheme-readable record design that the
[Task Lifecycle and Control Loop](control-loop.md) and #286 implement. The
remaining cross-cutting decisions, **D5** (tree search and backtracking) and
**D6** (autonomy locus), are recorded in that control-loop document.

*Field default:* agent results are means over noisy runs on one implementation;
learning lives in opaque weights; retrieval lives in an opaque vector database;
records are stamped with wall-clock time. Nondeterminism is pervasive and is
reported as a statistic.

*Consent choice:* nondeterminism is quarantined and bounded so the agent layer
is replayable and parity-checkable:

- **Model output is the only nondeterministic channel,** and it is recorded as
  fixed input on resync. A replay re-runs the deterministic loop over the
  recorded model output; it does not re-sample the model.
- **Agent records use logical clocks, not wall-clock time.** Ordering and
  recency are appended events on the loop's monotonic counter, so a record
  stream is identical regardless of when or how fast it ran.
- **Embeddings and other host acceleration structures are untrusted advisory
  caches** over the canonical content-addressed store, never the source of
  truth, consistent with [Inspectable Memory](#inspectable-memory). If
  embeddings are ever used, any ranking they inform is rebuildable from the
  canonical datums, and a parity run cannot depend on them.
- **Live browsing and other external observation lower to snapshotted evidence
  datums,** with the network capability an explicit grant, so a replayed run
  sees the recorded snapshot rather than a fresh fetch.
- **Learning lives in append-only memory and content-addressed skills, never in
  weights.** A learned skill must hash and behave byte-identically on both
  cores.
- **Anything that hashes or behaves differently across the two cores is a
  parity defect to fix at root,** not a variance to average away. The
  `test-parity` gate (#374) is the mechanism; the agent-layer corpora extend it.
  This is also the mechanical counterpart to the field's manual agreement
  checks, such as GAIA's two-annotator agreement and tau-bench's task-uniqueness
  check.

## Runtime Shape

For a visual overview of the current portable Scheme core, Emacs Lisp twin,
evaluation pipeline, host boundary, bootstrap hooks, and parity matrix, see
[Runtime Core Diagrams](runtime-core-diagrams.md).

The runtime has three layers.

### Language Core

The language core owns R7RS data and evaluation:

- lexical reader and datum validator
- writer and stable result rendering
- explicit lexical environments
- proper-tail-recursive evaluator
- primitive procedure registry
- hygienic `syntax-rules` expansion
- `define-syntax`, `let-syntax`, `letrec-syntax`, and `define-library`
- R7RS standard libraries and conformance fixtures

Macros and libraries are first-class requirements. They are not optional polish
after a loose evaluator exists.

#### Portable symbol ownership

User-visible symbols are opaque Consent values, not host Scheme or Emacs Lisp
symbols. `(consent symbol)` interns immutable names through an explicit table
handle. Portable tables stage changes in `(data transient-map)` and materialize
checkpoint-visible persistent `(data avl-tree)` roots. The Emacs bootstrap
carries the same table/root lifecycle through dedicated handle and snapshot
records over its hash-backed adapter. Creating or installing an Emacs root
copies the hash index while sharing inherited owned-symbol records, so forks
preserve inherited identity, later insertions remain branch-local, and root
installation can commit or discard a branch without replacing the context's
table handle. This host adapter uses linear-time snapshots rather than
duplicating the portable AVL implementation.

The portable implementation is the native-compiler destination, not merely a
cross-host reference model. A native Consent image links `(consent symbol)` and
its portable data-structure dependencies directly and uses that table as its
only interning authority. Compiler backends may optimize the representation,
but may not introduce a second backend-owned symbol table or alter table-root,
budget, identity, or checkpoint semantics.

Evaluation contexts are created before source is read and carry their table
through ordinary, incremental, recovery, program-input, include, load, and
source-library reader paths. Reader literals, evaluated `string->symbol`, and
macro-introduced quoted symbols therefore share identity when they share a
context. Same-name symbols from isolated roots remain equivalent under `eq?`,
`eqv?`, `equal?`, and `symbol=?`, which keeps future checkpoint and transport
boundaries deterministic.

Host-native symbols remain private bootstrap, dispatch, or adapter metadata.
The runtime-only `(consent symbol-boundary)` library lets the evaluator,
reader, macro expander, and library loader recognize that exceptional mixed
metadata while bootstrapping; ordinary libraries never import it. Language
predicates never accept host values as Consent symbols. Writers render owned
names directly with the R7RS identifier escaping rules rather than
round-tripping through host symbol identity.

Shared libraries import `(scheme base)` unchanged. If a borrowed R7RS compiler
also runs one natively as an internal backend, the runtime's native-call bridge
recursively marshals owned symbols to ordinary host symbols on arguments and
on callback results the native library consumes. It recursively interns host
symbols in the active evaluation context on native results and callback
arguments. Opaque host controls such as `call-with-input-file` preserve a
callback's result until the single outer result barrier instead of converting
the same graph out and back. The compiled library therefore uses only its
host's ordinary `(scheme base)` procedures and has no knowledge of Consent's
symbol representation. On that borrowed host, the central runtime barrier also
marshals result datums consumed directly by compiled CLI or adapter code whose
`(scheme base)` is still the host implementation. That egress walks proper-list
spines iteratively so large audit and result streams remain linear rather than
turning ancestor-based cycle checks into a quadratic hot path.
Reader-owned forms remain opaque until they enter evaluation, and any result
that re-enters Consent is interned into the active context rather than becoming
a second language-visible symbol domain.

That bridge belongs only to a borrowed R7RS host ABI. Calls between libraries
compiled for a native Consent runtime use Consent values directly, so no
host-symbol representation or conversion participates. Foreign symbols exist
only at actual FFI or bootstrap edges and are interned into the active Consent
table before entering language-visible data.

#### Portable numeric ownership

Language-visible numbers are Consent-owned values. The portable R7RS runtime
implements sign-and-limb exact integers, normalized rationals, deterministic
binary64 tuples, canonical infinities and NaN, and rectangular complex pairs.
Its exact arithmetic, finite arithmetic, mixed-exactness comparison, conversion,
and rendering are owned algorithms. The Emacs bootstrap retains host integers
and floats behind its private implementation seam, while transcendental host
math remains a normalized, parity-tested accelerator through the
compiled-runtime ABI milestone.

The full representation, operation, host-dependency, ABI, allocation, and
conformance contract is recorded in
[Self-Hostable Numeric Backend](numeric-backend.md). Compiler and collector work
may optimize its physical layout but may not redefine its equality, exactness,
special-value, or external-rendering semantics.

### Host Adapter

The host adapter owns effects outside pure Scheme:

- opaque handles for live objects
- Emacs buffer, window, project, documentation, search, diff, diagnostics, VCS,
  compile, command, and process capabilities
- policy checks and audit records
- user confirmation and approval buffers
- local persistence and ignored state
- MCP tool registration and response transport

Scheme programs should never receive raw Emacs objects. They receive printable
opaque handles that are useful only when passed back to registered capabilities.

### Agent Layer

The agent layer provides self-scripting facilities as Scheme-readable data:

- `(agent io)` event channel
- `(agent task)` task lifecycle records and state transitions
- `(agent registry)` agent abstraction, registry, and automatic selection,
  described in [Task Lifecycle and Control Loop](control-loop.md)
- `(agent memory)` scoped memory
- `(agent plan)` plans
- `(agent helper)` helper libraries and artifacts
- `(agent test)` helper and skill self-test result datums
- `(agent approval)` approval requests
- `(agent job)` long-running work, cancellation, and streaming yields
- `(agent debugger)` condition, stack, environment, and restart datums
- `(agent reflect)` runtime reflection
- `(agent context)` request and project context
- `(agent rules)` behavior rules
- `(agent patterns)` reusable workflow patterns
- skill import/export and native skill manifests
- replayable transcripts and helper libraries, described in
  [Replayable Transcripts](transcripts.md)

This layer should be usable from a shared REPL by both the user and the outer
agent loop.

Runtime-visible documentation metadata follows the R7RS-compatible body literal
convention in [Docstring Metadata Convention](docstring-metadata.md). Comments
remain source-only contributor notes, while docstring metadata is intended to
survive as Scheme-readable data for reflection, logs, yields, static reference
generation, and future compiled runtimes.

The task-level state machine, control-loop semantics, pause and stop receipts,
provider interaction points, and minimal executable slice are defined in
[Task Lifecycle and Control Loop](control-loop.md).

Scheme programs that need to adapt to optional libraries or host adapters
should use the reflection ladder documented in
[Feature and Host Reflection](feature-reflection.md): R7RS `cond-expand` with
`(library ...)` for static library selection, `(features)` for
implementation-level language features, and structured `host-adapter` and
`host-capability` datums for runtime host inspection.

## Pass-Oriented Frontend and Backends

Consent Scheme should have one shared frontend for reading, resolving libraries,
expanding macros, and normalizing Scheme programs. Interpreters, native
compilers, and Emacs Lisp or byte-code backends consume that shared frontend
output instead of reimplementing reader, library, or macro behavior.

The intended pipeline is:

```text
source -> datums -> expanded Scheme -> normalized core form or IR -> backend
```

Library resolution participates in the frontend before and during expansion,
because imports install both value bindings and syntactic bindings. Frontend
passes may carry syntax environments, source locations, policy requirements,
and binding metadata as pass state, but pass outputs that cross a module or
backend boundary should remain Scheme-readable or printable where practical.

### Frontend Pass Boundaries

The reader and datum validator turn source text into Consent Scheme datums. This
pass owns lexical grammar, datum labels, abbreviation syntax, numeric and
character external representations, and depth, node, and string-size limits. It
does not resolve identifiers, run macros, import libraries, or perform host
effects.

The program and library-shape pass checks that datums form legal program or
`define-library` units. It separates import declarations, export declarations,
body forms, definitions, and expressions; enforces top-level ordering such as
imports before body forms; and preserves enough source context for diagnostics
and later debugging.

The library resolver maps R7RS library names and import sets to value and syntax
bindings. It owns `only`, `except`, `prefix`, `rename`, `cond-expand`,
`include`, `include-ci`, and `include-library-declarations` decisions. Source
inclusion is a host file observation, so it must lower to a policy-checked
frontend request rather than silently reading arbitrary host files.

The macro expander owns `syntax-rules`, `define-syntax`, `let-syntax`,
`letrec-syntax`, hygiene, expansion-time `syntax-error`, and derived syntax
lowering that is implemented through portable macro libraries. Its output is
expanded Scheme that uses a small set of core syntactic forms plus explicit
syntax or binding metadata when needed. It may evaluate transformer code in a
restricted expansion environment, but it must not call backend-specific runtime
shortcuts.

The normalizer turns expanded Scheme into a target-independent core form or IR.
The first representation can stay close to Scheme datums, but it should make the
remaining semantic cases explicit enough for all backends: literal data,
lexical references and binding sites, assignments, sequences, conditionals,
closures, applications, multiple-value contexts, dynamic-wind boundaries,
continuation-sensitive calls, and policy-visible capability requests. The
normalizer preserves tail-position metadata and source context so every backend
can honor proper tail recursion and produce useful diagnostics.

### Backend Boundaries

The interpreter backend consumes normalized core forms and runs them directly.
It owns runtime environments, mutable cells, closure values, parameter state,
ports, multiple values, continuations, dynamic-wind state, exception handlers,
the trampoline or equivalent tail-call machinery, primitive application,
resource counters, and result rendering. The current evaluator is this first
backend, even though it still hosts several frontend responsibilities while the
runtime is bootstrapping.

Future native compiler backends consume the same normalized core form or IR and
emit executable code for a Scheme, byte-code, native, or other runtime target.
They may choose different calling conventions or storage layouts, but they must
preserve the R7RS-small contract, Consent Scheme policy behavior, inspectable
result records, and the shared library and macro semantics supplied by the
frontend.

Future Emacs Lisp or byte-code backends also consume the normalized core form or
IR. Generated Emacs Lisp remains an implementation detail behind
`consent-` APIs and must not expose raw Emacs objects as Scheme values. Any
compiled call that reaches Emacs buffers, files, processes, commands, or
windows goes through the same capability, policy, handle, and audit surfaces as
the interpreter backend.

Backend results should be comparable as Scheme-readable data. A backend may
keep private caches, byte-code objects, closure layouts, or indexes, but those
objects are rebuildable acceleration structures over canonical frontend output
and runtime records.

### Primitive and Effect Metadata

Primitive and standard-binding metadata is exposed through a shared manifest
surface instead of being inferred from host registration code alone. The current
bootstrap accessors are `consent-primitive-manifest-binding-specs`,
`consent-base-primitive-specs`, and
`consent-base-prelude-binding-specs`; the portable Scheme evaluator exposes
the same manifest records as Scheme-readable association lists.

Each manifest record identifies the public binding name, library, minimum and
maximum arity, source boundary, effect tier, required capability if any,
interpreter hook names, future emitter hint, policy posture, documentation
metadata, and test categories. The `source` field keeps kernel primitives,
portable prelude bindings, portable source libraries, and host capabilities
distinguishable. The `effect` and `policy` fields are advisory metadata today,
but they are the contract future policy checks, fixture selection,
documentation, and compiler lowering should consume. When a primitive manifest
covers a public primitive binding, it carries explicit public documentation
metadata. Runtime reflection can still derive fallback documentation from the
registered implementation procedure docstring for implementation-only or
generated primitive hooks, and marks that origin separately from body-literal
source docstrings.

Compiler backends should treat `emitter-hook` as a dispatch hint, not as an
authorization decision. Pure bindings can be inlined or emitted as ordinary
runtime calls when the backend knows their representation. Mutation, control,
port, and dynamic-state effects must lower through runtime helpers that preserve
Consent Scheme semantics. Host-capability effects such as file, process, time,
REPL, provider, UI, memory, and future Emacs capability operations must carry
the `backend-effect-path` value `shared-capability-request`, lower to
capability requests that consult policy, and produce audit records. No backend
may bypass policy by directly calling host APIs; unsupported compiled effects
must remain explicit unsupported-effect nodes or fail closed before touching
host state.

The detailed per-user, per-project, per-session, and per-task authority model is
defined in [Capability Environment and Effect Lowering](capability-environment.md).
That document records the Scheme-readable `capability-environment`,
`capability-request`, `capability-decision`, `capability-revocation`, and
`capability-audit` datums used to keep interpreter and compiler effect lowering
on the same policy path.

### Current Bootstrap Placement

The Emacs Lisp and portable Scheme evaluators use matching pass-boundary
modules while the bootstrap runtime grows. Future file splits should preserve
behavior and keep both implementations aligned while moving responsibilities to
more focused frontend, runtime, and backend modules:

- `consent-reader.el` and `(consent reader)` are frontend reader and
  datum-validation passes.
- Library registry, import-set resolution, `define-library`, `cond-expand`, and
  include handling in the evaluator belong to frontend library-resolution
  modules.
- `syntax-rules`, syntax environments, identifier hygiene,
  `consent-expand`, and `consent-expand-source` belong to frontend
  expansion modules.
- Recursive full expansion of core combinations is a frontend lowering step
  until it is replaced or followed by an explicit normalizer.
- Environment cells, the evaluator trampoline, procedure and primitive
  application, continuations, dynamic-wind, exception handlers, parameters,
  ports, budgets, and result records belong to the interpreter backend and
  shared runtime support.
- The `(scheme base)` primitive registry, portable base prelude discovery, and
  primitive manifest metadata live in `consent-base.el` so they can be
  inspected without loading an interpreter backend.
- Library records, source-library discovery, import-set resolution, includes,
  `cond-expand`, and `define-library` bootstrap support live in
  `consent-library.el`; evaluation of library bodies still calls into the
  current interpreter backend.
- Syntax environments, `syntax-rules` parsing and application, hygienic
  template expansion, and `consent-expand` entry points live in
  `consent-macro.el`.
- Evaluation, primitive implementations, procedure application, continuations,
  the trampoline, and Scheme-readable evaluation result records live in
  `consent-interpreter.el`; `consent-eval.el` remains the public
  orchestration entry point.
- Model provider registration, role routing, diagnostics, and the Emacs local
  OpenAI-compatible transport live in `consent-models.el`, with matching
  portable `(agent models)` registration and routing primitives in
  `scheme/consent/interpreter.sld`.
- Default-denied file, process, time, default-port, and host-capability
  primitives are backend-visible capability calls, but their authority decisions
  belong to policy and adapter modules rather than to portable frontend passes.

### Fixture Phases

Shared fixtures should be able to test every public pass boundary as it becomes
executable:

- `read` and `read-all` cover source-to-datum behavior.
- `expand` covers library resolution, macro expansion, and derived syntax
  lowering into expanded Scheme.
- A future `normalize` phase should cover expanded Scheme to core form or IR
  without running a backend.
- `eval` and `eval-result` cover the interpreter backend over the shared
  frontend and, once available, over the normalizer.
- Future `compile` and `compile-run` phases should verify compiler output shape
  and compiled execution against the same expected values, errors, and result
  records used by the interpreter.

Policy-gated fixtures for `include`, `load`, file, process, time, default-port,
and host-capability behavior should assert capability requests, denials, audit
records, or result datums. They must not depend on unapproved direct host
mutation. This keeps pass tests useful for the multi-host bootstrap strategy and
keeps the R7RS-small contract independent of any one backend.

## Evaluation Scopes

Consent Scheme has three evaluation scopes:

- Fresh evaluation: isolated one-off forms with no durable definitions, imports,
  macros, handles, or helper procedures after the evaluation returns.
- Named agent REPL session: a persistent environment with definitions, imports,
  macros, handles, helper procedures, recent events, and session memory.
- Project session: a named session associated with a `project.el` root, project
  policy, project memory, project helpers, and project trust state.

An agent and a user should be able to share a named REPL session. The user can
inspect imported libraries, definitions, recent yields, policy decisions,
memory, and pending approvals as Scheme data.

The concrete lifecycle, snapshot, fork, and cleanup contract is recorded in
[Session Lifecycle and Snapshots](session-lifecycle.md). The host-neutral
read-eval-render loop both hosts drive over a durable session is defined in the
[Cross-Host REPL Interaction Contract](repl-interaction-contract.md).

Reusable helper libraries, helper artifacts, skill candidate promotion, and
their storage and policy boundaries are recorded in
[Helper Libraries and Artifacts](helper-artifacts.md).

## Library Namespaces

R7RS standard libraries use R7RS names:

```scheme
(scheme base)
(scheme write)
(scheme read)
(scheme file)
```

Emacs capabilities live under explicit Emacs libraries:

```scheme
(emacs buffer)
(emacs buffer edit)
(emacs diff)
(emacs window)
(emacs command)
(emacs project)
```

Agent interaction libraries live under `agent`:

```scheme
(agent io)
(agent memory)
(agent helper)
(agent plan)
(agent approval)
(agent job)
(agent diff)
(agent debugger)
(agent reflect)
(agent context)
```

Agent-domain libraries are real public APIs, not veneers over private model
libraries. Their host-neutral records, stores, predicates, and pure
transformations live in the public `(agent <domain>)` source library. Host
effects for those domains are attached through internal primitive backing
libraries such as `(agent memory primitive)`. Backend model providers use the
separate `(agent models)` family: `(agent models)` is the public routing and
tool-protocol API, `(agent models <provider>)` names provider adapters, and
`(agent models primitive)` supplies host-owned routing or live transport effects.

Standard Scheme bindings, host capabilities, and agent interaction bindings
should remain discoverable as separate categories.

## Capability Tiers

Capabilities are grouped by authority. Defaults should be conservative.

| Tier | Examples | Default posture |
| --- | --- | --- |
| Pure R7RS evaluation | literals, variables, lambdas, macros, pure `(scheme base)` procedures | allowed with resource budgets |
| Read-only Emacs observation | current buffer handle, buffer name, buffer text range, project root, command docs | allowed or confirmation-gated by project trust |
| Transactional buffer/window mutation | insert, delete, replace, save, select window, split window | confirmation-gated or denied by default, and grant-scoped for registered mutating capabilities |
| Command/process capabilities | whitelisted commands, compile, recompile, process jobs | confirmation-gated and audited |
| Policy-gated standard host effects | `(scheme file)`, `(scheme load)`, `(scheme eval)`, process context | denied or confirmation-gated by default |
| Raw Emacs Lisp escape hatch | confirmed host eval | denied unless explicitly enabled and confirmed |

Every effectful capability should produce an audit record before or during the
operation, including the evaluated form, capability name, target handles or
files, policy decision, and result or error.

The Emacs adapter exposes the current bootstrap policy surface through
`consent-policy-category-actions`.  Each category maps to `allow`, `deny`,
or `confirm`; confirmation uses a host callback that denies in noninteractive
batch mode unless tests or callers install an explicit confirmation function.

| Policy category | Default | Notes |
| --- | --- | --- |
| `pure-r7rs` | `allow` | Ordinary Scheme evaluation remains available under resource budgets. |
| `emacs-read-only` | `allow` | Current buffer, buffer text, project root, documentation, and other observation capabilities are still audited. |
| `buffer-edit` | `confirm` | `(emacs buffer edit)` exposes `buffer-insert!`, `buffer-delete!`, `buffer-replace!`, and `buffer-save!`; each requires a matching capability grant and approval by default. |
| `vcs-mutation` | `confirm` | `(emacs vcs mutation)` exposes `vcs-stage!`, `vcs-unstage!`, `vcs-commit!`, `vcs-branch-create!`, `vcs-switch!`, `vcs-fetch!`, `vcs-pull!`, and `vcs-push!`; each call also requires a shared VCS grant or approval record before Git changes repository state or contacts a remote. Credentialed remote-looking input is rejected and represented only as redacted request data in adapter-owned VCS audit records. |
| `window-session` | `confirm` | `(emacs buffer)` and `(emacs window)` expose `buffer-switch!`, `window-select!`, `window-split!`, and safe `window-delete!`; mutating session capabilities require matching grants by default. |
| `command-process` | `confirm` | `(emacs command)` exposes `command-call!` for user-customizable whitelisted commands, and `(emacs project)` exposes compile helpers; direct shell/process launch remains out of scope unless a whitelisted capability and policy decision allow it. |
| `standard-host-effect` | `allow` | Host-effecting standard Scheme procedures still require their narrower path or session policy, such as `:file-paths`; without that grant they deny and audit. |
| `debugger-recovery` | `confirm` | Emacs debugger restarts that retry, provide a value, define a binding, or import a library require host policy before they mutate session state or retry work. |
| `raw-emacs-lisp` | `deny` | Raw host evaluation stays unavailable; no raw Emacs Lisp evaluation surface is registered. |
| `approval-resolution` | `deny` | Scheme code can create and observe approval records, but resolving approvals is host-side by default unless automation policy explicitly allows it. |
| `skill-discovery-activation` | `confirm` | Skill discovery and activation require an approval callback by default. |
| `project-skill-trust` | `deny` | Project-level skill trust starts denied for untrusted projects. |
| `skill-resource-read` | `confirm` | Skill resource reads require approval unless policy is relaxed. |
| `skill-script-execution` | `confirm` | Bundled script execution requires explicit approval. |
| `skill-export-write` | `confirm` | Skill export writes require explicit approval. |

Audit entries live in memory as Scheme-readable datums and can be inspected
through `consent-audit-recent-entries` or `consent-audit-display`.
`consent-audit-clear` clears the current log, and
`consent-audit-rotate` trims it to a chosen number of newest entries.  The
current audit implementation records evaluations, read-only and buffer-edit
capability calls and outcomes, capability grant creation/use/attenuation/
expiration/revocation, standard host-effect denials or grants, skill activation
decisions, trust decisions, resource/script/export policy stubs, and
confirmation outcomes.  Approval requests and user decisions are recorded as
`approval-request` and `approval-decision` audit events.
Portable Scheme now records standard host-file policy decisions in
`evaluation-result` event lists for its path allow-list gates.  Remaining
portable parity covers host-adapter-only surfaces such as Emacs capabilities,
Agent Skills interop, and `(agent io)` session storage.

## Capability Grants

The `(consent capability)` library represents authority as Scheme-readable grant
datums. Policy still decides whether authority may exist; a grant describes how
little of that approved authority is usable by one capability call.

Region-limited edit grant:

```scheme
(capability-grant
  (id region-edit)
  (library (emacs buffer edit))
  (effect buffer-replace!)
  (scope (buffer (handle buffer h-12)) (range 120 140))
  (expires after-eval)
  (reason "Apply approved region edit."))
```

Skill-limited grant request, as declared by an imported skill without receiving
authority automatically:

```scheme
(requested-grants
  ((capability-grant
     (library (emacs buffer edit))
     (effect buffer-replace!)
     (scope (skill refactor-helper) (range 120 140))
     (expires after-eval))))
```

Grant operations include `grant-capability!`, `current-grants`, `grant-ref`,
`grant-attenuate`, `grant-revoke!`, and `with-capability-grant`. Grants can be
attenuated by operation, resource, range, session lifetime, use count, and skill
identity. Stale handles, revoked grants, expired grants, or mismatched scopes
fail closed with an Consent Scheme capability grant condition before the host
mutation runs.

## Approval Records

The `(agent approval)` library lets Scheme programs ask the host or user to
approve a proposed effect without performing that effect directly.  Requests are
ordinary Scheme-readable datums:

```scheme
(approval-request
  (id a-17)
  (policy buffer-edit)
  (effect (buffer-replace! h-12 120 140 "new text"))
  (diff (diff
          (source buffer)
          (old-label "before")
          (new-label "after")
          (status changed)
          (hunks
           ((hunk
             (old-start 120)
             (old-count 1)
             (new-start 120)
             (new-count 1)
             (lines ((line remove "old text")
                     (line add "new text"))))))))
  (reason "Replace deprecated helper name?")
  (status pending))
```

User code creates records with `approval-request!`, observes the current
decision with `approval-status`, cancels its own pending requests with
`approval-cancel!`, and can yield pending records with
`approval-yield-pending`.  The host-side `approval-resolve!` path is denied to
Scheme code by default through the `approval-resolution` policy category, so an
agent cannot approve its own restricted buffer, file, process, or UI mutation
unless the host explicitly grants an automation policy.

The Emacs adapter renders session approval records in
`*Consent Approvals: PROJECT*` as the same datums.  Confirmation-gated policy
calls, such as buffer edits, create approval records automatically before the
confirmation function runs, then resolve those records to `approved` or
`denied` and write the decision to the audit log.

Diffs deliberately straddle the portable/adapter boundary.  `(agent diff)`
owns the canonical `diff`, `hunk`, and `line` datum shape, proposed-edit
preview construction, `diff-render-unified`, and `diff-yield`.  `(emacs diff)`
is the first adapter library that produces those datums from live editor state
with procedures such as `buffer-diff`, `file-diff`, and `project-diff`.  Other
hosts should produce the same portable record shape instead of inventing a
host-specific diff model.

Diagnostics follow the same layered shape. `(agent diagnostics)` owns
canonical `diagnostic`, `diagnostic-range`, `diagnostics-snapshot`,
request/result, outcome, and `diagnostics-yield` datums for any host adapter.
`(emacs diagnostics)` is the first adapter library and maps Flymake, Flycheck,
and Eglot-backed state into those records with read-only procedures such as
`buffer-diagnostics`, `project-diagnostics`, and `diagnostic-at`. Code actions
and fixes remain outside this read-only diagnostics contract and must use a
separate mutating capability if they are exposed later.

The shared VCS contract is recorded in
[Shared VCS Capability Contract](vcs-capability.md). `(agent vcs)` owns
repository, branch, status-entry, conflict, diff-summary, request/result, and
outcome datums plus pure Git machine-format parsers. Host adapters obtain VCS
state through local tools, editor APIs, or native services, but Scheme-visible
values remain host-neutral records and repository mutation remains a separate
policy-gated capability family. `(emacs vcs)` is the first read-only adapter
surface over that contract, with procedures such as `vcs-root`, `vcs-branch`,
`vcs-status`, `vcs-diff`, `vcs-recent-commits`, and `vcs-yield`; it does not
export stage, commit, branch creation, fetch, pull, push, or other mutating
repository operations. `(emacs vcs mutation)` is the separate Emacs mutation
surface for policy-gated repository changes and remote intents.

## Threat Model

Consent Scheme should assume that evaluated code, imported skills, project files,
and model-authored helper scripts can be wrong or adversarial.

Primary risks:

- resource exhaustion through deep datums, huge strings, runaway recursion,
  infinite streams, or excessive host calls
- accidental or malicious mutation of buffers, files, windows, sessions, memory,
  or project state
- secret exposure through variables, buffers, environment, files, provider
  credentials, audit logs, memory, transcripts, or protocol payloads
- capability confusion where a portable library silently gains host authority
- raw Emacs object leakage into Scheme values
- stale handles to buffers, windows, processes, or projects that no longer exist
- untrusted project skills or helper scripts executing bundled code
- protocol-boundary confusion where JSON, Markdown, HTTP, or MCP data is treated
  as canonical trusted runtime state

Mitigations:

- parse Scheme syntax with an Consent Scheme reader, not Emacs `read`
- validate datums for maximum depth, length, scalar type, string size, and total
  node count before evaluation
- preserve proper tail recursion while still enforcing evaluation budgets
  (steps, host callbacks, events, allocation, output, and opt-in wall time),
  reported through a single inspectable ledger with an explicit exhaustion
  reason — see [budgets.md](budgets.md)
- make all host authority explicit through capability libraries
- use opaque handles for host objects
- gate effectful capabilities through policy and approvals
- record audit entries as Scheme-readable datums
- redact secrets before data enters memory, logs, transcripts, or protocol
  payloads
- keep project-level skills hidden, denied, or approval-gated until the project
  is trusted
- make caches rebuildable from canonical datums

## Event Channel

`agent-yield` is the primary mechanism for Scheme scripts to pass structured
observations back to the outer agent loop. It is for useful data, not only text.

Core event procedures:

```scheme
(agent-yield datum)
(agent-log level message . fields)
(agent-progress phase datum)
(agent-warn message . fields)
(agent-request request-datum)
```

Example events:

```scheme
(yield
  (kind candidate-helper)
  (name summarize-bindings)
  (value (lambda (env) ...)))

(request
  (kind approval)
  (policy buffer-edit)
  (effect (buffer-replace! h-17 120 140 "consent-read"))
  (reason "Replace old public entry point"))

(warn
  (kind stale-handle)
  (handle h-17)
  (message "Buffer was killed before edit"))
```

The outer agent loop, native REPL buffers, audit buffers, and MCP responses
should preserve event records as Scheme-readable data.  The current Emacs
bootstrap registers `(agent io)` and records emitted events as `context-event`
audit datums.  The `(agent job)` layer streams those same event records from
running jobs before the final evaluation result is available.

## Policy for Standard Libraries

Pure standard-library procedures can be available in ordinary R7RS evaluation.
Host-effecting standard libraries require a policy bridge:

- `(scheme file)`: file reads/writes must respect project trust, path policy,
  remote-file policy, and approval rules.
- `(scheme load)`: loading code must validate source, trust, and scope before
  extending an environment.
- `(scheme eval)`: dynamic evaluation must inherit the current scope and budget
  and must not bypass policy.
- `(scheme process-context)`: environment variables, command line, and exit
  behavior require redaction and host policy.
- `(scheme read)` and `(scheme write)`: reading and writing from host ports must
  obey port capability and size limits.

The same policy function should serve local REPL use, project sessions, skills,
and MCP-triggered evaluation.

## Base Library Kernel and Prelude

The initial `(scheme base)` environment is assembled in two phases:

1. install a small evaluator kernel of host primitives
2. evaluate the portable prelude in
   `scheme/consent/base-prelude.scm` into that environment

Kernel primitives are reserved for bindings that cannot yet be expressed
portably inside the bootstrap evaluator: primitive expression and application
mechanics, mutable storage representation hooks, identity-sensitive predicates,
low-level numeric and scalar representation operations, collection
constructors/accessors/mutators, control features when they land, and
policy-gated host effects. Derived helpers such as composed accessors, list
traversals, convenience numeric predicates, and higher-order iteration should
live in the prelude once they can be written using the available kernel.

Primitive discovery should preserve this boundary. Kernel bindings and
prelude-defined bindings are both discoverable, but their metadata identifies
which source installed each binding so later conformance work can reduce the
host surface without losing visibility into the supported base environment.

Portable source for pure, non-base R7RS-small standard libraries lives beside
the rest of the R7RS-small implementation under `scheme/consent/`, using one
`.sld` file per library. For example, `(scheme case-lambda)` lives in
`scheme/consent/case-lambda.sld`. Both the Emacs Lisp bootstrap
evaluator and the portable Scheme evaluator load those checked-in source files
directly as implementation bootstrap data; this is separate from user-level
`include` and `load`, which remain policy-gated host file access.
Host-effecting standard libraries continue to be registered through explicit
adapter or primitive policy surfaces instead of portable source files.

Optional SRFI and R7RS-large libraries belong under `scheme/stdlib/`,
with primary names in the `(stdlib *)` namespace. The Scheme-readable
`(stdlib manifest)` library records source URLs, upstream revisions, licenses,
aliases, dependencies, test status, and local patches for this optional layer;
SRFI, R7RS-large, and historical Consent names are public import compatibility
and metadata, not filesystem ownership.

## Agent Skills Interop

The ecosystem Agent Skills directory format is the public interchange format.
Consent Scheme imports skills into Scheme-readable datums for runtime use.

Package surfaces:

- `SKILL.md`: portable Markdown instruction surface for the broader ecosystem
- `SKILL.scm`: optional Consent Scheme-native manifest and helper library surface

Import/export expectations:

- `import-agent-skill` reads a skill directory, applies progressive disclosure,
  validates trusted files, and returns a normalized skill datum.
- `export-agent-skill` writes a dual-mode skill package from canonical datums
  only after policy approval.
- Native manifests can reference examples, tests, assets, helper libraries, and
  required rules as data.
- Round-trip validation should prove that importing an exported skill preserves
  the intended manifest and portable instruction surface.

Example normalized record:

```scheme
(agent-skill
  (name "scheme-reader")
  (source (directory "skills/scheme-reader"))
  (trust project-approved)
  (instructions (markdown-resource "SKILL.md"))
  (native-manifest "SKILL.scm")
  (resources ((examples "examples/reader.scm")))
  (rules (r7rs-first public-repo-safety)))
```

## Public Entry Points and Names

Durable Consent Scheme identifiers use the project namespace documented in
[Naming Convention](naming.md). Public Emacs Lisp commands, functions,
variables, customization options, faces, modes, hooks, and module entry points
use `consent-`. Private Emacs Lisp internals use `consent--`.

Initial public entry points should include:

- `consent-read`
- `consent-eval`
- `consent-describe-environment`
- `consent-start-repl`
- `consent-mcp-start`
- `consent-mcp-stop`
- `consent-mcp-register-tools`
- `consent-mcp-unregister-tools`

Compatibility aliases may exist during migrations from shipped names, but they
must be documented as temporary and must not appear as the preferred names in new
Consent Scheme docs, tests, examples, or issue plans.

## Emacs and MCP Integration

Consent Scheme should keep local agent UX and MCP wiring in separable modules with
clear responsibilities:

- local agent UX loads the REPL, session, policy, audit, memory, and capability
  buffers
- MCP wiring registers Consent Scheme tools only after the reader, evaluator,
  library system, policy layer, sessions, and event channel are available
- MCP payloads preserve Scheme-readable result and event datums inside the
  protocol response
- `consent-mcp-start` and `consent-mcp-stop` should expose the
  user-facing integration lifecycle
- `consent-mcp-register-tools` and
  `consent-mcp-unregister-tools` should not disturb unrelated Emacs MCP
  tools

MCP exposure should come after local evaluation, policy, session UX, and
`agent-yield` are coherent.

## Initial Module and Test Map

Later tickets should use focused modules rather than one large host file.
Portable R7RS core modules live under `scheme/`, with Emacs Lisp bootstrap and
host adapter modules under `lisp/`. Scheme modules should be usable by another
R7RS implementation while Consent Scheme is still self-bootstrapping; Emacs Lisp
modules own Emacs integration and must stay aligned with the portable core
where they implement shared language behavior.

Likely portable R7RS modules:

- `scheme/consent/reader.sld`
- `scheme/consent/numeric.sld`
- `scheme/consent/runtime.sld`
- `scheme/consent/base.sld`
- `scheme/consent/datum.sld`
- `scheme/consent/frontend.sld`
- `scheme/consent/library.sld`
- `scheme/consent/macro.sld`
- `scheme/consent/normalize.sld`
- `scheme/consent/interpreter.sld`
- `scheme/consent/eval.sld`
- `scheme/consent/write.sld`
- `scheme/consent/approval.sld`
- `scheme/consent/result.sld`

Likely Emacs Lisp bootstrap and adapter modules:

- `lisp/consent-reader.el`
- `lisp/consent-runtime.el`
- `lisp/consent-result.el`
- `lisp/consent-datum.el`
- `lisp/consent-library.el`
- `lisp/consent-macro.el`
- `lisp/consent-normalize.el`
- `lisp/consent-interpreter.el`
- `lisp/consent-eval.el`
- `lisp/consent-env.el`
- `lisp/consent-base.el`
- `lisp/consent-write.el`
- `lisp/consent-compile.el`
- `lisp/consent-bytecode.el`
- `lisp/consent-policy.el`
- `lisp/consent-approval.el`
- `lisp/consent-debugger.el`
- `lisp/consent-diagnostics.el`
- `lisp/consent-diff.el`
- `lisp/consent-audit.el`
- `lisp/consent-agent-io.el`
- `lisp/consent-handle.el`
- `lisp/consent-capability.el`
- `lisp/consent-models.el`
- `lisp/consent-repl.el`
- `lisp/consent-transcript.el`
- `lisp/consent-mcp.el`

After the split, `consent-eval.el` can remain the public orchestration
surface for reading, expanding, normalizing, and invoking the default backend,
while focused frontend and backend modules own the underlying pass behavior.

Focused test files should mirror the modules:

- `tests/consent-reader-test.el`
- `tests/consent-runtime-test.el`
- `tests/consent-result-test.el`
- `tests/consent-library-test.el`
- `tests/consent-library-module-test.el`
- `tests/consent-macro-test.el`
- `tests/consent-macro-module-test.el`
- `tests/consent-normalize-test.el`
- `tests/consent-eval-test.el`
- `tests/consent-base-test.el`
- `tests/consent-base-module-test.el`
- `tests/consent-interpreter-test.el`
- `tests/consent-interpreter-module-test.el`
- `tests/consent-compile-test.el`
- `tests/consent-policy-test.el`
- `tests/consent-approval-test.el`
- `tests/consent-diagnostics-test.el`
- `tests/consent-diff-test.el`
- `tests/consent-capability-test.el`
- `tests/consent-repl-test.el`
- `tests/consent-mcp-test.el`

The early conformance fixture suite belongs with issue tahoma/consent#12
and should be usable before the whole runtime is complete.

## Roadmap Alignment

The implementation order belongs in [Roadmap](roadmap.md), with
tahoma/consent#53 as the living dependency graph. Roadmap updates should
preserve this architecture's distinction between portable Scheme semantics and
explicit host authority.
