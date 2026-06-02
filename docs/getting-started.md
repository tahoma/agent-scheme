# Getting Started

This guide covers the currently supported first-use path for Consent Scheme from a
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

- Chibi Scheme, `chibi-scheme`, for optional portable R7RS Chibi checks and
  default oracle use
- Sagittarius, `sagittarius`, for default oracle comparisons
- Gauche, Guile, Racket with the `r7rs` package, and CHICKEN with the `r7rs`
  egg for additional developer-only oracle comparisons

## Checkout Setup

Clone the repository and enter the checkout:

```sh
git clone git@github.com:tahoma/agent-scheme.git
cd consent
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
(add-to-list 'load-path (expand-file-name "lisp" "/path/to/consent/"))
(require 'consent-repl)
```

Then run:

```text
M-x consent-start-repl
```

`consent-start-repl` defaults to a project session. From this repository,
the visible buffers normally use the project label `consent`, such as
`*Agent: consent*` and `*Consent Scheme: consent*`.

The native dispatch menu is bound to:

```text
C-c a
```

It includes commands for starting or switching sessions, inspecting or stopping
sessions, opening session buffers, and evaluating source in the current session.

## First Evaluation

After starting the REPL, run:

```text
M-x consent-repl-eval
```

Enter a pure Scheme expression:

```scheme
(+ 1 2)
```

The command evaluates the source in the current session and refreshes the native
session buffers. The REPL transcript buffer records the source and result as a
Scheme-readable `transcript-event`.

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
  --eval "(require 'consent-repl)" \
  --eval "(require 'consent-result)" \
  --eval "(consent-start-repl 'named \"getting-started\")" \
  --eval "(princ (consent-result->external (consent-repl-eval-source \"(import (scheme base) (agent io)) (define saved-answer 21) (agent-yield '(ready)) (+ saved-answer saved-answer)\")))"
```

Expected output:

```text
42
```

## Session Buffer Map

`consent-start-repl` creates a native, non-vterm buffer set for the active
session:

| Buffer | Role |
| --- | --- |
| `*Agent: PROJECT*` | Status and session record view. This is the primary state view for imports, definitions, memory references, handles, status, transcript references, and recent events. |
| `*Consent Scheme: PROJECT*` | Persistent REPL transcript. Evaluations appear as summarized Scheme-readable `transcript-event` datums. |
| `*Agent Events: PROJECT*` | Recent `(agent io)` events, such as `agent-yield`, `agent-log`, progress, warnings, and request records. |
| `*Agent Audit: PROJECT*` | Session-scoped audit entries for lifecycle transitions, evaluations, policy decisions, approval records, and capability activity. |
| `*Agent Approvals: PROJECT*` | Pending and resolved approval request datums for effects that need host or user confirmation. Pure examples normally leave this buffer empty. |

Each buffer includes a mode-line status indicator in the form:

```text
Agent[SESSION:STATUS]
```

Memory is represented in the session record and through `(agent memory)` when
that library is imported. Editable memory buffers are separate from the REPL
buffer set; after loading `consent-memory`, use `M-x
consent-memory-open` to inspect instance, session, or project memory as
Scheme-readable data.

Plans are represented through `(agent plan)` when that library is imported.
Use `plan-create!`, `plan-step-status!`, and `plan-yield` to share an editable
project or session plan with the outer loop. See [First-Class Plans](plans.md)
for a REPL example and the canonical plan datum shape.

## Context-Driven Helpers

The `(agent context)` library exposes the current request, editor focus,
region, buffer, project, and conversation summary as ordinary datums. This lets
helpers reason over what the user is doing without receiving raw Emacs objects
or protocol-specific payloads:

```scheme
(import (scheme base)
        (agent context))

(current-request)
(current-focus)
(current-region-context)
(current-buffer-context)
(current-project-context)
(current-conversation-summary)
```

Region and buffer records include source metadata such as the opaque buffer
handle, file path, point or region range, line number, and current line or
selected text. Project records include the project root. If a buffer is marked
local-only by the host, the context record carries `(local-only #t)` and is not
safe for provider routing unless an explicit provider policy override allows
that disclosure.

Context can be yielded back to the session event stream:

```scheme
(import (scheme base)
        (agent context))

(context-yield 'buffer)
(context-yield '(request project conversation-summary))
```

To keep context intentionally, store the datum through `(agent memory)` instead
of relying on implicit persistence:

```scheme
(import (scheme base)
        (agent context)
        (agent memory))

(memory-put! 'instance 'last-focus (current-focus))
```

## Local Model Providers

The `(agent models)` library provides the current model-facing entry point.
It can register provider profiles, inspect the routing decision for a role, and
run a local OpenAI-compatible completion request:

```scheme
(import (scheme base)
        (agent models))

(model-provider-register!
 '(model-provider
   (id local-llama)
   (kind local)
   (transport openai-compatible-http)
   (endpoint "http://127.0.0.1:11434/v1")
   (models
    (((id qwen-coder)
      (roles (scheme-scripter code))
      (privacy local))))))

(model-route 'scheme-scripter '())
(model-complete 'scheme-scripter "Write a small Scheme helper." '())
```

For the Emacs host, `model-complete` calls the selected local provider through
the OpenAI-compatible `/chat/completions` endpoint. Tests replace that transport
with a fake function, so CI does not require a running model server. The
portable Scheme implementation registers the same library and routing surface;
portable completion reports that no portable host transport is configured.

### Ollama Setup

Ollama is the simplest local OpenAI-compatible provider to use while this layer
is bootstrapping. Install Ollama for your platform, then pull a small model:

```sh
ollama pull qwen2.5-coder:0.5b
```

Start the local server if it is not already running:

```sh
ollama serve
```

Register that local server from Consent Scheme:

```scheme
(import (scheme base)
        (agent models))

(model-provider-register!
 '(model-provider
   (id local-qwen)
   (kind local)
   (transport openai-compatible-http)
   (endpoint "http://127.0.0.1:11434/v1")
   (models
    (((id qwen2.5-coder:0.5b)
      (roles (cheap-background scheme-scripter coder))
      (privacy local))))))

(model-complete 'scheme-scripter
                "What is 2 plus 3? Reply with only the numeral."
                '())
```

Larger local profiles can use the same provider shape with stronger model ids.
Useful starting points are `qwen2.5-coder:7b` or `qwen2.5-coder:14b` for
routine code work, `qwen2.5-coder:32b` for stronger code and review work,
`qwen3:8b` or `gemma3:12b` for summarization and explanation, and
`qwen3:30b`, `qwen3:32b`, or `llama3.1:70b` for slower planning or review
passes on machines with enough memory.

Suggested downloadable local model profiles by Consent Scheme role:

| Role | Practical local models |
| --- | --- |
| `planner` | `qwen3:30b`, `qwen3:32b`, `llama3.1:70b` |
| `scheme-scripter` | `qwen2.5-coder:7b`, `qwen2.5-coder:14b`, `qwen2.5-coder:32b` |
| `coder` | `qwen2.5-coder:14b`, `qwen2.5-coder:32b` |
| `reviewer` | `qwen2.5-coder:32b`, `qwen3:32b`, `llama3.1:70b` |
| `summarizer` | `gemma3:4b`, `gemma3:12b`, `qwen3:8b` |
| `memory-curator` | `qwen3:4b`, `qwen3:8b`, `gemma3:4b` |
| `cheap-background` | `qwen2.5-coder:0.5b`, `qwen3:0.6b`, `gemma3:1b` |
| `approval-explainer` | `qwen3:4b`, `qwen3:8b`, `gemma3:12b` |

To prepare the full suggested local model matrix with Ollama:

```sh
ollama pull qwen2.5-coder:0.5b
ollama pull qwen3:0.6b
ollama pull gemma3:1b
ollama pull qwen2.5-coder:7b
ollama pull qwen2.5-coder:14b
ollama pull qwen2.5-coder:32b
ollama pull qwen3:4b
ollama pull qwen3:8b
ollama pull qwen3:30b
ollama pull qwen3:32b
ollama pull llama3.1:70b
ollama pull gemma3:4b
ollama pull gemma3:12b
```

To run the same opt-in live local model smoke test used by CI, start an
OpenAI-compatible local server such as Ollama and run:

```sh
make test-live-model-ci
```

To run all live local model tests, including the full suggested local model
matrix after pulling those models, run:

```sh
make test-live-model
```

The test defaults to `http://127.0.0.1:11434/v1` and
`qwen2.5-coder:0.5b`. Override those with
`CONSENT_LIVE_MODEL_ENDPOINT` and `CONSENT_LIVE_MODEL_ID`.
The Make targets set `CONSENT_LIVE_MODEL_TEST=1`; `make test-live-model`
also sets `CONSENT_LIVE_MODEL_MATRIX=1`. The matrix test checks that each
documented local model completes through Consent Scheme's OpenAI-compatible
transport; it is not a quality or correctness benchmark.

Keep provider profiles and credentials in private Emacs initialization or an
ignored local file, then load them with `consent-models-register-provider!`
from `consent-models.el`. Do not commit provider tokens. Diagnostics from
`model-provider-diagnostics` redact credential-shaped fields before they appear
in Scheme-readable output.

Remote providers can be registered and inspected, but this bootstrap slice does
not ship a live remote transport. A completion routed to a remote provider must
pass the `remote-provider-routing` policy gate first, and local-only context is
denied before any transport can run.

## Policy and Capabilities

Consent Scheme keeps host authority explicit. Pure R7RS evaluation is allowed
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

Compile and test workflows use the Emacs compile adapter, but command execution
still goes through the shared process capability domain. The host policy must
allow or confirm `command-process`, and the exact command must be present in
the process command allow-list before Scheme code can start it. A minimal
approved `make test` workflow looks like:

```scheme
(import (scheme base)
        (consent capability)
        (emacs compile))

(grant-capability!
 '(capability-grant
   (id make-test-grant)
   (domain process)
   (operations (spawn observe output))
   (scope (command "make test"))
   (expires (uses 3))))

(define job
  (compile-run! "make test" '()))

(compile-status job)
(compile-output job '((max-chars 4000)))
```

`compile-run!`, `project-compile!`, and `recompile!` return opaque process-job
handles. `compile-status`, `compile-output`, and `compile-yield` return or emit
Scheme-readable datums that include the command, process status, exit status
when available, output text, truncation status, and parsed Emacs
`compilation-mode` error locations where Emacs can identify them.

## Verification

The default local verification command is:

```sh
make test
```

For documentation-only changes, also run:

```sh
git diff --check
rg -n "m[y]/consent|m[y]/mcp" README.md docs
```

The `rg` command should normally return no matches. If documentation changes
include the repository skill bundle, also scan `skills/` with the same pattern.

Optional portable and oracle checks use installed R7RS implementations. Chibi
checks can be run explicitly when Chibi Scheme is available:

```sh
CONSENT_CHIBI=chibi-scheme make test-portable-chibi
```

Pure shared fixtures can be compared against reference implementations:

```sh
make conformance-oracle
```

Use the environment variables listed by `make help` to select specific oracle
references or report statuses.

## Troubleshooting

If `require` cannot find `consent-repl`, confirm that the checkout's
`lisp/` directory is on `load-path`. In a fresh Emacs session, this form should
point at the local checkout:

```elisp
(add-to-list 'load-path (expand-file-name "lisp" "/path/to/consent/"))
```

If `M-x consent-start-repl` is unavailable, reload the module:

```elisp
(require 'consent-repl)
```

If a session seems stale, inspect the status buffer with `M-x
consent-inspect-session`, switch sessions with `M-x
consent-switch-session`, or retire the current session with `M-x
consent-stop-session`.

If a host-effecting example is denied, treat that as the expected safe posture.
Inspect `*Agent Audit: PROJECT*` and `*Agent Approvals: PROJECT*` to see the
request and decision records, then add the smallest explicit grant or policy
change needed for the experiment.

If optional Chibi checks are skipped, install Chibi Scheme or set
`CONSENT_CHIBI` to the executable path. Missing optional reference
implementations are reported as unsupported references for oracle work and do
not make the default `make test` command fail.

## Non-Emacs Status

Emacs is the supported first host and current first-use path. The portable R7RS
implementation under `scheme/consent/` is a first-class implementation
path and is exercised through the test suite where practical, but the native
CLI and daemon adapter is currently a specified host contract rather than a
general user entry point.

The native CLI/daemon contract defines planned terminal, batch, and daemon
behavior, including capability libraries, handles, prompt policy, result
records, event records, audit records, and test strategy. Until executable CLI
or daemon slices land, use the Emacs REPL for interactive first-use evaluation.
