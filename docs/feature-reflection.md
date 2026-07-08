# Feature and Host Reflection

Consent Scheme programs should prefer capability discovery over hard-coded host
identity. The runtime supports portable Scheme first, then exposes host-specific
surfaces as explicit libraries and Scheme-readable adapter data.

Use this order when a program needs to adapt to what is available.

## Static Library Selection

Use R7RS `cond-expand` with `(library ...)` feature requirements when code must
choose imports or definitions before runtime execution.

```scheme
(define-library (consent examples host-aware)
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
Consent Scheme may report features such as:

```scheme
(r7rs ratios exact-complex ieee-float consent)
```

The feature list answers questions such as "does this implementation advertise
R7RS?" or "is this Consent Scheme?" It should not be used to distinguish Emacs
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
     (library (consent capability)))))

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
    ((runtime consent)
     (version-source-file "scheme/consent/version.sld")
     (version-binding consent-version-datum)
     (version-source roadmap-derived)))
  (provides
    ((library (emacs buffer))
     (library (consent capability)))))
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

`(agent reflect)` exposes read-only snapshots of the active Consent Scheme
runtime. It is for diagnostics, adaptive helper libraries, and agent-authored
scripts that need to understand their current authority and budget before
choosing what to do next.

For a compact API tour, see [Reflection Quickstart](reflection-quickstart.md).
For a step-by-step workflow that combines live bindings, registered libraries,
and manifest metadata, see
[Runtime Definition Discovery Tutorial](runtime-definition-discovery.md).

Current procedures:

- `(consent-version)` returns the canonical Consent Scheme runtime version
  datum, shaped as `(consent-version major minor ordinal)`.
  Components are exact non-negative integers. The current value is
  `(consent-version 0 17 35)`: the `major` and `minor` components come from
  the roadmap chunk's dotted number (`Chunk 0.17` → `0.17`), and `ordinal` is
  the issue's one-based position in that chunk. The major component is no longer
  hardcoded to `0`; a future `Chunk 1.x` line yields `1.x.x` versions while the
  datum shape stays the same. Strings such as `0.17.35` are derived presentation,
  not the canonical value. This scheme is roadmap-derived from #53, with
  completed chunks recorded in `docs/release-notes.md`.
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
  `documentation` metadata with origin `(primitive-manifest metadata)` when the
  manifest supplies rich fields, or `(primitive-manifest string)` for
  string-only manifest documentation; implementation docstrings remain a
  fallback for implementation-only or generated primitive hooks. Body-literal
  origin reports string, vector, or both literal forms; primitive
  implementation fallback reports
  `(implementation-procedure string)`; argument-only metadata reports
  `(signature)`.
- `(consent-doc subject)` returns the same `documentation-metadata` record as
  `(documentation subject)`. It is the scriptable replacement for REPL
  `:doc`-style sigils, so callers get ordinary Scheme-readable data in
  interactive, `--script`, and shebang runs.
- `(consent-describe subject)` returns a `binding-description` record for a
  binding symbol/name or procedure value, or `#f` when the subject cannot be
  described. The record includes `subject`, `binding-kind`, `value-kind`,
  `library`, `source`, a string `value-summary`, and a nested
  `documentation` field when metadata is available.
- `(current-policy)` returns the active policy category actions and per-run
  overrides.
- `(current-budget)` returns the evaluation budget ledger: the used count and
  ceiling for every enforced and reserved dimension (steps, host calls, events,
  event nodes, value nodes, output bytes, wall time) plus a `reason` field
  naming the dimension that stopped the run, or `#f` while the run is still
  admissible. See [budgets.md](budgets.md) for the full ledger shape.
- `(budget-remaining)` returns the same ledger expressed as remaining headroom
  (`limit - used`) per enforced dimension; an unbounded dimension reports `#f`.
- `(budget-exhausted? condition)` reports whether a condition datum or an
  evaluation-result error datum is a budget-exhaustion stop receipt.
- `(budget-yield)` emits the current budget ledger as a yield event (so an agent
  loop can observe remaining budget mid-run) and returns it.
- `(with-budget spec body ...)` evaluates `body` under a budget tightened by the
  `(budget ...)` `spec` for that dynamic extent. See [budgets.md](budgets.md).
- `(current-imports)` returns the libraries registered in the current
  evaluation context.
- `(libraries)` returns manifest-backed `library-info` records for repo-owned
  libraries known to the runtime. Each record includes `name`, `category`,
  `status`, `source-kind`, `visibility`, `availability`,
  `availability-condition`, `source-file`, `aliases`, `target`, `exports`,
  `dependencies`, `origin`, `source-id`, and `summary` fields. The public and
  internal visibility vocabulary is documented in
  [Library Surface and Manifests](library-surface.md).
- `(library-info library-name)` returns one `library-info` record or `#f` when
  the library name is not cataloged.
- `(library-search query)` searches cataloged library names, aliases,
  categories, source paths, and exports, returning matching `library-info`
  records.
- `(catalog-sources)` returns `catalog-source` records for the active catalog
  inputs in deterministic precedence order. The built-in seed is always present;
  ad-hoc manifests and explicit manifest-root inputs appear ahead of it.
- `(catalog-diagnostics)` returns Scheme-readable diagnostics from the most
  recent catalog build, including duplicate-library diagnostics when a higher
  precedence source shadows a later source.
- `(add-manifest! source-id manifest)` and
  `(remove-manifest! source-id)` add, replace, and remove explicit ad-hoc
  manifest datums. A manifest is a `(library-catalog ...)` datum containing
  `manifest-entry` and `manifest-index-entry` records; it is validated before
  it affects discovery.
- `(add-manifest-root! root manifest)` and
  `(remove-manifest-root! root)` add, replace, and remove explicit
  manifest-root inputs supplied as Scheme-readable manifest datums. These
  operations update discovery metadata only; they do not grant authority to
  import, load, or execute source.
- `(refresh-library-catalog!)` clears cached catalog views and diagnostics.
- `(library-bindings library-name)` returns the currently registered exported
  bindings for an imported library.
- `(library-documentation library-name)` resolves a cataloged library in a
  private reflection context and returns documentation records for documented
  exports without adding the library to the caller's current imports.
- `(binding-libraries symbol-or-name)` returns cataloged or currently
  registered libraries that export the requested binding. This includes
  ad-hoc libraries defined in the current evaluator context without manifest
  metadata.
- `(documented-bindings)` returns documentation records for documented
  bindings in the current interaction environment.
- `(apropos query)` searches definitions first, combining current documented
  bindings with catalog exports and currently registered library exports, and
  returns `apropos-match` records for matching bindings. Each match carries
  library provenance when the catalog or current evaluator context can identify
  exporting libraries. Library-container discovery remains the responsibility
  of `library-search`.
- `(reflection-field record field [default])`,
  `(documentation-field documentation field [default])`, and
  `(docstring subject [default])` are helper accessors for Scheme-readable
  reflection records. A present field whose value is `#f` remains `#f`; the
  default is used only when the field or documentation is absent.
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

- `(consent-version)` reports the roadmap-derived runtime version as
  `(consent-version 0 17 35)`, and the Emacs host-adapter fixture points
  at `scheme/consent/version.sld` as the single source of truth for the
  runtime version datum.
- R7RS `cond-expand` library requirements are available for implemented
  libraries.
- `(features)` reports implementation-level feature identifiers, including
  `consent`.
- Emacs capability libraries are registered under `(emacs ...)` names.
- The Emacs host-adapter declaration and capability manifest fixture is checked
  in as `fixtures/host-adapters/emacs.scm`.
- `(agent reflect)` exposes capability, documentation, policy, budget, import,
  manifest-backed library catalog, library discovery, binding crosswalk,
  session, macro expansion, recent yield, recent error, and recent
  policy-decision snapshots.
- Runtime source-file enumeration is derived from the same catalog seed used by
  library discovery, keeping the builder's embedded-source manifest and
  reflection metadata on one repo-owned path list.
- Ad-hoc manifest datums and explicit manifest-root inputs can be added,
  inspected, refreshed, and removed at runtime. They participate in discovery
  precedence and duplicate diagnostics, but remain metadata-only.

Tracked follow-up work:

- #229 adds the native CLI/daemon `host-adapter` declaration fixture and
  portable validator.
- #235 exposes current host-adapter and capability reflection to Scheme.
- #236 adds reusable host-adapter introspection conformance for future adapter
  contracts.
