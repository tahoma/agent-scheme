# Agent Scheme

Agent Scheme is an R7RS-small guest language and agentic REPL design whose first host is Emacs.

The project goal is to give agents and users a Lisp-native scripting environment with:

- R7RS-small compliance from the start, including macros and `define-library`
- Scheme-readable datums for memory, plans, transcripts, approvals, skills,
  rules, and audit records
- explicit host capabilities instead of unrestricted host access
- Emacs as the first host adapter, not the semantic center
- a first-class portable Scheme implementation that can grow into a native
  reader, evaluator, emitter, and REPL path
- portable libraries and self-scripting workflows that can eventually run in
  other UI environments

## Current Status

The implementation roadmap lives in GitHub issues, starting with the architecture and dependency-graph issues.

The initial R7RS-small compliance target is tracked in
[docs/r7rs-conformance.md](docs/r7rs-conformance.md). Pure `(scheme base)`
forms and the standard pure libraries are exercised through `make test`.
Libraries that observe or mutate host state, such as `(scheme file)`,
`(scheme load)`, `(scheme process-context)`, `(scheme repl)`, `(scheme time)`,
and current/default ports, are importable where appropriate but default to
policy-gated behavior.

SRFI support is not part of the R7RS-small compliance contract. Optional SRFI
libraries belong to a future `stdlib-plus` layer tracked separately in
[tahoma/agent-scheme#54](https://github.com/tahoma/agent-scheme/issues/54), so
SRFI import failures should not be read as R7RS-small conformance failures.

The multi-host bootstrap strategy lives in
[docs/multi-host-bootstrap.md](docs/multi-host-bootstrap.md). It records how
Emacs remains the first host adapter while R7RS-small remains the portable
language contract for future Scheme implementations, compiled backends, and
non-Emacs UI surfaces.

## Design Rules

- Think in Lisp/Scheme first for internal APIs and examples.
- Keep canonical runtime state inspectable as Scheme data.
- Use JSON, HTTP, Markdown, and other encodings at protocol or document boundaries, not as the internal model.
- Keep host adapters severable. Emacs is the first body; Agent Scheme should have a portable core.
- Keep Emacs Lisp and portable R7RS Scheme architecture in parity for core
  language behavior.
- Prefer conservative, audited capabilities over broad host access.
- Use the Agent Scheme project namespace for durable Emacs Lisp APIs and docs.

## Repository Shape

This seed is intentionally small. Initial implementation modules and documentation should follow the GitHub roadmap.

## Examples

R7RS-small library imports and ordinary macros:

```scheme
(import (scheme base)
        (scheme case-lambda)
        (scheme char)
        (scheme write))

(define-syntax unless
  (syntax-rules ()
    ((unless test body ...)
     (if test #f (begin body ...)))))

(define describe
  (case-lambda
    ((value)
     (let ((out (open-output-string)))
       (unless (char-ci=? #\a #\A)
         (error "character folding unavailable"))
       (write value out)
       (get-output-string out)))
    ((label value)
     (string-append label ": " (describe value)))))
```

Optional SRFI imports should be guarded so portable R7RS-small code still runs
when the `stdlib-plus` layer is unavailable:

```scheme
(define-library (agent-scheme examples optional-srfi)
  (export sample)
  (import (scheme base))
  (cond-expand
    ((library (srfi 1))
     (import (srfi 1)))
    (else))
  (begin
    (define sample '(1 2 3))))
```

Emacs capability libraries are separate from standard Scheme libraries and are
subject to host policy. Adapter-provided procedures can be imported beside
ordinary Scheme code when the host enables them:

```scheme
(define-library (agent-scheme examples hosted)
  (export summarize-buffer)
  (import (scheme base)
          (scheme write)
          (emacs buffer))
  (begin
    (define-syntax with-default
      (syntax-rules ()
        ((with-default fallback expression)
         (guard (exn (else fallback))
           expression))))

    (define (summarize-buffer)
      (with-default
       "buffer access denied by policy"
       (let ((out (open-output-string)))
         (write (buffer-name (current-buffer)) out)
         (get-output-string out)))))))
```

Approval requests are also Scheme data.  Scheme code can request, inspect, and
yield approvals, while host-side resolution remains denied by default unless
policy explicitly permits automation:

```scheme
(import (scheme base)
        (agent approval))

(define edit-approval
  (approval-request!
   '(approval-request
      (policy buffer-edit)
      (effect (buffer-replace! h-12 120 140 "new text"))
      (reason "Replace deprecated helper name?"))))

(approval-status edit-approval)
```

In Emacs project sessions, pending and resolved records appear in
`*Agent Approvals: PROJECT*` as Scheme-readable approval datums.

Diff records are portable trust data.  `(agent diff)` owns the canonical datum
shape, proposed-edit previews, unified rendering, and event-channel yield;
`(emacs diff)` produces the same records from live Emacs buffers, files, and
projects:

```scheme
(import (scheme base)
        (agent approval)
        (agent diff)
        (emacs buffer)
        (emacs diff))

(define handle (emacs-current-buffer))

(define preview
  (proposed-edit-diff
   '(proposed-edit
     (source buffer)
     (old-label "before")
     (new-label "after")
     (start 120)
     (end 140)
     (before "deprecated-helper")
     (after "current-helper"))))

(diff-yield preview)

(approval-request!
 `(approval-request
   (policy buffer-edit)
   (effect (buffer-replace! ,handle 120 140 "current-helper"))
   (diff ,preview)
   (reason "Replace deprecated helper name?")))

(diff-render-unified (buffer-diff handle))
```

Capability grants narrow approved authority before a mutating host capability
can use it:

```scheme
(import (scheme base)
        (agent capability)
        (emacs buffer)
        (emacs buffer edit))

(define handle (emacs-current-buffer))

(grant-capability!
 `(capability-grant
   (id region-edit)
   (library (emacs buffer edit))
   (effect buffer-replace!)
   (scope (buffer ,handle) (range 120 140))
   (expires after-eval)
   (reason "Apply approved region edit.")))

(buffer-replace! handle 120 140 "new text")
```

Read-only search capabilities return Scheme-readable source locations that can
be yielded back to the agent event stream:

```scheme
(import (scheme base)
        (emacs buffer)
        (emacs search))

(define matches
  (buffer-search
   (emacs-current-buffer)
   "define-library"
   '((limit 20))))

(search-yield matches)
```

Project search uses the active Emacs project and skips generated directories,
large files, and binary files by default:

```scheme
(import (emacs search))

(project-search
 "define-library"
 '((limit 50)
   (max-file-bytes 1048576)))
```

Skills can declare requested grants as data without receiving them
automatically:

```yaml
requested-grants: ((capability-grant (library (emacs buffer edit)) (effect buffer-replace!) (scope (skill refactor-helper) (range 120 140)) (expires after-eval)))
```

## Project Docs

- [Repository agent instructions](AGENTS.md)
- [Project skill bundle](skills/README.md)
- [Architecture and threat model](docs/architecture.md)
- [Feature and host reflection](docs/feature-reflection.md)
- [Debugger workflow](docs/debugger.md)
- [Multi-host adapter and bootstrap strategy](docs/multi-host-bootstrap.md)
- [Native CLI and daemon adapter contract](docs/native-cli-daemon-adapter.md)
- [Scheme references](docs/references.md)
- [R7RS-small report reference](docs/r7rs-small-report.md)
- [R7RS-small conformance matrix](docs/r7rs-conformance.md)
- [Contributing](docs/contributing.md)
- [Development setup](docs/development.md)
- [Naming convention](docs/naming.md)
- [GitHub issue taxonomy](docs/issue-taxonomy.md)
- [Roadmap note](docs/roadmap.md)
