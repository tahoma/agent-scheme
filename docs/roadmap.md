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

This document can summarize the current milestone while the issue remains the
source of truth for ordering.

When adding or revising roadmap issues, keep the GitHub labels current:

- one `surface:*` label
- one `phase:*` label
- risk, host, size, review, and documentation labels when they add useful
  selection or review context
