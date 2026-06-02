# Release Notes

This file is the historical record of completed Consent Scheme roadmap chunks,
migrated out of the living roadmap issue
[#53](https://github.com/tahoma/agent-scheme/issues/53). The living roadmap keeps
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

**Migration trigger (going forward).** Migrate a full chunk from #53 into this
file when starting the first issue of the *next* chunk — not opportunistically
mid-chunk — so every still-open issue keeps its `<major>.<minor>.<ordinal>`
position in #53 until its whole chunk has shipped.

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

Chunk `0.15` is still the live chunk in #53 (the roadmap maintenance issue #364 is
open), but its host-compiled executable line has shipped. Version `0.15.3` (#272)
was not separately committed to `version.sld`; it is recorded here for
completeness alongside the other shipped slices.

- 0.15.1 — #270 add make compile for host-compiled portable executables
- 0.15.2 — #273 compile portable runtime executable with Gambit
- 0.15.3 — #272 compile portable runtime executable with Racket CS
- 0.15.4 — #364 roadmap maintenance — release-notes migration, chunk renumbering, and reconciliation
