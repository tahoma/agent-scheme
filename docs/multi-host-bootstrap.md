# Multi-Host Adapter and Bootstrap Strategy

Consent Scheme treats R7RS-small as the user-facing language contract and treats
each host as a replaceable adapter. Emacs is the first host and the bootstrap
vehicle, but the portable runtime model should remain able to move into other
Scheme implementations, compiled backends, and non-Emacs user interfaces.

The portable R7RS implementation is not a demonstration harness or downstream
copy of the Emacs Lisp bootstrap. It is a first-class implementation path and
the strategic route toward a natively compiled reader, evaluator, emitter, and
REPL. While both implementations coexist, language-core work should preserve
architectural parity instead of allowing the portable side to trail as cleanup.

This document records the host/core boundary for contributors before the
adapter APIs become executable code.

The companion [Runtime Core Diagrams](runtime-core-diagrams.md) page maps the
current portable Scheme runtime core, Emacs Lisp twin, host boundary, bootstrap
hooks, and parity test matrix as Mermaid source.

## Design Goals

- Keep R7RS-small semantics independent from any one host.
- Represent runtime interfaces, host requests, results, policy decisions,
  memory, plans, rules, skills, and transcripts as Scheme-readable data.
- Put host authority behind explicit adapter-provided capability libraries.
- Make Emacs useful early without making Emacs the semantic center.
- Keep at least one non-Emacs validation path available for portable core work.
- Keep Emacs Lisp and portable R7RS modules in parity for language semantics,
  pass boundaries, standard libraries, fixtures, and public behavior.

## Core and Adapter Boundary

The portable core owns Scheme data and semantics. A host adapter owns external
effects, user interaction, and host-specific acceleration. The boundary should
look like Scheme-readable records even when a particular adapter stores or
transports them through Emacs Lisp objects, JSON, files, or process messages.

Example adapter declaration shape:

```scheme
(host-adapter
  (name emacs)
  (contract r7rs-small)
  (provides
    ((library (emacs buffer))
     (library (emacs project))
     (library (agent approval))))
  (authority
    ((read-only-observation allowed-or-confirmed)
     (mutation confirmation-gated)
     (process confirmation-gated)))
  (validation
    ((portable-suite gambit)
     (portable-suite racket)
     (portable-suite guile)
     (portable-suite gauche)
     (host-suite ert))))
```

Example capability shape:

```scheme
(host-capability
  (library (emacs buffer))
  (name current-buffer)
  (authority read-only-observation)
  (arguments ())
  (returns (handle buffer))
  (policy project-trust-or-confirm)
  (audit required))
```

Example request and result shape:

```scheme
(host-request
  (id req-17)
  (capability ((emacs buffer) current-buffer))
  (arguments ())
  (scope project-main))

(host-result
  (id req-17)
  (status ok)
  (value (handle buffer h-42))
  (audit audit-91))
```

These examples are design targets, not frozen public APIs. Later issues should
turn them into concrete records, procedures, and tests as the policy, session,
library-resolution, and capability layers land.

## Portable Core Responsibilities

Portable core code belongs in `scheme/` whenever practical and should avoid
assuming Emacs, a current editor buffer, a process supervisor, or local
filesystem authority. This is the default ownership rule: if behavior can be
implemented as portable Scheme without performing a host effect, it belongs in
the portable layer before any host-specific duplicate is added. The dual-core
surface should stay limited to the smallest subset that must be implemented
separately by a bootstrap or host adapter. Portable core owns:

- reader, datum validation, writer, evaluator, macro expander, and library
  semantics
- owned pair, string, vector, and bytevector identity, graph topology, and
  mutation through `(consent datum)`
- standard R7RS libraries and policy-visible declarations for host-effecting
  libraries
- canonical datums for memory records, plans, rules, skills, transcripts,
  session records, results, events, approvals, and audit entries
- portable helper libraries and Consent Scheme-native manifests
- protocol datums, host-neutral codecs, deterministic parsers, and request or
  response normalization
- conformance fixtures, reference data, and portable tests
- deterministic library names and imports such as `(scheme base)`,
  `(agent memory)`, and `(agent plan)`

Portable code may describe a host effect as data, but it must not silently
perform that effect. For example, a portable library can construct an approval
request datum; only a host adapter can display the prompt and perform an
approved buffer, process, network, or filesystem action.

## Host Adapter Responsibilities

Host-specific code belongs in adapter modules such as `lisp/` for Emacs. It
owns:

- UI buffers, views, commands, keymaps, menus, status indicators, and other
  host-native interaction surfaces
- capability bridges that turn imported host libraries into controlled effects
- policy prompts, approval UX, denial behavior, and audit emission
- process, network, filesystem, project, VCS, diagnostics, and documentation
  integration
- persistence plumbing and migration hooks for host-managed storage
- model provider wire I/O, effectful stream delivery, and host-specific retry,
  timeout, or credential handling
- performance shortcuts such as indexes, caches, native handles, and compiled
  fast paths

Adapters must keep raw host objects out of Scheme values. Scheme code receives
opaque handles and Scheme-readable records. A host adapter may keep a private
side table from handles to live objects, but canonical state remains printable
and auditable at the Scheme boundary.

The portable runtime applies the same rule to ordinary compound data. Borrowed
R7RS pairs, strings, vectors, and bytevectors may appear only in private parser,
control, or ABI adapter state. A call-scoped native graph bridge preserves
aliases, returned subobject identity, cycles, raised conditions, and mutation
writeback while one compiled host call temporarily observes such containers.
Raw mirrors cannot outlive that outer call. Fresh result and writeback topology
is charged once after reconciliation, while borrowed identities reused from the
call are not allocated again. Hash-backed hosts retain linear foreign-graph
copying; the plain-R7RS compatibility route accepts at most 64 distinct foreign
identities and then fails closed. Shared conformance fixtures keep this owned
portable behavior aligned with the Emacs bootstrap.

## Emacs as the First Host

The Emacs adapter is the first body for Consent Scheme because it can provide
native buffers, project integration, ERT tests, process management, and policy
prompts early. That bootstrap role does not make Emacs Lisp the architectural
reference. While the Emacs Lisp and portable Scheme implementations coexist,
both sides should preserve the same library names, datum shapes, result
rendering, policy expectations, pass boundaries, and conformance fixtures.

Emacs-specific facilities should appear through explicit libraries such as:

```scheme
(emacs buffer)
(emacs project)
(emacs command)
(emacs process)
```

Those imports must not pollute `(scheme base)` or redefine R7RS behavior. Code
that only imports standard Scheme libraries should remain host-neutral.

Character and Unicode behavior follows the
[portable character model](character-model.md): borrowed hosts provide source
text and string storage, while Consent Scheme owns scalar validity, ordering,
classification, casing, folding, digit values, and strict UTF-8 behavior.
Adapters must wrap host characters at entry and may unwrap them only for
source-text, host-string, or textual-port storage. A host Unicode table cannot
silently redefine the public `(scheme char)` library.

## Bootstrap Stance

R7RS-small remains the contract even if an R6RS or Chez-based backend becomes
attractive later. A backend can be faster, more mature, or easier to compile
without changing the language that Consent Scheme promises to users.

Bootstrap work should proceed in this order:

1. Put new host-neutral semantics, derived helpers, codecs, protocol surfaces,
   and libraries in portable Scheme as soon as the evaluator can run them.
2. Maintain architectural parity between the Emacs Lisp bootstrap
   implementation and portable R7RS modules only for the irreducible dual-core
   slice that cannot yet be single-sourced against the same conformance
   fixtures.
3. Keep host effects policy-gated and represented as data before adapter code
   performs them.
4. Use an external R7RS implementation to validate portable reader, evaluator,
   library, and helper code where practical.
5. Add new host adapters only after their capability libraries, policy posture,
   handle model, and audit records are described as Scheme-readable data.

Chez Scheme or another R6RS system may become an implementation backend. If so,
it should be wrapped by an adapter layer that presents R7RS-small names and
semantics to Consent Scheme programs. R6RS libraries, condition systems,
Unicode behavior, or module facilities can inform the implementation, but they
must not replace the R7RS-small user contract.

## Backend Capability Matrix

| Target | Role | Strengths | Constraints | Validation target |
| --- | --- | --- | --- | --- |
| Emacs Lisp adapter | First host and bootstrap adapter | Native editor UX, ERT, project buffers, policy prompts | Host-specific objects and dynamic editor state must stay behind handles | `make test` through ERT |
| Chibi Scheme | Optional external R7RS validation path | Small R7RS implementation, `.sld` support, useful for portability spot checks | Optional on developer machines; validates the portable product path but is not itself the product host | `CONSENT_CHIBI=chibi-scheme make test-portable-chibi` |
| Gauche, Gambit, Racket, Guile, or Cyclone | R7RS compatibility probes | Broader implementation diversity and performance signals | Library/import behavior and extensions differ by implementation | Default portable CI shards plus opt-in oracle adapters |
| Chez or another R6RS backend | Possible optimized backend | Mature compiler and runtime, strong performance story | R6RS is not the Consent Scheme language contract | R7RS compatibility adapter plus conformance fixtures |
| Future compiled backend | Long-term runtime strategy | Fast startup or embedding in non-editor hosts | Must preserve inspectable datums, policy, and library semantics | Same core fixture suite |
| Non-Emacs UI shell | Future UX host | CLI, web, IDE, or editor surfaces can share the core | Needs its own policy, handles, and persistence adapter | Mock or real host-adapter suite |

The first concrete non-Emacs path was a Chibi-backed portable test path for
reader, evaluator, and library code; it remains available as an optional manual
check. Full-suite Gambit, Racket, Guile, and Gauche CI shards run the portable
Scheme suite by default to keep independent host timing signals visible while
compiled host work remains future scope. A later non-Emacs host can start as a
command-line adapter with mock capability
libraries before gaining real UI, process, provider, or persistence authority.

## Portable Test Strategy

Portable pieces should be testable without loading the Emacs adapter whenever
the feature can be expressed through R7RS libraries and data alone.

Current examples:

- `tests/scheme/test-plan.scm` is the Scheme-readable source of truth for
  portable programs, tags, and shard selectors. `(testing plan)` validates and
  selects it through `(testing runner)`; `tools/run-portable-tests.sh` only
  maps the resulting paths to the configured external Scheme host. Every host,
  Chibi included, goes through this boundary without entering ERT.
- `tests/consent-scheme-eval-test.el` guards a host-independent bootstrap
  invariant around explicit continuations in the portable evaluator source.
- `tests/consent-conformance-test.el` validates the fixture suite and runs
  implemented cases through the Consent Scheme evaluator.

Host-neutral behavior must add R7RS fixtures first unless the test documents a
host-boundary reason that prevents it. Bridge those fixtures into `make test`
through ERT so a minimal checkout still has one verification command; ERT is
the host runner and reporting adapter, not the canonical semantic test home.
If an external Scheme is unavailable, the bridge may skip the external run,
but the fixture shape should still be validated.

The helper library and artifact workflow in
[Helper Libraries and Artifacts](helper-artifacts.md) follows this boundary:
the portable core owns helper, artifact, and skill candidate datums, while host
adapters own private-local persistence, project-tracked writes, and approval
prompts.

Feature and host discovery expectations are documented in
[Feature and Host Reflection](feature-reflection.md). Host adapters should
support static discovery through library availability and runtime discovery
through Scheme-readable `host-adapter` and `host-capability` datums, while
keeping authorization behind the capability environment.

The native CLI and daemon adapter contract in
[Native CLI and Daemon Adapter Contract](native-cli-daemon-adapter.md) is the
first concrete non-Emacs host contract. It keeps terminal prompts, daemon
control, process jobs, standard streams, audit sinks, and stale native handles
behind the same Scheme-readable capability boundary described here.

The shared repository-state vocabulary in
[Shared VCS Capability Contract](vcs-capability.md) follows the same boundary:
`(agent vcs)` defines portable records and pure Git parser fixtures, while
Emacs, CLI, and future hosts decide how to obtain repository observations
without exposing raw host VCS objects or granting mutation by default.

## Contributor Placement Rules

- Put host-neutral R7RS libraries in `scheme/consent/`.
- Put reusable portable testing facilities under `scheme/testing/` and
  register them in the testing collection manifest.
- Put Emacs adapter code in `lisp/consent-*.el`.
- Put portable Scheme tests in `tests/scheme/` and run them through the
  Scheme-native testing facilities plus the thin portable host launcher.
- Put host adapter tests in focused `tests/consent-*-test.el` files.
- Keep capability libraries visibly separate from standard Scheme libraries.
- Keep host performance caches rebuildable from canonical Scheme-readable data.
- Update Emacs Lisp and portable Scheme pass modules together for core
  semantics and refactors when practical; otherwise record the parity follow-up
  explicitly.
- Document any backend-specific shortcut as an adapter implementation detail,
  not as a change to Consent Scheme semantics.

When a design question is about Scheme semantics, prefer the local
R7RS-small report and the conformance matrix. When the question is about host
authority, prefer the architecture threat model, policy issues, and this
adapter boundary.
