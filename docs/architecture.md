# Agent Scheme Architecture and Threat Model

Agent Scheme is an R7RS-small guest runtime for agentic scripting. Its first
host is Emacs, but Emacs is an adapter around the language, not the language's
semantic center.

The core promise is:

- standard Scheme inside a sandbox
- explicit host capabilities at the boundary
- inspectable Scheme-readable data for agent state
- ecosystem compatibility through Agent Skills packages

The old working name "Agent Lisp" should be treated as historical. Durable
project APIs, docs, tests, and examples should use "Agent Scheme".

## Design Rules

### R7RS First

Agent Scheme targets R7RS-small compliance rather than a Scheme-flavored Lisp
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

Internal Agent Scheme APIs should think in Lisp and Scheme terms first. Prefer
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

The initial implementation may be hosted in Emacs Lisp while the project is
bootstrapping, but modules should keep the following boundary clear:

- portable core: reader, datums, evaluator, macro expander, libraries, writer,
  conformance fixtures, and portable agent libraries
- host adapter: Emacs handles, buffers, windows, commands, policies, UI,
  process launch, local files, persistence, and MCP registration

Future hosts should be able to reuse the core data model and libraries without
pretending to be Emacs.

The detailed multi-host adapter and bootstrap stance is recorded in
[Multi-Host Adapter and Bootstrap Strategy](multi-host-bootstrap.md). New host
or backend work should preserve that document's R7RS-small contract, portable
test path, and Scheme-readable adapter boundary.

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
  (source (issue tahoma/agent-scheme 1))
  (confidence high))
```

Required scopes:

- `instance`: durable local/private memory across projects
- `session`: memory tied to a named agent REPL or conversation session
- `project`: memory tied to a `project.el` root, with safe defaults for public
  repositories

## Runtime Shape

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
- `(agent memory)` scoped memory
- `(agent plan)` plans
- `(agent approval)` approval requests
- `(agent reflect)` runtime reflection
- `(agent context)` request and project context
- `(agent rules)` behavior rules
- `(agent patterns)` reusable workflow patterns
- skill import/export and native skill manifests
- replayable transcripts and helper libraries

This layer should be usable from a shared REPL by both the user and the outer
agent loop.

## Pass-Oriented Frontend and Backends

Agent Scheme should have one shared frontend for reading, resolving libraries,
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

The reader and datum validator turn source text into Agent Scheme datums. This
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
preserve the R7RS-small contract, Agent Scheme policy behavior, inspectable
result records, and the shared library and macro semantics supplied by the
frontend.

Future Emacs Lisp or byte-code backends also consume the normalized core form or
IR. Generated Emacs Lisp remains an implementation detail behind
`agent-scheme-` APIs and must not expose raw Emacs objects as Scheme values. Any
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
bootstrap accessors are `agent-scheme-primitive-manifest-binding-specs`,
`agent-scheme-base-primitive-specs`, and
`agent-scheme-base-prelude-binding-specs`; the portable Scheme evaluator exposes
the same manifest records as Scheme-readable association lists.

Each manifest record identifies the public binding name, library, minimum and
maximum arity, source boundary, effect tier, required capability if any,
interpreter hook names, future emitter hint, policy posture, and test
categories. The `source` field keeps kernel primitives, portable prelude
bindings, portable source libraries, and host capabilities distinguishable.
The `effect` and `policy` fields are advisory metadata today, but they are the
contract future policy checks, fixture selection, documentation, and compiler
lowering should consume.

Compiler backends should treat `emitter-hook` as a dispatch hint, not as an
authorization decision. Pure bindings can be inlined or emitted as ordinary
runtime calls when the backend knows their representation. Mutation, control,
port, and dynamic-state effects must lower through runtime helpers that preserve
Agent Scheme semantics. Host-capability effects such as file, process, time,
REPL, provider, UI, and future Emacs capability operations must lower to
capability requests that consult policy and produce audit records; a compiler
must not bypass the manifest by directly calling host APIs.

### Current Bootstrap Placement

The current Emacs Lisp and portable Scheme evaluators intentionally mix
frontend and interpreter-backend code in one bootstrap module. Future file
splits should preserve behavior while moving responsibilities to pass-oriented
modules:

- `agent-scheme-reader.el` and `(agent-scheme reader)` are frontend reader and
  datum-validation passes.
- Library registry, import-set resolution, `define-library`, `cond-expand`, and
  include handling in the evaluator belong to frontend library-resolution
  modules.
- `syntax-rules`, syntax environments, identifier hygiene,
  `agent-scheme-expand`, and `agent-scheme-expand-source` belong to frontend
  expansion modules.
- Recursive full expansion of core combinations is a frontend lowering step
  until it is replaced or followed by an explicit normalizer.
- Environment cells, the evaluator trampoline, procedure and primitive
  application, continuations, dynamic-wind, exception handlers, parameters,
  ports, budgets, and result records belong to the interpreter backend and
  shared runtime support.
- The `(scheme base)` primitive registry, portable base prelude discovery, and
  primitive manifest metadata live in `agent-scheme-base.el` so they can be
  inspected without loading an interpreter backend.
- Library records, source-library discovery, import-set resolution, includes,
  `cond-expand`, and `define-library` bootstrap support live in
  `agent-scheme-library.el`; evaluation of library bodies still calls into the
  current interpreter backend.
- Syntax environments, `syntax-rules` parsing and application, hygienic
  template expansion, and `agent-scheme-expand` entry points live in
  `agent-scheme-macro.el`.
- Evaluation, primitive implementations, procedure application, continuations,
  the trampoline, and Scheme-readable evaluation result records live in
  `agent-scheme-interpreter.el`; `agent-scheme-eval.el` remains the public
  orchestration entry point.
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

Agent Scheme has three evaluation scopes:

- Fresh evaluation: isolated one-off forms with no durable definitions, imports,
  macros, handles, or helper procedures after the evaluation returns.
- Named agent REPL session: a persistent environment with definitions, imports,
  macros, handles, helper procedures, recent events, and session memory.
- Project session: a named session associated with a `project.el` root, project
  policy, project memory, project helpers, and project trust state.

An agent and a user should be able to share a named REPL session. The user can
inspect imported libraries, definitions, recent yields, policy decisions,
memory, and pending approvals as Scheme data.

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
(emacs window)
(emacs command)
(emacs project)
```

Agent interaction libraries live under `agent`:

```scheme
(agent io)
(agent memory)
(agent plan)
(agent approval)
(agent reflect)
(agent context)
```

Standard Scheme bindings, host capabilities, and agent interaction bindings
should remain discoverable as separate categories.

## Capability Tiers

Capabilities are grouped by authority. Defaults should be conservative.

| Tier | Examples | Default posture |
| --- | --- | --- |
| Pure R7RS evaluation | literals, variables, lambdas, macros, pure `(scheme base)` procedures | allowed with resource budgets |
| Read-only Emacs observation | current buffer handle, buffer name, buffer text range, project root, command docs | allowed or confirmation-gated by project trust |
| Transactional buffer/window mutation | insert, delete, replace, save, select window, split window | confirmation-gated or denied by default |
| Command/process capabilities | whitelisted commands, compile, recompile, process jobs | confirmation-gated and audited |
| Policy-gated standard host effects | `(scheme file)`, `(scheme load)`, `(scheme eval)`, process context | denied or confirmation-gated by default |
| Raw Emacs Lisp escape hatch | confirmed host eval | denied unless explicitly enabled and confirmed |

Every effectful capability should produce an audit record before or during the
operation, including the evaluated form, capability name, target handles or
files, policy decision, and result or error.

## Threat Model

Agent Scheme should assume that evaluated code, imported skills, project files,
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

- parse Scheme syntax with an Agent Scheme reader, not Emacs `read`
- validate datums for maximum depth, length, scalar type, string size, and total
  node count before evaluation
- preserve proper tail recursion while still enforcing evaluation budgets
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
  (effect (buffer-replace! h-17 120 140 "agent-scheme-read"))
  (reason "Replace old public entry point"))

(warn
  (kind stale-handle)
  (handle h-17)
  (message "Buffer was killed before edit"))
```

The outer agent loop, native REPL buffers, audit buffers, and MCP responses
should preserve event records as Scheme-readable data.

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
   `scheme/agent-scheme/base-prelude.scm` into that environment

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

Portable source for pure, non-base standard libraries belongs under
`scheme/standard-library/`, using one `.sld` file per R7RS library.  For
example, `(scheme case-lambda)` lives in
`scheme/standard-library/case-lambda.sld`.  Both the Emacs Lisp bootstrap
evaluator and the portable Scheme evaluator load those checked-in source files
directly as implementation bootstrap data; this is separate from user-level
`include` and `load`, which remain policy-gated host file access.
Host-effecting standard libraries continue to be registered through explicit
adapter or primitive policy surfaces instead of portable source files.

## Agent Skills Interop

The ecosystem Agent Skills directory format is the public interchange format.
Agent Scheme imports skills into Scheme-readable datums for runtime use.

Package surfaces:

- `SKILL.md`: portable Markdown instruction surface for the broader ecosystem
- `SKILL.scm`: optional Agent Scheme-native manifest and helper library surface

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

Durable Agent Scheme identifiers use the project namespace documented in
[Naming Convention](naming.md). Public Emacs Lisp commands, functions,
variables, customization options, faces, modes, hooks, and module entry points
use `agent-scheme-`. Private Emacs Lisp internals use `agent-scheme--`.

Initial public entry points should include:

- `agent-scheme-read`
- `agent-scheme-eval`
- `agent-scheme-describe-environment`
- `agent-scheme-start-repl`
- `agent-scheme-mcp-start`
- `agent-scheme-mcp-stop`
- `agent-scheme-mcp-register-tools`
- `agent-scheme-mcp-unregister-tools`

Compatibility aliases may exist during migrations from shipped names, but they
must be documented as temporary and must not appear as the preferred names in new
Agent Scheme docs, tests, examples, or issue plans.

## Emacs and MCP Integration

Agent Scheme should keep local agent UX and MCP wiring in separable modules with
clear responsibilities:

- local agent UX loads the REPL, session, policy, audit, memory, and capability
  buffers
- MCP wiring registers Agent Scheme tools only after the reader, evaluator,
  library system, policy layer, sessions, and event channel are available
- MCP payloads preserve Scheme-readable result and event datums inside the
  protocol response
- `agent-scheme-mcp-start` and `agent-scheme-mcp-stop` should expose the
  user-facing integration lifecycle
- `agent-scheme-mcp-register-tools` and
  `agent-scheme-mcp-unregister-tools` should not disturb unrelated Emacs MCP
  tools

MCP exposure should come after local evaluation, policy, session UX, and
`agent-yield` are coherent.

## Initial Module and Test Map

Later tickets should use focused modules rather than one large host file.
Portable R7RS core modules live under `scheme/`, with Emacs Lisp host adapters
and bootstrap mirrors under `lisp/`. Scheme modules should be usable by another
R7RS implementation while Agent Scheme is still self-bootstrapping; Emacs Lisp
modules own Emacs integration and may mirror core behavior until the portable
core can take over.

Likely portable R7RS modules:

- `scheme/agent-scheme/reader.sld`
- `scheme/agent-scheme/datum.sld`
- `scheme/agent-scheme/frontend.sld`
- `scheme/agent-scheme/library.sld`
- `scheme/agent-scheme/macro.sld`
- `scheme/agent-scheme/normalize.sld`
- `scheme/agent-scheme/eval.sld`
- `scheme/agent-scheme/write.sld`
- `scheme/agent-scheme/base.sld`

Likely Emacs Lisp bootstrap and adapter modules:

- `lisp/agent-scheme-reader.el`
- `lisp/agent-scheme-runtime.el`
- `lisp/agent-scheme-result.el`
- `lisp/agent-scheme-datum.el`
- `lisp/agent-scheme-library.el`
- `lisp/agent-scheme-macro.el`
- `lisp/agent-scheme-normalize.el`
- `lisp/agent-scheme-interpreter.el`
- `lisp/agent-scheme-eval.el`
- `lisp/agent-scheme-env.el`
- `lisp/agent-scheme-base.el`
- `lisp/agent-scheme-write.el`
- `lisp/agent-scheme-compile.el`
- `lisp/agent-scheme-bytecode.el`
- `lisp/agent-scheme-policy.el`
- `lisp/agent-scheme-audit.el`
- `lisp/agent-scheme-handle.el`
- `lisp/agent-scheme-capability.el`
- `lisp/agent-scheme-repl.el`
- `lisp/agent-scheme-mcp.el`

After the split, `agent-scheme-eval.el` can remain the public orchestration
surface for reading, expanding, normalizing, and invoking the default backend,
while focused frontend and backend modules own the underlying pass behavior.

Focused test files should mirror the modules:

- `tests/agent-scheme-reader-test.el`
- `tests/agent-scheme-runtime-test.el`
- `tests/agent-scheme-result-test.el`
- `tests/agent-scheme-library-test.el`
- `tests/agent-scheme-library-module-test.el`
- `tests/agent-scheme-macro-test.el`
- `tests/agent-scheme-macro-module-test.el`
- `tests/agent-scheme-normalize-test.el`
- `tests/agent-scheme-eval-test.el`
- `tests/agent-scheme-base-test.el`
- `tests/agent-scheme-base-module-test.el`
- `tests/agent-scheme-interpreter-test.el`
- `tests/agent-scheme-interpreter-module-test.el`
- `tests/agent-scheme-compile-test.el`
- `tests/agent-scheme-policy-test.el`
- `tests/agent-scheme-capability-test.el`
- `tests/agent-scheme-repl-test.el`
- `tests/agent-scheme-mcp-test.el`

The early conformance fixture suite belongs with issue tahoma/agent-scheme#12
and should be usable before the whole runtime is complete.

## Roadmap Alignment

The implementation order belongs in [Roadmap](roadmap.md), with
tahoma/agent-scheme#53 as the living dependency graph. Roadmap updates should
preserve this architecture's distinction between portable Scheme semantics and
explicit host authority.
