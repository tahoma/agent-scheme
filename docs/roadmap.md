# Roadmap

The active roadmap is tracked in GitHub issues, with
[tahoma/agent-scheme#53](https://github.com/tahoma/agent-scheme/issues/53) as
the living dependency graph.

Issues also carry a label taxonomy documented in
[GitHub issue taxonomy](issue-taxonomy.md). The roadmap says when work should
happen; the taxonomy says where contributors can work and which host or review
constraints apply.

The architectural baseline for that graph is
[Architecture and threat model](architecture.md).

The pass-oriented frontend and backend architecture tracked in
[tahoma/agent-scheme#97](https://github.com/tahoma/agent-scheme/issues/97)
guides phase 1 runtime work. Major evaluator splitting should follow that
architecture: reader, library resolution, macro expansion, and normalization
are shared frontend passes; the current evaluator is the first interpreter
backend over those passes; future compiler or byte-code backends plug in after
the normalized core form or IR rather than reimplementing reader, library, or
macro behavior.

The project roadmap follows this design intent:

1. R7RS-small language core
2. safety and live runtime substrate
3. Emacs host adapter and useful capabilities
4. agentic self-scripting libraries
5. model, protocol, persistence, and ecosystem integrations
6. compiler backends over the shared frontend and runtime contracts

Current onboarding documentation issue:

- [tahoma/agent-scheme#264](https://github.com/tahoma/agent-scheme/issues/264)
  adds a getting started guide for checkout setup, native Emacs REPL first use,
  verification, and the current non-Emacs host status.

Current host-neutral agent capability issues:

- [tahoma/agent-scheme#267](https://github.com/tahoma/agent-scheme/issues/267)
  adds a host-neutral search interface over adapter-provided search
  capabilities, starting from the Emacs search surface in
  [tahoma/agent-scheme#32](https://github.com/tahoma/agent-scheme/issues/32).

The compiler-backend phase starts with Agent Scheme LLIR rather than LLVM
directly.  LLIR is the backend-facing, Scheme-readable low-level intermediate
representation that sits after normalized core forms and before concrete
emitters.  LLVM textual IR is the first planned native emitter, but it consumes
LLIR instead of becoming Agent Scheme's own compiler IR.  Emacs Lisp byte-code
is the first planned host byte-code emitter and follows the same LLIR boundary.
The first LLIR slice executes only pure R7RS forms while still representing
effects as explicit unsupported nodes so compiled backends do not drift around
policy.

Current compiler-backend issues:

- [tahoma/agent-scheme#115](https://github.com/tahoma/agent-scheme/issues/115)
  defines Agent Scheme LLIR for compiler backends.
- [tahoma/agent-scheme#116](https://github.com/tahoma/agent-scheme/issues/116)
  lowers normalized core forms to LLIR.
- [tahoma/agent-scheme#117](https://github.com/tahoma/agent-scheme/issues/117)
  adds the LLIR verifier and shared fixture phase.
- [tahoma/agent-scheme#118](https://github.com/tahoma/agent-scheme/issues/118)
  adds a debug LLIR execution harness before native emission.
- [tahoma/agent-scheme#120](https://github.com/tahoma/agent-scheme/issues/120)
  defines the compiled runtime ABI and value representation.
- [tahoma/agent-scheme#119](https://github.com/tahoma/agent-scheme/issues/119)
  emits LLVM textual IR for the pure LLIR subset.
- [tahoma/agent-scheme#121](https://github.com/tahoma/agent-scheme/issues/121)
  routes compiled effects through the shared policy path.
- [tahoma/agent-scheme#123](https://github.com/tahoma/agent-scheme/issues/123)
  defines the Emacs Lisp byte-code backend contract.
- [tahoma/agent-scheme#124](https://github.com/tahoma/agent-scheme/issues/124)
  emits Emacs Lisp forms for the pure LLIR subset.
- [tahoma/agent-scheme#125](https://github.com/tahoma/agent-scheme/issues/125)
  adds the Emacs byte-code compile and execution harness.
- [tahoma/agent-scheme#126](https://github.com/tahoma/agent-scheme/issues/126)
  compares interpreter, LLIR debug, and byte-code backend results.
- [tahoma/agent-scheme#127](https://github.com/tahoma/agent-scheme/issues/127)
  routes byte-code backend effects through the shared policy path.
- [tahoma/agent-scheme#128](https://github.com/tahoma/agent-scheme/issues/128)
  adds byte-code backend diagnostics and source mapping.
- [tahoma/agent-scheme#129](https://github.com/tahoma/agent-scheme/issues/129)
  adds byte-code backend caching and invalidation.

Future host-adapter expansion issues, in proposed order:

- [tahoma/agent-scheme#135](https://github.com/tahoma/agent-scheme/issues/135)
  tracks the native CLI and daemon host adapter.
- [tahoma/agent-scheme#136](https://github.com/tahoma/agent-scheme/issues/136)
  defines the native CLI daemon adapter contract.
- [tahoma/agent-scheme#137](https://github.com/tahoma/agent-scheme/issues/137)
  tracks the Neovim host adapter.
- [tahoma/agent-scheme#138](https://github.com/tahoma/agent-scheme/issues/138)
  defines the Neovim RPC adapter contract.
- [tahoma/agent-scheme#139](https://github.com/tahoma/agent-scheme/issues/139)
  tracks the VS Code extension host adapter.
- [tahoma/agent-scheme#140](https://github.com/tahoma/agent-scheme/issues/140)
  defines the VS Code extension adapter contract.
- [tahoma/agent-scheme#141](https://github.com/tahoma/agent-scheme/issues/141)
  tracks the browser WebExtension host adapter.
- [tahoma/agent-scheme#142](https://github.com/tahoma/agent-scheme/issues/142)
  defines the browser WebExtension adapter contract.
- [tahoma/agent-scheme#143](https://github.com/tahoma/agent-scheme/issues/143)
  defines Wasm backend requirements for browser host adapters.
- [tahoma/agent-scheme#144](https://github.com/tahoma/agent-scheme/issues/144)
  tracks the Jupyter notebook host adapter.
- [tahoma/agent-scheme#145](https://github.com/tahoma/agent-scheme/issues/145)
  defines the Jupyter kernel and notebook adapter contract.
- [tahoma/agent-scheme#146](https://github.com/tahoma/agent-scheme/issues/146)
  tracks the LSP and DAP protocol adapter surface.
- [tahoma/agent-scheme#147](https://github.com/tahoma/agent-scheme/issues/147)
  defines the LSP and DAP capability and transport contract.
- [tahoma/agent-scheme#148](https://github.com/tahoma/agent-scheme/issues/148)
  tracks the WASI and component-model host contract.
- [tahoma/agent-scheme#149](https://github.com/tahoma/agent-scheme/issues/149)
  defines WASI component imports for host capabilities.
- [tahoma/agent-scheme#150](https://github.com/tahoma/agent-scheme/issues/150)
  tracks the JetBrains platform host adapter.
- [tahoma/agent-scheme#151](https://github.com/tahoma/agent-scheme/issues/151)
  defines the JVM IDE platform adapter contract.

This document can summarize the current milestone while the issue remains the
source of truth for ordering.

When adding or revising roadmap issues, keep the GitHub labels current:

- one `surface:*` label
- one `phase:*` label
- risk, host, size, review, and documentation labels when they add useful
  selection or review context
