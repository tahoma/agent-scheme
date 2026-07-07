# Runtime Core Diagrams

This page is a visual companion to
[Architecture and Threat Model](architecture.md) and
[Multi-Host Adapter and Bootstrap Strategy](multi-host-bootstrap.md). The
Mermaid blocks below are the primary editable source for these diagrams: they
render in GitHub preview, stay reviewable as text, and should be updated
alongside the modules they describe.

The diagrams describe the current runtime architecture. They do not introduce a
new implementation contract beyond the linked architecture documents.

## Static Rendering Decision

No static SVG or PNG renderings are committed for these diagrams yet. Mermaid
source is the authoritative artifact, and committing generated images now would
add renderer-version churn, binary diffs, and extra SPDX/REUSE bookkeeping before
the repository has an offline manual or PDF documentation pipeline that needs
them.

When static renderings become useful, generate them as derived artifacts under
`docs/assets/diagrams/` with stable names matching these section anchors, record
the Mermaid source as authoritative, and update the asset README plus
`REUSE.toml` as needed. A future rendering pass should pin the Mermaid CLI
version and render each fenced block from this page into the matching asset
file.

## Portable Scheme Runtime Core

The portable runtime side keeps `(consent eval)` thin. Most public evaluation,
REPL, and result-producing entry points are owned by `(consent interpreter)`,
while resolver modules stay loadable by receiving backend hooks after the
interpreter is loaded.

```mermaid
flowchart TD
  user["Portable callers<br/>Scheme source or datums"]

  eval["(consent eval)<br/>scheme/consent/eval.sld<br/>thin public facade"]
  interpreter["(consent interpreter)<br/>scheme/consent/interpreter.sld<br/>eval entry points, trampoline,<br/>procedure application, primitives,<br/>REPL contexts, result-producing eval"]

  reader["(consent reader)<br/>lexical reading, datum validation,<br/>recovery, source metadata,<br/>canonical datum support"]
  runtime["(consent runtime)<br/>runtime values, environments,<br/>syntax contexts, ports, budgets,<br/>embedded source, registries,<br/>eval context state"]
  base["(consent base)<br/>(scheme base) primitive metadata,<br/>base prelude loading,<br/>base syntax bootstrap hooks"]
  library["(consent library)<br/>imports, define-library,<br/>source/native resolution,<br/>library registration"]
  macro["(consent macro)<br/>syntax environments,<br/>syntax-rules, macro expansion,<br/>syntax definitions"]
  result["(consent result)<br/>stable external result datums"]

  shared["Shared manifests and source libraries<br/>scheme/manifest/index.sld<br/>scheme/*/manifest.sld<br/>scheme/consent/*.sld<br/>scheme/stdlib/*.sld<br/>scheme/agent/*.sld"]

  user --> eval
  eval --> interpreter
  interpreter --> reader
  interpreter --> runtime
  interpreter --> result
  interpreter --> base
  interpreter --> library
  interpreter --> macro
  library --> shared
  base --> shared

  interpreter -. "installs base backend hooks<br/>primitive resolution, prelude eval,<br/>syntax definition" .-> base
  interpreter -. "installs library backend hooks<br/>primitive resolution, body eval,<br/>syntax env construction and lookup" .-> library
  interpreter -. "installs native applier<br/>for callbacks from source libraries" .-> runtime

  classDef facade fill:#eef7ff,stroke:#3d6f9f,color:#102a43
  classDef backend fill:#f3f0ff,stroke:#6b5fb5,color:#24164f
  classDef pass fill:#ecfdf3,stroke:#438a5e,color:#143923
  classDef source fill:#fff8df,stroke:#a97912,color:#3d2b04
  class eval facade
  class interpreter backend
  class reader,runtime,base,library,macro,result pass
  class shared source
```

## Emacs Lisp Twin

The Emacs Lisp implementation mirrors the same semantic spine, but
`consent-eval.el` is larger because it is also the first host adapter
orchestration surface. Host-facing policy, audit, stream, capability, session,
and approval behavior lives around the evaluator rather than inside portable
Scheme semantics.

```mermaid
flowchart TD
  callers["Emacs commands, tests,<br/>REPLs, MCP integration"]

  eval["lisp/consent-eval.el<br/>public evaluator orchestration"]
  interp["lisp/consent-interpreter.el<br/>trampoline, application,<br/>primitive implementations,<br/>Scheme-readable result records"]

  reader["lisp/consent-reader.el"]
  runtime["lisp/consent-runtime.el"]
  base["lisp/consent-base.el"]
  library["lisp/consent-library.el"]
  macro["lisp/consent-macro.el"]
  result["lisp/consent-result.el"]

  host["Host orchestration around eval<br/>policy authorization, audit records,<br/>capability expiry, standard streams,<br/>persistent sessions, REPL contexts"]

  adapters["Adapter and agent modules<br/>approval, audit, capability, context,<br/>diagnostics, diff, helper, job, memory,<br/>models, plan, policy, redaction,<br/>reflect, session, transcript, VCS"]

  shared["Shared Scheme source loaded<br/>through lisp/consent-library.el<br/>scheme/consent/*.sld<br/>scheme/stdlib/*.sld<br/>scheme/agent/*.sld"]

  callers --> eval
  eval --> interp
  eval --> host
  host --> adapters

  interp --> reader
  interp --> runtime
  interp --> base
  interp --> library
  interp --> macro
  interp --> result

  library --> shared
  adapters --> shared

  classDef facade fill:#eef7ff,stroke:#3d6f9f,color:#102a43
  classDef host fill:#fff1f1,stroke:#bb4b4b,color:#4a0d0d
  classDef backend fill:#f3f0ff,stroke:#6b5fb5,color:#24164f
  classDef pass fill:#ecfdf3,stroke:#438a5e,color:#143923
  classDef source fill:#fff8df,stroke:#a97912,color:#3d2b04
  class eval facade
  class host,adapters host
  class interp backend
  class reader,runtime,base,library,macro,result pass
  class shared source
```

## Evaluation Pipeline

Evaluation accepts either source text or already-read datums. Entry points that
raise host errors and entry points that return `evaluation-result` datums share
the same reader, resolver, macro, trampoline, primitive-dispatch, and rendering
path; only the error boundary changes.

```mermaid
sequenceDiagram
  participant Caller as Caller
  participant Reader as Reader
  participant Context as Eval context
  participant Base as Base syntax
  participant Library as Library resolver
  participant Macro as Macro expander
  participant Eval as Trampoline evaluator
  participant Result as Result renderer
  participant Host as Host state

  Caller->>Reader: source string
  Caller->>Eval: already-read datum
  Reader-->>Eval: form sequence
  Eval->>Context: create fresh eval context and budgets
  Context->>Host: connect current input, output, and error ports
  Eval->>Base: install base syntax and prelude
  Eval->>Library: resolve imports and define-library forms
  Library-->>Eval: value and syntax bindings
  Eval->>Macro: expand syntax and body forms
  Macro-->>Eval: expanded forms
  Eval->>Eval: trampoline execution
  Eval->>Eval: procedure application and primitive dispatch
  Eval->>Host: expire after-eval capability grants
  Eval->>Result: render value, condition, events, and budget fields
  Result-->>Caller: evaluation-result datum for result entry points
  Eval-->>Caller: value or raised host error for raising entry points

  Note over Context,Host: Cross-cutting state includes budgets, current ports,<br/>capability expiry, events, and condition capture.
```

## Library Resolution Flow

Library resolution is part of the frontend because imports install both value
bindings and syntax bindings. Source-backed libraries loaded by both hosts are
one shared implementation, not two copies that require parity testing against
each other.

```mermaid
flowchart TD
  input["import declaration<br/>or define-library form"]
  key["Normalize library key"]
  importset["Apply import-set operators<br/>only, except, prefix, rename,<br/>cond-expand"]

  base["(scheme base)<br/>environment snapshot"]
  standard["Standard library subsets<br/>and primitive wrappers"]
  source["Source-backed .sld libraries<br/>scheme/consent, scheme/stdlib,<br/>scheme/agent"]
  native["Native or primitive libraries<br/>runtime and library registries"]

  values["Install value bindings<br/>into value environment"]
  syntax["Install syntax bindings<br/>into syntax environment"]

  hooks["Backend callbacks from interpreter<br/>evaluate library bodies,<br/>construct syntax environments,<br/>syntax lookup, scoped syntax execution"]

  shared["Single shared implementation<br/>both hosts load the same source"]
  dual["Irreducible dual-core path<br/>reader, evaluator, macro,<br/>base primitives, host-effect adapters"]

  input --> key --> importset
  importset --> base
  importset --> standard
  importset --> source
  importset --> native

  base --> values
  standard --> values
  source --> values
  native --> values
  base --> syntax
  standard --> syntax
  source --> syntax

  hooks -. "cycle-breaking support" .-> source
  hooks -. "construct resolver environments" .-> syntax

  source --> shared
  native --> dual

  classDef input fill:#eef7ff,stroke:#3d6f9f,color:#102a43
  classDef source fill:#fff8df,stroke:#a97912,color:#3d2b04
  classDef env fill:#ecfdf3,stroke:#438a5e,color:#143923
  classDef hook fill:#f3f0ff,stroke:#6b5fb5,color:#24164f
  classDef dual fill:#fff1f1,stroke:#bb4b4b,color:#4a0d0d
  class input,key,importset input
  class base,standard,source,native source
  class values,syntax env
  class hooks hook
  class dual dual
```

## Host Boundary And Capability Flow

Pure Scheme data crosses into effects only through capability-backed libraries.
Raw Emacs buffers, windows, processes, filesystem handles, provider clients, and
other live host objects stay behind the adapter boundary.

```mermaid
sequenceDiagram
  participant Scheme as Scheme code
  participant Runtime as Runtime primitive
  participant Grants as Capability grants
  participant Policy as Policy and approval
  participant Adapter as Host adapter
  participant Audit as Audit and events

  Scheme->>Runtime: call capability-backed procedure
  Runtime->>Grants: lookup grant and attenuation
  Grants-->>Runtime: usable authority or revoked/expired denial
  Runtime->>Policy: request policy decision or confirmation
  Policy-->>Runtime: approve, deny, or require user decision
  Runtime->>Adapter: perform host operation if approved
  Adapter-->>Runtime: opaque handle or Scheme-readable value
  Runtime->>Audit: record request, decision, handle, result, or denial
  Runtime-->>Scheme: result datum or capability condition

  Note over Adapter: Live host objects remain in adapter side tables.<br/>Scheme receives handles and ordinary datums.
```

## Portable And Emacs Value Representation

The two implementations preserve mirrored semantics, but their host-level value
representations differ. The Emacs reader uses wrapper records for Scheme datums
that do not map cleanly onto Emacs Lisp host values. The portable Scheme
implementation can lean more on host Scheme datums, while still owning
Consent-specific records when semantics or stable external representation
require them.

```mermaid
flowchart LR
  semantics["Consent Scheme semantic value"]

  portable["Portable Scheme representation<br/>mostly host Scheme datums<br/>plus Consent-specific records"]
  emacs["Emacs Lisp representation<br/>host values plus wrapper records<br/>for Scheme-specific datums"]
  external["Stable external result datums<br/>(consent result)"]

  scalars["booleans, symbols, identifiers,<br/>numbers with lexical metadata,<br/>characters, EOF and error objects"]
  compounds["pairs, vectors, strings,<br/>bytevectors, records,<br/>record types"]
  runtime["ports, environments,<br/>syntax environments,<br/>syntax transformers,<br/>macro-introduced identifiers"]
  procedures["primitive, compound,<br/>parameter, continuation procedures"]
  handles["opaque handles<br/>not raw host objects"]
  results["evaluation-result datums<br/>status, values or error,<br/>events, budgets"]

  semantics --> scalars
  semantics --> compounds
  semantics --> runtime
  semantics --> procedures
  semantics --> handles
  semantics --> results

  scalars --> portable
  compounds --> portable
  runtime --> portable
  procedures --> portable
  handles --> portable
  results --> portable

  scalars --> emacs
  compounds --> emacs
  runtime --> emacs
  procedures --> emacs
  handles --> emacs
  results --> emacs

  portable --> external
  emacs --> external

  classDef semantic fill:#eef7ff,stroke:#3d6f9f,color:#102a43
  classDef family fill:#ecfdf3,stroke:#438a5e,color:#143923
  classDef impl fill:#f3f0ff,stroke:#6b5fb5,color:#24164f
  classDef external fill:#fff8df,stroke:#a97912,color:#3d2b04
  class semantics semantic
  class scalars,compounds,runtime,procedures,handles,results family
  class portable,emacs impl
  class external external
```

## REPL And Session Lifecycle

Durable interaction contexts keep definitions, imports, and macros across
submissions. Each submission still receives a fresh budgeted eval context, and
the submitted form is read separately from the evaluated program input stream.

```mermaid
flowchart TD
  submit["REPL submission"]
  lookup["Create or look up session"]
  durable["Durable interaction context"]
  value["Persistent value environment<br/>definitions and imports"]
  syntax["Persistent syntax environment<br/>macros and imported syntax"]
  stdin["Shared program input cursor<br/>stdin port"]
  output["Program output port"]
  evalctx["Fresh per-submission eval context<br/>budgets and event counters"]
  readform["Read submitted form"]
  program["Read evaluated program input<br/>from interaction stdin when requested"]
  eval["Evaluate through runtime pipeline"]
  result["Generate result record"]
  emacs["Emacs side updates<br/>transcript and session records"]

  submit --> lookup --> durable
  durable --> value
  durable --> syntax
  durable --> stdin
  durable --> output
  durable --> evalctx
  evalctx --> readform --> eval
  stdin --> program --> eval
  value --> eval
  syntax --> eval
  output --> eval
  eval --> result --> emacs
  result --> durable

  classDef durable fill:#fff8df,stroke:#a97912,color:#3d2b04
  classDef fresh fill:#eef7ff,stroke:#3d6f9f,color:#102a43
  classDef env fill:#ecfdf3,stroke:#438a5e,color:#143923
  classDef host fill:#fff1f1,stroke:#bb4b4b,color:#4a0d0d
  class durable,value,syntax,stdin,output durable
  class submit,lookup,evalctx,readform,program,eval,result fresh
  class emacs host
```

## Macro Expansion Lifecycle

The macro subsystem owns syntax environments, `syntax-rules`, local syntax
scopes, and body expansion. Imported syntax bindings are installed alongside
value bindings during library resolution.

```mermaid
flowchart TD
  base["Install base syntax"]
  imports["Resolve library imports"]
  importedSyntax["Install imported syntax bindings"]
  definitions["define-syntax<br/>let-syntax<br/>letrec-syntax"]
  lookup["Syntax environment lookup"]
  parse["Parse syntax-rules transformer"]
  match["Match pattern"]
  template["Expand template"]
  hygiene["Create hygienic identifier contexts"]
  body["Expand body definitions<br/>and expression forms"]
  evaluator["Hand expanded forms<br/>back to evaluator"]

  base --> importedSyntax
  imports --> importedSyntax
  importedSyntax --> lookup
  definitions --> lookup
  lookup --> parse --> match --> template --> hygiene --> body --> evaluator
  body -. "recursive expansion" .-> lookup

  classDef setup fill:#eef7ff,stroke:#3d6f9f,color:#102a43
  classDef macro fill:#ecfdf3,stroke:#438a5e,color:#143923
  classDef eval fill:#f3f0ff,stroke:#6b5fb5,color:#24164f
  class base,imports,importedSyntax setup
  class definitions,lookup,parse,match,template,hygiene,body macro
  class evaluator eval
```

## Bootstrap Hooks

The hook structure is deliberate. Base and library resolver modules need to be
loadable without directly importing the interpreter backend, but the base
prelude and source library bodies still evaluate through the same trampoline as
user code.

```mermaid
flowchart TD
  base["(consent base)<br/>loadable without evaluator import"]
  library["(consent library)<br/>loadable without evaluator import"]
  macro["(consent macro)<br/>syntax environment operations"]
  runtime["(consent runtime)<br/>native applier slot"]
  interpreter["(consent interpreter)<br/>backend owner"]

  baseHooks["Base backend hooks<br/>primitive resolution,<br/>prelude evaluation,<br/>syntax definition"]
  libHooks["Library backend hooks<br/>primitive resolution,<br/>policy-denied primitive construction,<br/>library-body trampoline evaluation,<br/>syntax-environment creation,<br/>syntax lookup,<br/>scoped syntax execution"]
  native["Native applier<br/>library procedures call<br/>interpreted callbacks"]
  trampoline["Shared trampoline path<br/>base prelude, source libraries,<br/>user code"]

  base --> baseHooks
  library --> libHooks
  runtime --> native

  interpreter -. "installs" .-> baseHooks
  interpreter -. "installs" .-> libHooks
  interpreter -. "installs" .-> native
  macro --> libHooks

  baseHooks --> trampoline
  libHooks --> trampoline
  native --> trampoline
  trampoline --> interpreter

  classDef resolver fill:#ecfdf3,stroke:#438a5e,color:#143923
  classDef backend fill:#f3f0ff,stroke:#6b5fb5,color:#24164f
  classDef hook fill:#fff8df,stroke:#a97912,color:#3d2b04
  classDef path fill:#eef7ff,stroke:#3d6f9f,color:#102a43
  class base,library,macro,runtime resolver
  class interpreter backend
  class baseHooks,libHooks,native hook
  class trampoline path
```

## Parity And Test Matrix

Cross-host agreement applies to the irreducible dual-core layer: reader,
evaluator, macro, runtime, base primitives, and host-effect adapter semantics.
Single-sourced `.sld` libraries drop out of dual-core parity scope because both
hosts load the same implementation.

```mermaid
flowchart TD
  corpus["Shared fixture corpus<br/>and portable Scheme tests"]
  makeTest["make test<br/>trimmed default local shard set"]
  parity["make test-parity<br/>Emacs and portable dual-core<br/>agreement gate"]

  emacs["Emacs-hosted runtime path<br/>ERT shards"]
  portable["Portable R7RS runtime path"]
  external["External Scheme host shards<br/>Gambit, Racket, Guile, Gauche,<br/>optional Chibi"]

  dual["Parity scope<br/>irreducible dual core:<br/>reader, evaluator, macro,<br/>runtime, base primitives,<br/>host-effect adapter semantics"]
  shared["Single-sourced .sld libraries<br/>loaded by both hosts<br/>not duplicated for parity"]
  ci["CI timing and required checks<br/>test shards, lint gates,<br/>REUSE/SPDX, branding"]

  corpus --> makeTest
  makeTest --> emacs
  makeTest --> portable
  makeTest --> external
  makeTest --> parity
  parity --> dual
  parity -. "excludes imports from" .-> shared
  emacs --> ci
  portable --> ci
  external --> ci
  parity --> ci

  classDef source fill:#fff8df,stroke:#a97912,color:#3d2b04
  classDef command fill:#eef7ff,stroke:#3d6f9f,color:#102a43
  classDef host fill:#ecfdf3,stroke:#438a5e,color:#143923
  classDef parity fill:#f3f0ff,stroke:#6b5fb5,color:#24164f
  classDef ci fill:#fff1f1,stroke:#bb4b4b,color:#4a0d0d
  class corpus,shared source
  class makeTest command
  class emacs,portable,external host
  class parity,dual parity
  class ci ci
```
