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

- R7RS `cond-expand` library requirements are available for implemented
  libraries.
- `(features)` reports implementation-level feature identifiers, including
  `agent-scheme`.
- Emacs capability libraries are registered under `(emacs ...)` names.

Tracked follow-up work:

- #229 adds the native CLI/daemon `host-adapter` declaration fixture and
  portable validator.
- #234 adds the Emacs `host-adapter` declaration fixture.
- #235 exposes current host-adapter and capability reflection to Scheme.
- #236 adds reusable host-adapter introspection conformance for future adapter
  contracts.
