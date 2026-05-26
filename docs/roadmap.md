# Roadmap

The active roadmap is tracked in GitHub issues, with
[tahoma/agent-scheme#53](https://github.com/tahoma/agent-scheme/issues/53) as
the living dependency graph and flat chunk map. This document is an onboarding
summary, not a second source of truth for issue order. When this note and #53
diverge, update #53 first and then refresh this summary.

Issues also carry a label taxonomy documented in
[GitHub issue taxonomy](issue-taxonomy.md). The roadmap says when work should
happen; the taxonomy says where contributors can work and which host or review
constraints apply.

The architectural baseline for the graph is
[Architecture and threat model](architecture.md). The multi-host and portable
bootstrap stance is recorded in
[Multi-Host Adapter and Bootstrap Strategy](multi-host-bootstrap.md).

## Roadmap Shape

#53 keeps a flat, time-ordered chunk map. Each chunk is a small planning cluster
of related issues. Umbrella and sub-issue relationships are tracked in a
separate index in #53 so broad topics do not nest inside the chunk map.

The current chunk bands are:

- Chunks 00-06 frame project process, conformance, the reader, evaluator,
  `(scheme base)`, shared fixtures, macros, library/frontend boundaries, and
  core R7RS-small completion.
- Chunks 07-12 build the first host safety substrate: read-only Emacs handles,
  policy, sessions, approvals, grants, redaction, file/port/process/network
  effects, VCS records, basic Emacs capabilities, and host reflection.
- Chunks 13-15 cover agent-facing workflow foundations: task lifecycle design,
  planning, helper libraries, transcripts, debugger UX, package and skill
  interop, rules, collaboration UX, and user-facing custom library docs.
- Chunks 16-25 collect optional SRFI work, starting with import naming and
  R7RS-overlap shims, then portable data, text, collection, test, pattern,
  port, restart, and binary-block libraries.
- Chunks 26-27 cover external evaluation and references, model/provider
  capabilities, budgets, persistence, outward protocols, and task control-loop
  proof fixtures.
- Chunks 28-30 introduce compiler backends through Agent Scheme LLIR, native
  emission and compiled effects, and the Emacs Lisp byte-code backend.
- Chunks 31-37 plan native CLI and daemon contracts, host-compiled portable
  executables, host adapter harnesses, host reflection and search, host adapter
  conformance, CLI-compatible Emacs slices, and future editor, browser,
  notebook, WASI, and JVM host contracts.

## Runtime Version Mapping

Agent Scheme runtime versions are derived from #53 until the project adopts an
explicit release policy. Every issue branch updates
`scheme/agent-scheme/version.sld` so the public runtime version reports the
roadmap position of the issue being advanced.

Use the version shape `0.<chunk>.<ordinal>`:

- `0` is the primary version during the pre-release roadmap phase.
- `<chunk>` is the issue's chunk number in #53's flat chunk map.
- `<ordinal>` is the issue's one-based position inside that chunk.

For example, the first issue in chunk 14 maps to `0.14.1`, represented in
source as `(agent-scheme-version 0 14 1)`.

## Roadmap Areas

The roadmap currently emphasizes these durable work areas. Some have completed
seed slices that later chunks depend on; #53 remains the authority for exact
open or closed status and ordering.

- Onboarding and planning hygiene:
  [#264](https://github.com/tahoma/agent-scheme/issues/264) tracks getting
  started documentation, [#294](https://github.com/tahoma/agent-scheme/issues/294)
  tracks this roadmap summary, and
  [#295](https://github.com/tahoma/agent-scheme/issues/295) tracks label,
  sub-issue, dependency, and chunk-placement cleanup.
- CI visibility and shard feedback:
  [#322](https://github.com/tahoma/agent-scheme/issues/322) splits CI tests and
  reports timing by Emacs-hosted and portable Chibi-backed validation path, and
  [#325](https://github.com/tahoma/agent-scheme/issues/325) tracks the later
  rebalancing pass after enough timing summaries are available.
- Shared effect domains:
  [#220](https://github.com/tahoma/agent-scheme/issues/220) for files,
  [#221](https://github.com/tahoma/agent-scheme/issues/221) for ports,
  [#222](https://github.com/tahoma/agent-scheme/issues/222) for processes,
  [#290](https://github.com/tahoma/agent-scheme/issues/290) for network
  capabilities, and
  [#103](https://github.com/tahoma/agent-scheme/issues/103) for the shared
  policy-gated backend effect path.
- VCS capabilities and mutation:
  [#266](https://github.com/tahoma/agent-scheme/issues/266) defines the shared
  VCS capability contract,
  [#279](https://github.com/tahoma/agent-scheme/issues/279) tracks
  policy-gated mutating VCS operations,
  [#292](https://github.com/tahoma/agent-scheme/issues/292) tracks Emacs
  mutating VCS adapter operations,
  [#280](https://github.com/tahoma/agent-scheme/issues/280) tracks the native
  CLI daemon VCS adapter library, and
  [#293](https://github.com/tahoma/agent-scheme/issues/293) tracks native CLI
  and daemon mutating VCS adapter operations.
- Task lifecycle and control loop:
  [#281](https://github.com/tahoma/agent-scheme/issues/281) is the umbrella for
  task lifecycle and control-loop design, documented in
  [Task Lifecycle and Control Loop](control-loop.md), with concrete slices for
  task records ([#285](https://github.com/tahoma/agent-scheme/issues/285)),
  the minimal task runner
  ([#286](https://github.com/tahoma/agent-scheme/issues/286)), shared
  control-loop fixtures
  ([#287](https://github.com/tahoma/agent-scheme/issues/287)), persistence and
  resume ([#288](https://github.com/tahoma/agent-scheme/issues/288)), and
  remote/local provider proof fixtures
  ([#289](https://github.com/tahoma/agent-scheme/issues/289)).
- Providers, budgets, and persistence:
  [#26](https://github.com/tahoma/agent-scheme/issues/26) covers model provider
  routing, [#223](https://github.com/tahoma/agent-scheme/issues/223) covers the
  provider capability domain,
  [#291](https://github.com/tahoma/agent-scheme/issues/291) tracks budget
  ledger and stop receipts, and
  [#48](https://github.com/tahoma/agent-scheme/issues/48) covers persistence
  formats and migrations.
- Host adapter conformance:
  [#237](https://github.com/tahoma/agent-scheme/issues/237) is the conformance
  umbrella for host adapter declarations, library discovery, raw object
  exclusion, capability mediation, policy posture, handle lifecycle, session
  isolation, redaction, prompts, cancellation, filesystem, process, stdio, and
  event durability.
- CLI-compatible Emacs behavior:
  [#254](https://github.com/tahoma/agent-scheme/issues/254) tracks the Emacs
  CLI-compatible host affordance subset, with child slices for stdio and
  transcripts, batch prompts, cwd/file/environment/audit records, approval
  separation, process events and handles, cancellation and budget behavior, and
  session/audit/handle liveness.
- Native CLI, daemon, and host-compiled executables:
  [#136](https://github.com/tahoma/agent-scheme/issues/136) defines the native
  CLI daemon adapter contract,
  [#270](https://github.com/tahoma/agent-scheme/issues/270) tracks
  host-compiled portable executable packaging, and
  [#272](https://github.com/tahoma/agent-scheme/issues/272) and
  [#273](https://github.com/tahoma/agent-scheme/issues/273) track Racket CS and
  Gambit executable slices.
- Compiler backends:
  [#115](https://github.com/tahoma/agent-scheme/issues/115) defines Agent
  Scheme LLIR, [#116](https://github.com/tahoma/agent-scheme/issues/116)
  lowers normalized core forms to LLIR,
  [#119](https://github.com/tahoma/agent-scheme/issues/119) emits LLVM textual
  IR for the pure LLIR subset, and
  [#123](https://github.com/tahoma/agent-scheme/issues/123) through
  [#129](https://github.com/tahoma/agent-scheme/issues/129) track the Emacs
  Lisp byte-code backend contract, emission, execution, comparison, effects,
  diagnostics, and caching.
- User-facing library and reference documentation:
  [#24](https://github.com/tahoma/agent-scheme/issues/24) tracks the R7RS
  reference library,
  [#37](https://github.com/tahoma/agent-scheme/issues/37) tracks the Emacs
  documentation capability library, and
  [#284](https://github.com/tahoma/agent-scheme/issues/284) tracks custom
  Agent Scheme library reference docs.
- Future host contracts:
  [#138](https://github.com/tahoma/agent-scheme/issues/138) covers Neovim,
  [#140](https://github.com/tahoma/agent-scheme/issues/140) covers VS Code,
  [#147](https://github.com/tahoma/agent-scheme/issues/147) covers LSP and
  DAP, [#142](https://github.com/tahoma/agent-scheme/issues/142) and
  [#143](https://github.com/tahoma/agent-scheme/issues/143) cover browser and
  Wasm requirements, [#145](https://github.com/tahoma/agent-scheme/issues/145)
  covers Jupyter, [#149](https://github.com/tahoma/agent-scheme/issues/149)
  covers WASI component imports, and
  [#151](https://github.com/tahoma/agent-scheme/issues/151) covers JVM IDE
  platforms.

## Maintenance

When adding or revising roadmap issues:

- update #53 first, including explicit issue-number dependencies where the
  target issue exists
- keep `docs/roadmap.md` concise and summary-level
- keep umbrella relationships in #53's Umbrella Issue Index, not nested in the
  chunk map
- keep GitHub labels aligned with [GitHub issue taxonomy](issue-taxonomy.md):
  one `surface:*` label, useful risk/host/size/review/documentation labels, and
  current placement in the chunk map
- do not add new `phase:*` labels; existing `phase:*` labels are legacy metadata
  from the old roadmap model and should be retired through
  [#295](https://github.com/tahoma/agent-scheme/issues/295)

Documentation-only roadmap changes should still run the verification command
documented in [Development Setup](development.md) and report the result.
