# Documentation Index

This is the complete map of the `docs/` tree. Every document is listed below,
grouped by topic, with a one-line description drawn from the document's own
opening lines. For an onboarding path, start with **Getting Started**; for the
project pitch and examples, see the top-level [README](../README.md).

## Getting Started

- [Getting Started](getting-started.md) — first-use path for Consent Scheme from a local checkout.
- [Contributing](contributing.md) — issue lifecycle, branch names, pull requests, and commit messages.
- [Development Setup](development.md) — seed development machine setup, expected repository shape, and verification commands.

## Architecture & Design

- [Architecture and Threat Model](architecture.md) — the Consent Scheme runtime design, host boundary, and threat model.
- [Runtime Core Diagrams](runtime-core-diagrams.md) — Mermaid diagrams for the portable runtime core, Emacs Lisp twin, evaluation pipeline, host boundary, bootstrap hooks, and parity matrix.
- [Naming Convention](naming.md) — public and private Consent Scheme identifier conventions.
- [Multi-Host Adapter and Bootstrap Strategy](multi-host-bootstrap.md) — the Emacs-first bootstrap stance and the portable Scheme self-hosting path.
- [Roadmap](roadmap.md) — pointer to the GitHub-issue roadmap and how it is structured.
- [GitHub Issue Taxonomy](issue-taxonomy.md) — the label taxonomy for where and how an issue can be worked.
- [Licensing Policy](licensing.md) — the project's Apache-2.0 + SPDX licensing policy.
- [Project Credits](credits.md) — human authorship, maintenance, and tool-assisted attribution policy.
- [Resolved Graph Invariants](resolved-graph-invariants.md) — the roadmap dependency-graph invariants the resolved order must satisfy.
- [Host-Compiled Staging and the Embedded VFS](host-compiled-staging.md) — the `make compile` pipeline as a borrowed-backend compiler front-end, and the embedded source store as a capability-addressable virtual filesystem.

## Language & Conformance

- [R7RS-Small Report Reference](r7rs-small-report.md) — a local Markdown rendering of the Revised⁷ Report on the Algorithmic Language Scheme.
- [R7RS-Small Conformance Matrix](r7rs-conformance.md) — the source of truth for Consent Scheme's R7RS-small surface and its status.
- [Stdlib Libraries](stdlib.md) — optional SRFI and R7RS-large library support outside the R7RS-small conformance contract.
- [Flexvectors (SRFI 214)](flexvectors.md) — imports, mutation contracts, traversal rules, and storage boundaries for extensible vectors.
- [List Queues (SRFI 117)](list-queues.md) — list identity, mutation, complexity, and private-worklist boundaries for mutable queues.
- [R7RS Implementation Test Mining](r7rs-implementation-mining.md) — a survey of external R7RS and near-R7RS test suites mined for fixtures.
- [Docstring Metadata Convention](docstring-metadata.md) — carrying documentation metadata as ordinary R7RS data in source.
- [Scheme Style Guidelines](scheme-style.md) — portable Scheme source layout, docstrings, and rich metadata style.
- [Macro Expansion Introspection](macro-introspection.md) — exposing macro expansion as Scheme-readable data.
- [Reflection Quickstart](reflection-quickstart.md) — a user guide for apropos, library discovery, binding crosswalks, and manifest-backed reflection.
- [Runtime Definition Discovery Tutorial](runtime-definition-discovery.md) — using `(agent reflect)` and manifests to discover live bindings, registered libraries, and cataloged definitions.
- [Feature and Host Reflection](feature-reflection.md) — preferring capability discovery over hard-coded host assumptions.

## Runtime & Capabilities

- [Capability Environment and Effect Lowering](capability-environment.md) — how pure evaluation is gated by explicit host capabilities and effects.
- [Secrets, Local-Only Context, and Redaction](privacy.md) — treating secrets and private context as policy-bearing data.
- [Session Lifecycle and Snapshots](session-lifecycle.md) — explicit runtime records for evaluation state and their snapshots.
- [Task Lifecycle and Control Loop](control-loop.md) — the runtime layer that turns Scheme-readable tasks into managed work.
- [Jobs, Cancellation, and Streaming Yields](jobs.md) — representing long-running or concurrent work as Scheme-readable jobs.
- [Evaluation Budgets](budgets.md) — the single inspectable budget ledger, its exhaustion reason, and how to inspect and tighten resource ceilings.
- [First-Class Plans](plans.md) — Scheme-readable plan records shared through the `(agent plan)` library.
- [Replayable Transcripts](transcripts.md) — recording session and runtime activity as replayable Scheme data.
- [Debugger](debugger.md) — turning evaluator failures and raised exceptions into an inspectable surface.
- [Helper Libraries and Artifacts](helper-artifacts.md) — reusable Scheme source snippets and their related artifacts.
- [Executable Consent Scheme Scripts](executable-scripts.md) — marking a source file executable and running it directly from a shell.

## Host Adapters & REPL

- [Native CLI and Daemon Adapter Contract](native-cli-daemon-adapter.md) — the first planned non-Emacs host adapter contract.
- [REPL Agent Harness Quick Start](repl-agent-quickstart.md) — five-minute path from launching a REPL to prompting an agent with stubbed provider steps.
- [Using the Consent Scheme REPL](repl.md) — single guide to starting the REPL on both hosts, with a cross-host parity matrix.
- [Portable Terminal REPL Shell](portable-repl.md) — the first interactive non-Emacs REPL entry point.
- [Cross-Host REPL Interaction Contract](repl-interaction-contract.md) — the shared interaction contract a REPL must honor across hosts.
- [Shared VCS Capability Contract](vcs-capability.md) — the host-neutral `(agent vcs)` repository-state capability.

## Library System

- [Content-Addressed Library Store](content-addressed-library-store.md) — exploratory design note on a content-addressed store and inter-agent exchange.
- [Library Exchange — Design Log](library-exchange-design-log.md) — a narrative record of the design conversation behind the library exchange.

## Reference

- [The Logo](logo.md) — the design and layered meaning of the Consent Scheme mark (a yin-yang of a brush λ and an ensō dialog bubble).
- [Scheme References](references.md) — external Scheme references useful while building Consent Scheme.
- [Agentic-Harness and Language-Agent Prior-Art Synthesis](agentic-harness-ideas.md) — non-normative idea bank derived from the curated agentic references: experiments, features, and design decisions for the M2 REPL agent harness.
- [Release Notes](release-notes.md) — the historical record of completed roadmap chunks.
- [CI Run Record](ci-run-record.md) — the structured, machine-readable per-run record emitted by the test workflow.
- [CI Timing Baselines](ci-timing-baselines.md) — recorded per-shard timing baselines and observations the regression heuristic compares against.
