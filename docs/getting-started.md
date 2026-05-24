# Getting Started

This guide covers the currently supported first-use path for Agent Scheme from a
local checkout. The supported user entry point today is the Emacs-hosted native
REPL session. The portable Scheme code and native CLI/daemon adapter contract
are part of the project direction, but they are not yet the general first-use
interface.

## Prerequisites

Install the core development tools:

- Git
- GitHub CLI, `gh`, for issue and pull request work
- Emacs, preferably a current stable release
- GNU Make
- ripgrep, `rg`

Optional Scheme implementations improve portable and oracle coverage:

- Chibi Scheme, `chibi-scheme`, for portable R7RS tests and default oracle use
- Sagittarius, `sagittarius`, for default oracle comparisons
- Gauche, Guile, Racket with the `r7rs` package, and CHICKEN with the `r7rs`
  egg for additional developer-only oracle comparisons

## Checkout Setup

Clone the repository and enter the checkout:

```sh
git clone git@github.com:tahoma/agent-scheme.git
cd agent-scheme
```

For issue work, create a branch that includes the issue number:

```sh
git switch -c author-name/issue-N/short-name
```

Before working with issues or pull requests, confirm GitHub CLI access:

```sh
gh auth status
git remote -v
```

## Emacs REPL Startup

The current first-use flow loads the Emacs Lisp bootstrap modules from the
checkout and starts a project session.

From Emacs, add the checkout's `lisp/` directory to `load-path` and load the
native REPL module:

```elisp
(add-to-list 'load-path (expand-file-name "lisp" "/path/to/agent-scheme/"))
(require 'agent-scheme-repl)
```

Then run:

```text
M-x agent-scheme-start-repl
```

`agent-scheme-start-repl` defaults to a project session. From this repository,
the visible buffers normally use the project label `agent-scheme`, such as
`*Agent: agent-scheme*` and `*Agent Scheme: agent-scheme*`.

The native dispatch menu is bound to:

```text
C-c a
```

It includes commands for starting or switching sessions, inspecting or stopping
sessions, opening session buffers, and evaluating source in the current session.

## First Evaluation

After starting the REPL, run:

```text
M-x agent-scheme-repl-eval
```

Enter a pure Scheme expression:

```scheme
(+ 1 2)
```

The command evaluates the source in the current session and refreshes the native
session buffers. The REPL transcript buffer records the source and result as a
Scheme-readable `transcript-entry`.

For a small session example that preserves a definition and emits a safe event,
evaluate:

```scheme
(import (scheme base) (agent io))
(define saved-answer 21)
(agent-yield '(ready))
(+ saved-answer saved-answer)
```

The result is `42`. The transcript records the evaluation, and the events buffer
shows the yielded `(ready)` datum. This example uses pure evaluation and
`(agent io)` event emission; it does not request file, process, buffer-edit, or
other privileged host effects.

You can also exercise the same path in batch Emacs from the repository root:

```sh
emacs -Q --batch -L lisp \
  --eval "(require 'agent-scheme-repl)" \
  --eval "(require 'agent-scheme-result)" \
  --eval "(agent-scheme-start-repl 'named \"getting-started\")" \
  --eval "(princ (agent-scheme-result->external (agent-scheme-repl-eval-source \"(import (scheme base) (agent io)) (define saved-answer 21) (agent-yield '(ready)) (+ saved-answer saved-answer)\")))"
```

Expected output:

```text
42
```

## Session Buffer Map

`agent-scheme-start-repl` creates a native, non-vterm buffer set for the active
session:

| Buffer | Role |
| --- | --- |
| `*Agent: PROJECT*` | Status and session record view. This is the primary state view for imports, definitions, memory references, handles, status, transcript references, and recent events. |
| `*Agent Scheme: PROJECT*` | Persistent REPL transcript. Evaluations appear as Scheme-readable `transcript-entry` datums. |
| `*Agent Events: PROJECT*` | Recent `(agent io)` events, such as `agent-yield`, `agent-log`, progress, warnings, and request records. |
| `*Agent Audit: PROJECT*` | Session-scoped audit entries for lifecycle transitions, evaluations, policy decisions, approval records, and capability activity. |
| `*Agent Approvals: PROJECT*` | Pending and resolved approval request datums for effects that need host or user confirmation. Pure examples normally leave this buffer empty. |

Each buffer includes a mode-line status indicator in the form:

```text
Agent[SESSION:STATUS]
```

Memory is represented in the session record and through `(agent memory)` when
that library is imported. Editable memory buffers are separate from the REPL
buffer set; after loading `agent-scheme-memory`, use `M-x
agent-scheme-memory-open` to inspect instance, session, or project memory as
Scheme-readable data.

## Policy and Capabilities

Agent Scheme keeps host authority explicit. Pure R7RS evaluation is allowed
under resource budgets, while host-observing or host-mutating work goes through
policy, grants, handles, and audit records. The first-use posture is
default-deny for ungranted or unresolved host effects.

At first use:

- Pure `(scheme base)` evaluation is the safe starting point.
- Read-only Emacs observations are audited and may be allowed or confirmation
  gated by project trust.
- Buffer, window, command, process, skill, and many standard host effects are
  confirmation-gated or denied by default.
- Raw Emacs Lisp evaluation from Scheme is denied by default.
- Scheme code can create approval requests, but approval resolution is
  host-side unless explicitly enabled by policy.
- Host objects stay behind opaque handles; Scheme values remain printable,
  auditable data.

For first experiments, prefer pure expressions, standard pure libraries, and
`(agent io)` event examples. Avoid examples that read local files, mutate
buffers, run commands, inspect environment variables, or depend on private
machine state until you are intentionally testing capability policy.

Read-only host observations can still return structured data. For example, a
diagnostic-driven helper can inspect the current buffer through the Emacs
adapter, then yield the portable diagnostic snapshot back to the session event
stream:

```scheme
(import (scheme base)
        (agent diagnostics)
        (emacs buffer)
        (emacs diagnostics))

(define snapshot
  (buffer-diagnostics (emacs-current-buffer)))

(diagnostics-yield snapshot)
snapshot
```

The yielded value is a `diagnostics-snapshot` datum containing zero or more
`diagnostic` records with severity, message, source, buffer/file, range, and
backend metadata. If project-wide diagnostics are unavailable for the current
host state, `(project-diagnostics '())` returns an unavailable snapshot instead
of trying to run a mutating command. Diagnostic code actions are not exposed by
this read-only library.

## Verification

The default local verification command is:

```sh
make test
```

For documentation-only changes, also run:

```sh
git diff --check
rg -n "m[y]/agent-scheme|m[y]/mcp" README.md docs
```

The `rg` command should normally return no matches. If documentation changes
include the repository skill bundle, also scan `skills/` with the same pattern.

Optional portable and oracle checks use installed R7RS implementations. Chibi
Scheme is used by portable R7RS tests when available:

```sh
AGENT_SCHEME_CHIBI=chibi-scheme make test
```

Pure shared fixtures can be compared against reference implementations:

```sh
make conformance-oracle
```

Use the environment variables listed by `make help` to select specific oracle
references or report statuses.

## Troubleshooting

If `require` cannot find `agent-scheme-repl`, confirm that the checkout's
`lisp/` directory is on `load-path`. In a fresh Emacs session, this form should
point at the local checkout:

```elisp
(add-to-list 'load-path (expand-file-name "lisp" "/path/to/agent-scheme/"))
```

If `M-x agent-scheme-start-repl` is unavailable, reload the module:

```elisp
(require 'agent-scheme-repl)
```

If a session seems stale, inspect the status buffer with `M-x
agent-scheme-inspect-session`, switch sessions with `M-x
agent-scheme-switch-session`, or retire the current session with `M-x
agent-scheme-stop-session`.

If a host-effecting example is denied, treat that as the expected safe posture.
Inspect `*Agent Audit: PROJECT*` and `*Agent Approvals: PROJECT*` to see the
request and decision records, then add the smallest explicit grant or policy
change needed for the experiment.

If portable R7RS tests are skipped, install Chibi Scheme or set
`AGENT_SCHEME_CHIBI` to the executable path. Missing optional reference
implementations are reported as unsupported references for oracle work and do
not make the default `make test` command fail.

## Non-Emacs Status

Emacs is the supported first host and current first-use path. The portable R7RS
implementation under `scheme/agent-scheme/` is a first-class implementation
path and is exercised through the test suite where practical, but the native
CLI and daemon adapter is currently a specified host contract rather than a
general user entry point.

The native CLI/daemon contract defines planned terminal, batch, and daemon
behavior, including capability libraries, handles, prompt policy, result
records, event records, audit records, and test strategy. Until executable CLI
or daemon slices land, use the Emacs REPL for interactive first-use evaluation.
