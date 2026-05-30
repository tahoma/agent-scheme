# Feature and Host Reflection

Agent Scheme programs should prefer capability discovery over hard-coded host
identity. The runtime supports portable Scheme first, then exposes host-specific
surfaces as explicit libraries and Scheme-readable adapter data.

Use this order when a program needs to adapt to what is available.

## Static Library Selection

Use R7RS `cond-expand` with `(library ...)` feature requirements when code must
choose imports or definitions before runtime execution.

```scheme
(define-library (agent-scheme examples host-aware)
  (export host-kind)
  (import (scheme base))
  (cond-expand
    ((library (emacs buffer))
     (import (emacs buffer))
     (begin
       (define (host-kind) 'emacs)))
    ((library (cli process))
     (import (cli process))
     (begin
       (define (host-kind) 'native-cli-daemon)))
    (else
     (begin
       (define (host-kind) 'portable)))))
```

This is the right mechanism for library-dependent code because it is part of
the R7RS language. A missing host library should select another clause or a
portable fallback instead of failing at runtime.

## Implementation Features

Use `(features)` for implementation and language features, not host identity.
Agent Scheme may report features such as:

```scheme
(r7rs ratios exact-complex ieee-float agent-scheme)
```

The feature list answers questions such as "does this implementation advertise
R7RS?" or "is this Agent Scheme?" It should not be used to distinguish Emacs
from a native CLI daemon. Host adapters have richer structure than a flat
feature symbol can represent.

## Runtime Adapter Reflection

Runtime host inspection should use structured adapter and capability datums.
The intended `(agent reflect)` or `(agent context)` surface is:

```scheme
(current-host-adapter)
;; =>
(host-adapter
  (name native-cli-daemon)
  (modes (cli batch daemon))
  (provides
    ((library (cli process))
     (library (agent capability)))))

(current-host-capabilities)
;; =>
((host-capability
   (library (cli process))
   (name process-start)
   (authority process-control)
   (effect-path shared-capability-request)))
 ...)
```

This reflection path is for runtime decisions, diagnostics, helper scripts, and
agent-authored workflows. It should report what a host can mediate, not grant
permission by itself.

The checked-in Emacs fixture at `fixtures/host-adapters/emacs.scm` records
Emacs-specific facilities with the same `host-adapter` declaration shape as
other hosts:

```scheme
(host-adapter
  (name emacs)
  (contract r7rs-small)
  (implementation
    ((runtime agent-scheme)
     (version-source-file "scheme/agent-scheme/version.sld")
     (version-binding agent-scheme-version-datum)
     (version-source roadmap-derived)))
  (provides
    ((library (emacs buffer))
     (library (agent capability)))))
```

Future runtime reflection can consume this Scheme-readable declaration and its
capability manifest without exposing raw Emacs buffers, windows, frames,
processes, command objects, audit entries, secrets, or private local state.

Adapter reflection follows these rules:

- `host-adapter` records name the host, modes, provided libraries, mediated
  standard libraries, authority classes, handle kinds, prompt posture,
  validation suites, and effect path metadata.
- `host-capability` records name available libraries and bindings, argument and
  result shapes where known, policy categories, authority classes, and backend
  effect paths.
- Reflection datums never expose raw Emacs objects, native descriptors, daemon
  sockets, provider clients, secrets, buffer contents, or private local state.
- Availability is not authority. Capability use still goes through grants,
  policy decisions, stale-handle checks, and audit records.
- Programs should ask for the narrow capability they need. Host identity is a
  last resort for diagnostics or UX differences.

## Runtime Reflection Library

`(agent reflect)` exposes read-only snapshots of the active Agent Scheme
runtime. It is for diagnostics, adaptive helper libraries, and agent-authored
scripts that need to understand their current authority and budget before
choosing what to do next.

Current procedures:

- `(agent-scheme-version)` returns the canonical Agent Scheme runtime version
  datum, shaped as `(agent-scheme-version primary secondary tertiary)`.
  Components are exact non-negative integers. The initial value is
  `(agent-scheme-version 0 15 2)`: primary version `0`, secondary version
  `15` for the roadmap chunk, and tertiary version `2` for the issue's
  position in that chunk. Strings such as `0.15.2` are derived presentation,
  not the canonical value. This scheme is roadmap-derived for now and can
  change once Agent Scheme has an explicit release policy.
- `(current-capabilities)` returns public `host-capability` records from the
  primitive manifest. Capability records expose operational metadata; callers
  use `(documentation subject)` for the corresponding user-facing help text.
- `(capability-info symbol-or-name)` returns one matching `host-capability`
  record, or `#f` if the capability is unavailable.
- `(documentation subject)` returns a `documentation-metadata` record for a
  documented procedure binding or procedure value, or `#f` when the subject
  does not resolve to a procedure with metadata. `subject` may be a binding
  symbol, binding name string, or procedure value. The record exposes generated
  signature metadata through `arguments` plus canonical body-literal fields
  such as `documentation`, `parameters`, `returns`, `effects`, `examples`, and
  `see-also`. Public primitive manifest entries carry manifest
  `documentation` metadata with origin `(primitive-manifest string)`;
  implementation docstrings remain a fallback for implementation-only or
  generated primitive hooks. Body-literal origin reports string, vector, or
  both literal forms; primitive implementation fallback reports
  `(implementation-procedure string)`; argument-only metadata reports
  `(signature)`.
- `(current-policy)` returns the active policy category actions and per-run
  overrides.
- `(current-budget)` returns evaluator step, host-call, event, event-node, and
  value-node counters and limits.
- `(current-imports)` returns the libraries registered in the current
  evaluation context.
- `(current-session-info)` returns public session/job identity and event count
  information for the current evaluation.
- `(recent-yields)`, `(recent-errors)`, and `(recent-policy-decisions)` return
  recent event and audit data useful for debugging scripts.
- `(macroexpand form)`, `(macroexpand-1 form)`, `(macroexpand-library name)`,
  `(macro-binding-info identifier)`, `(syntax-source datum)`, and
  `(macroexpand-yield form options)` expose macro expansion debugging data.
  See [macro-introspection.md](macro-introspection.md) for the REPL workflow and
  record shape.

Reflection data is Scheme-readable data. It does not expose raw Emacs objects,
native descriptors, provider clients, credentials, hidden model internals, or
private host structures. Returned event and audit data is redacted at the
reflection boundary, so secret-prone fields such as tokens, API keys, passwords,
authorization headers, and local-only context are replaced with redaction
records before the caller sees them.

An agent script can combine reflection with `(agent io)` to yield a diagnostic
snapshot:

```scheme
(import (scheme base)
        (agent io)
        (agent reflect))

(define file-metadata (capability-info 'file-exists?))

(define (snapshot-note)
  "Return whether file metadata is visible in this runtime."
  (if file-metadata #t #f))

(define doc-metadata (documentation 'snapshot-note))

(agent-yield
 (list 'runtime-snapshot
       (list 'file-metadata-available (snapshot-note))
       (list 'snapshot-note-doc doc-metadata)
       (current-budget)
       (current-imports)
       (recent-policy-decisions)))
```

Availability is still not authority. A `host-capability` record tells Scheme
code that a binding exists and describes its policy path; calling the capability
still goes through grants, policy checks, redaction, and audit.

## Host Effects

Once code calls a host capability, all hosts use the same effect path:

```scheme
(capability-request ...)
(capability-decision ...)
(capability-audit ...)
```

This applies whether the backing runtime is Emacs Lisp, an interpreted native
CLI adapter, a long-lived daemon, or a future compiled backend. A host may
display approvals differently or own different handle kinds, but the Scheme
boundary remains Scheme-readable data.

## Current Implementation Status

Current implemented pieces:

- `(agent-scheme-version)` reports the roadmap-derived runtime version as
  `(agent-scheme-version 0 15 2)`, and the Emacs host-adapter fixture points
  at `scheme/agent-scheme/version.sld` as the single source of truth for the
  runtime version datum.
- R7RS `cond-expand` library requirements are available for implemented
  libraries.
- `(features)` reports implementation-level feature identifiers, including
  `agent-scheme`.
- Emacs capability libraries are registered under `(emacs ...)` names.
- The Emacs host-adapter declaration and capability manifest fixture is checked
  in as `fixtures/host-adapters/emacs.scm`.
- `(agent reflect)` exposes capability, documentation, policy, budget, import,
  session, macro expansion, recent yield, recent error, and recent
  policy-decision snapshots.

Tracked follow-up work:

- #229 adds the native CLI/daemon `host-adapter` declaration fixture and
  portable validator.
- #235 exposes current host-adapter and capability reflection to Scheme.
- #236 adds reusable host-adapter introspection conformance for future adapter
  contracts.
