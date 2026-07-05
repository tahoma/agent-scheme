# Release Notes

This file is the historical record of completed Consent Scheme roadmap chunks,
migrated out of the living roadmap issue
[#53](https://github.com/tahoma/consent/issues/53). The living roadmap keeps
only the current and future chunks; once every issue in a chunk has shipped, the
chunk is moved here.

## Versioning

Each entry is recorded as `<major>.<minor>.<ordinal> — #<issue> <title>`, where
`<major>.<minor>` is the chunk's dotted number and `<ordinal>` is the issue's
one-based position within the chunk.

- **Chunks `0.00`-`0.13` (synthesized ordinals).** These chunks shipped before
  `scheme/consent/version.sld` existed, so no per-issue version was ever
  committed. Their ordinals are synthesized from GitHub merge order: issues are
  sorted by `closed_at` (ties broken by ascending issue number) and numbered from
  one.
- **Chunk `0.14` onward (committed versions).** Runtime versioning began at the
  start of chunk `0.14` (`version.sld` introduced at `0.14.1`). From here the
  ordinals are the versions actually committed to `version.sld`, not a renumber, so
  historical gaps in the committed sequence are preserved.

**Migration trigger (going forward).** A chunk lives in #53 only until every one
of its issues has shipped. As a standing invariant, whenever you advance any
issue, check whether an earlier chunk is now fully shipped yet still listed in
#53; if so, migrate it here in the same change rather than deferring it to a
later edge. Do not split a chunk mid-flight — a chunk with any still-open issue
keeps all of its issues, and their `<major>.<minor>.<ordinal>` positions, in
#53 until the whole chunk has shipped.

---

## 0.00 Project Frame and Contributor Flow

- 0.00.1 — #1 document R7RS-small architecture and threat model
- 0.00.2 — #61 replace informal my/ identifiers
- 0.00.3 — #62 add unit test harness
- 0.00.4 — #69 run test harness in GitHub Actions
- 0.00.5 — #60 add GitHub issue taxonomy
- 0.00.6 — #264 Consent Scheme getting started guide
- 0.00.7 — #295 reconcile roadmap metadata and issue relationships
- 0.00.8 — #294 refresh roadmap documentation from issue #53
- 0.00.9 — #322 split CI tests and report timing

## 0.01 Conformance and Host Contract Frame

- 0.01.1 — #12 add R7RS conformance matrix and fixture suite
- 0.01.2 — #55 add multi-host adapter and bootstrap strategy

## 0.02 Reader, Evaluator, and Base Bootstrap

- 0.02.1 — #2 implement R7RS reader and datum validator
- 0.02.2 — #3 implement R7RS evaluator kernel with proper tail recursion
- 0.02.3 — #4 add initial R7RS base library and result encoding
- 0.02.4 — #73 move derived base bindings into portable Scheme prelude

## 0.03 Shared Fixtures and Reference Coverage

- 0.03.1 — #92 unify reader and evaluator fixtures
- 0.03.2 — #93 add reference implementation oracle runner
- 0.03.3 — #94 mine R7RS implementations for conformance coverage
- 0.03.4 — #95 audit and expand R7RS conformance coverage
- 0.03.5 — #271 bring Gambit to R7RS host parity

## 0.04 Macro Surface and Source Documentation

- 0.04.1 — #13 implement syntax-rules hygienic macro expansion
- 0.04.2 — #77 improve inline documentation in Scheme and Emacs Lisp code
- 0.04.3 — #96 define Scheme source documentation rules
- 0.04.4 — #106 apply Scheme source documentation rules to existing code

## 0.05 Libraries and Frontend Boundaries

- 0.05.1 — #14 implement define-library and imports
- 0.05.2 — #99 move embedded portable libraries into source files
- 0.05.3 — #97 define pass-oriented frontend and backend architecture
- 0.05.4 — #98 add primitive and effect metadata manifest
- 0.05.5 — #101 move derived behavior into portable Scheme libraries
- 0.05.6 — #100 refactor evaluator modules along pass boundaries

## 0.06 Core R7RS Completion Slices

- 0.06.1 — #15 implement continuations, values, exceptions, and dynamic-wind
- 0.06.2 — #16 implement R7RS numeric tower
- 0.06.3 — #83 Native Scheme writer should canonicalize character external forms
- 0.06.4 — #84 Native Scheme numerics should not delegate inexact semantics to the host
- 0.06.5 — #81 support re-enterable continuations across completed extents
- 0.06.6 — #17 complete core data types and writer behavior
- 0.06.7 — #18 implement ports, read/write, load, and eval policy
- 0.06.8 — #19 complete R7RS-small standard libraries and compliance pass

## 0.07 First Host Safety Substrate

- 0.07.1 — #5 add Emacs capability libraries and opaque handles
- 0.07.2 — #7 add policy gates and audit log UX
- 0.07.3 — #21 implement agent-yield and the agent I/O library
- 0.07.4 — #41 define session lifecycle and snapshots
- 0.07.5 — #20 add native REPL session UX and scopes
- 0.07.6 — #22 add inspectable scoped memory library
- 0.07.7 — #313 implement policy-gated REPL interaction environment

## 0.08 Approvals, Grants, Redaction, and First Mutation

- 0.08.1 — #30 add programmable approval library
- 0.08.2 — #6 add transactional buffer edit capability library
- 0.08.3 — #43 add capability grants and attenuation
- 0.08.4 — #49 add secrets and redaction policy
- 0.08.5 — #102 define session capability environment and effect lowering

## 0.09 File, Port, Process, and Shared Effect Domains

- 0.09.1 — #220 implement file capability domain
- 0.09.2 — #221 implement port capability domain
- 0.09.3 — #103 ensure backends share policy-gated effect path
- 0.09.4 — #222 implement process capability domain
- 0.09.5 — #266 Consent Scheme shared VCS capability contract
- 0.09.6 — #279 add policy-gated mutating VCS operations
- 0.09.7 — #290 implement network capability domain
- 0.09.8 — #311 implement policy-gated time standard library

## 0.10 Basic Emacs Capability Surface

- 0.10.1 — #8 add controlled command and window capability libraries
- 0.10.2 — #32 add Emacs search capability library
- 0.10.3 — #33 add Emacs diff capability library
- 0.10.4 — #35 add Emacs diagnostics capability library

## 0.11 Emacs Process, VCS, and Test Surface

- 0.11.1 — #36 Consent Scheme Emacs VCS adapter library
- 0.11.2 — #292 implement Emacs policy-gated mutating VCS operations
- 0.11.3 — #46 add jobs, cancellation, and streaming yields
- 0.11.4 — #34 add Emacs compile capability library

## 0.12 Runtime Reflection and Host Declaration

- 0.12.1 — #136 define native CLI daemon adapter contract
- 0.12.2 — #27 add runtime reflection library
- 0.12.3 — #28 add current context library
- 0.12.4 — #234 add Emacs host-adapter declaration fixture

## 0.13 Planning, Helpers, and Workflow Foundations

- 0.13.1 — #131 add project development skill bundle
- 0.13.2 — #26 add model provider registry and routing policy
- 0.13.3 — #281 define agent task lifecycle and control loop
- 0.13.4 — #285 add task lifecycle records and state transitions
- 0.13.5 — #29 add first-class planning library
- 0.13.6 — #23 add reusable helper library and artifact workflow
- 0.13.7 — #31 add helper self-test library

## 0.14 Transcripts, Debugger, and Runtime Introspection UX

Ordinals below are the versions committed to `version.sld`. Version `0.14.3` was
never committed as a standalone datum because #44 closed as the version datum was
being introduced mid-chunk; it is recorded at its chunk position for completeness.

- 0.14.1 — #323 add introspectable runtime versioning
- 0.14.2 — #42 add replayable transcripts
- 0.14.3 — #44 add debugger and restart UX
- 0.14.4 — #227 add Emacs debugger UI and policy-gated restart actions
- 0.14.5 — #45 add macro expansion introspection
- 0.14.6 — #300 define docstring metadata convention
- 0.14.7 — #301 implement simple string docstrings
- 0.14.8 — #302 adopt simple docstrings in checked-in libraries
- 0.14.9 — #303 add rich documentation property records
- 0.14.10 — #344 add manifest-backed primitive documentation
- 0.14.11 — #341 expose private procedure docstrings in debug views
- 0.14.12 — #47 define handle lifetime and cleanup
- 0.14.13 — #338 attach source metadata to syntax datums
- 0.14.14 — #325 rebalance CI test shards from timing data
- 0.14.15 — #358 Docstring retention modes for runtime performance

## 0.15 Host-Compiled Portable Executables

Ordinals follow this chunk's positions in #53. Version `0.15.3` (#272) was not
separately committed to `version.sld`; it is recorded here at its chunk position
for completeness.

- 0.15.1 — #270 add make compile for host-compiled portable executables
- 0.15.2 — #273 compile portable runtime executable with Gambit
- 0.15.3 — #272 compile portable runtime executable with Racket CS
- 0.15.4 — #364 roadmap maintenance — release-notes migration, chunk renumbering, and reconciliation
- 0.15.5 — #376 design content-addressed library store and inter-agent exchange (RFC)
- 0.15.6 — #367 make CPS exception-handler restoration unwind-safe
- 0.15.7 — #394 slim docs/roadmap.md to a pointer to the roadmap issue
- 0.15.8 — #387 reduce the runtime-version update footprint to version.sld alone
- 0.15.9 — #68 relicense to Apache-2.0 with SPDX headers and NOTICE
- 0.15.10 — #389 rename Agent Scheme to Consent Scheme

## 0.16 Functional R7RS REPL and Cross-Host Parity

Ordinals follow this chunk's positions in #53. Version `0.16.5` was accidentally
burned during versioning and left as a gap so `0.16.6` onward keep their
already-assigned versions; the issue that briefly held the slot (#388) was moved
to the end of the chunk.

- 0.16.1 — #404 trim the make test default matrix and standard CI shard set
- 0.16.2 — #390 define shared cross-host REPL interaction contract
- 0.16.3 — #229 add native CLI daemon adapter manifest fixture
- 0.16.4 — #230 add native CLI daemon mock adapter tests
- 0.16.5 — _skipped_
- 0.16.6 — #231 add native CLI process boundary harness
- 0.16.7 — #360 add portable R7RS terminal REPL shell
- 0.16.8 — #418 reader recovery and errors-as-data: resync past malformed forms
- 0.16.9 — #399 support shebang-style executable script handling
- 0.16.10 — #424 add a pluggable chrome layer for the portable REPL
- 0.16.11 — #391 add Emacs incremental stdin REPL parity entry
- 0.16.12 — #425 render the Emacs REPL with the shared chrome model
- 0.16.13 — #392 add shared cross-host REPL parity conformance fixtures
- 0.16.14 — #374 promote in-repo Emacs-Lisp ↔ portable-Scheme parity diffing to a CI gate
- 0.16.15 — #465 record a structured, versioned per-PR CI run record for longitudinal analysis
- 0.16.16 — #453 add a documentation index (table of contents) for docs/
- 0.16.17 — #460 curate REPL and interactive-environment references in docs/references.md
- 0.16.18 — #393 document REPL usage and cross-host parity
- 0.16.19 — #407 fix source-comment standard violations on the optional portable shard
- 0.16.20 — #412 re-home host-independent consent-scheme-* ERT tests stranded on the opt-in Chibi shard
- 0.16.21 — #411 converge the Chibi portable host onto the shared host-suite harness
- 0.16.22 — #415 wire Emacs byte-compile warnings-as-errors (and checkdoc) into make test and CI
- 0.16.23 — #421 wire portable-host compiler warnings-as-errors into make test and CI
- 0.16.24 — #481 trim the per-push de-feature test cross to a single smoke leg
- 0.16.25 — #388 dev rule: background-monitor CI after committing to an open PR, and watch for timing regressions
- 0.16.26 — #447 fix comment chrome double-echoing interactive input
- 0.16.27 — #448 fix classic chrome continuation prompt landing on the result line
- 0.16.28 — #470 add make install/uninstall and a distribution path for the host-compiled runtime
- 0.16.29 — #518 bind internal-library imports to compiled native modules under the host-run grant
- 0.16.30 — #515 finish the Agent→Consent rename on the Emacs REPL surface and fix the user-reserved dispatch keybinding
- 0.16.31 — #506 surface reader nesting depth / pending-form state on the REPL prompt record
- 0.16.32 — #507 formalize REPL transcript capture and replay over the Scheme-readable record stream
- 0.16.33 — #505 define the REPL program-input stream model
- 0.16.34 — #514 add a comint-style interactive Emacs REPL buffer
- 0.16.35 — #522 charge value budgets at allocation instead of re-walking every primitive result
- 0.16.36 — #520 make the compiled-shard CI builds parallel, incremental, and cached; cancel superseded PR runs
- 0.16.37 — #528 connect binary standard streams (read-u8/write-u8 over stdio-backed ports)
- 0.16.38 — #529 refine the comment and classic REPL chrome rendering
- 0.16.39 — #556 rebalance local make test shards: isolate native-build tests, cache the compile-portable build, raise -j

## 0.17 REPL Agent Harness — Minimal Loop

Ordinals follow this chunk's final positions in #53.

- 0.17.1 — #459 curate agentic-harness and language-agent references
- 0.17.2 — #561 design the agent-layer consent stance
- 0.17.3 — #395 add Scheme-callable session management for the REPL
- 0.17.4 — #396 add agent abstraction, registry, and default selection
- 0.17.5 — #569 add the project logo
- 0.17.6 — #51 add comprehensive evaluation budgets
- 0.17.7 — #368 bound the global symbol intern table
- 0.17.8 — #508 bound REPL value rendering
- 0.17.9 — #598 enforce rich docstring metadata on runtime Scheme procedures
- 0.17.10 — #286 add the minimal task runner control loop
- 0.17.11 — #397 add the `(agent prompt)` REPL harness library
- 0.17.12 — #400 define promptable non-interactive script authority
- 0.17.13 — #604 adopt typed docstring metadata for parameters and returns
- 0.17.14 — #287 add the task control-loop fixture suite
- 0.17.15 — #185 add SRFI 180 JSON support
- 0.17.16 — #531 add native tool/function calling over the shipped local transport
- 0.17.17 — #562 admit tool/code calls by AST subtree match
- 0.17.18 — #563 measure pass^k reliability by stop-receipt cause
- 0.17.19 — #180 add SRFI 128 comparators
- 0.17.20 — #166 add SRFI 16 variable-arity procedure syntax
- 0.17.21 — #625 wrap Emacs Lisp docstrings and enforce docstring width
- 0.17.22 — #628 preserve runtime procedure defining syntax environments
- 0.17.23 — #205 add SRFI 2 AND-LET*
- 0.17.24 — #204 add SRFI 8 receive
- 0.17.25 — #621 add SRFI 145 assumptions
- 0.17.26 — #176 add SRFI 1 list library support
- 0.17.27 — #183 add SRFI 158 generators and accumulators
- 0.17.28 — #622 add the portable red-black tree helper for SRFI 146
- 0.17.29 — #191 add SRFI 146 ordered mappings
- 0.17.30 — #439 single-source the `(agent session)` library
- 0.17.31 — #437 single-source the `(agent memory)` library
- 0.17.32 — #564 add append-only gated reflection and deterministic retrieval
- 0.17.33 — #614 vendor SRFI 180 JSON reference tests
- 0.17.34 — #509 add introspection procedures as Scheme-readable data
- 0.17.35 — #670 add manifest-backed reflection and library discovery
- 0.17.36 — #654 preserve Scheme and Lisp prior-art references
- 0.17.37 — #398 add the REPL agent-harness quick-start guide
- 0.17.38 — #676 record project credits and normalize attribution
- 0.17.39 — #688 fix non-ASCII model prompt transport and REPL diagnostics
