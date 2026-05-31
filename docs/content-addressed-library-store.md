# Content-Addressed Library Store and Inter-Agent Exchange

> Status: exploratory design note. This captures a design discussion, not a
> ratified architecture. It is tracked under tahoma/agent-scheme#376 (design/RFC;
> roadmap chunk 0.15.6) and landed via PR #377. Treat it as the
> shared vocabulary and the set of open decisions for a future library-exchange
> facility, to be reconciled with [Architecture and threat
> model](architecture.md) and [Capability Environment and Effect
> Lowering](capability-environment.md) before any commitment. For the *reasoning
> journey* behind these conclusions — the order ideas arrived and the dead-ends
> that were corrected — see the
> [Library Exchange Design Log](library-exchange-design-log.md).

Agent Scheme is not a sealed application. Like the Lisp systems it descends
from, it is meant to grow as a live, extensible toolkit, and — uniquely — to let
an orchestrated community of agents share and exchange code. This note works out
what the *unit of that sharing* is, how identity and authority attach to it, and
what actually travels between agents. The short answer is a **content-addressed
library store**: libraries are named, hashed bundles of pure Scheme code and
macros that travel as source, are identified by the hash of their canonical
form, and adopt authority only when linked into a particular agent.

## Premise: open by necessity, and the seam that makes it survivable

Agent Scheme is open by necessity. The moment an agent's medium of action is
*code* rather than a fixed tool vocabulary, it has an open-ended, runtime-defined
action space — and a sealed environment can only ever express what was compiled
before it ran. A sealed programming language for agents is close to a
contradiction: sealing removes the runtime generativity that distinguishes a
language from an API. Openness is therefore not a feature of this design; it is
*entailed* by the choice to let agents program. (Standard Scheme leans the other
way — it de-reifies the environment to preserve lexical scope and compilation —
which is exactly the fixed-world graft this runtime has to reclaim the open side
of.)

That openness is *survivable* only because of one organizing decision, which the
rest of this document elaborates:

> **The architecture is the placement of a single seam — between a sealed,
> gated, foreign-coupled core (the TCB) and a live, managed, pure-Scheme
> periphery — and the rules for what may cross it and what crossing costs.**

Every axis below is that same seam under a different lens: open vs. sealed,
managed vs. foreign, `export` vs. `foreign-export`, load vs. link, and the
reflective environment as the root capability. They are not separate findings;
they are one line seen from several angles. Each major decision — content
addressing, capability adoption at link, provenance as admission, the deferred
foreign plane — is a *consequence* of where the seam sits, not an independent
choice. The more open the periphery, the more rigor the core requires: openness
raises the stakes on the seam rather than removing it.

## The library is where three roles coincide

In ordinary Scheme a library does one job: namespacing and reuse — the enabling
R6RS/R7RS development that made serious Scheme feasible. In Agent Scheme the same
boundary can carry two more jobs we actually need:

- **Namespacing and reuse** — R7RS `import`/`export`.
- **Capability scoping** — a library instantiates against the *importer's*
  grants; gated primitives resolve against the importing agent's capability
  context, not against where the code originated.
- **Inter-agent exchange** — a library is a self-contained bundle of code and
  macros with a name, which is exactly the unit to ship between agents.

The design commitment is to deliberately align all three on the library
boundary, so that namespacing, sandboxing, and exchange are one mechanism rather
than three.

## Three moments: load, link, invoke

The model depends on holding three moments apart:

- **Load** — the artifact is *present* (in the store, the address space, shipped
  from another agent). Capability-neutral. Inert code.
- **Link** — the library's references resolve against a *particular* agent's
  gated primitives. Authority adheres here: "call the file primitive" binds to
  *this* agent's file primitive, carrying *this* agent's grants. This is
  **adoption**.
- **Invoke** — a gated primitive runs; the monitor checks grants and emits audit.
  This is **enforcement**.

The keystone: **capability adoption happens at link time, not load time.** From
that single placement, the rest follows:

- **Exchange is safe** because exchange is a *load*-time act. Moving the inert
  artifact moves no authority, because adoption has not happened yet.
- **Per-agent isolation is free** because each agent links separately; each link
  is a distinct adoption with its own instance and its own authority. No shared
  mutable state across agents, because there is no shared link.
- **Liveness is re-linking.** A new version links afresh under a new identity and
  adopts the current context; existing importers keep their old link. (Compare
  Erlang/BEAM two-version coexistence.)

This is the object-capability reading of the existing reference-monitor model in
[Capability Environment](capability-environment.md). A stronger form closes a
library's primitive references over the agent's authority *at link* (no ambient
context to thread at each call), preserving grant liveness by linking to the
agent's mutable grant cell rather than a frozen snapshot. Whether to move to that
stronger form is an open decision (see below).

## FFI is an orthogonal axis, and it explains the boundary

"Native/compiled code is opaque and ungateable" is an **FFI** concern, not a
library-loading concern. Loadability and foreignness are independent axes. A
pure-Scheme library is fully gateable whether interpreted, locally compiled, or
loaded at runtime, because it only ever reaches the gated primitives. What is
dangerous is *foreign* code crossing out of the managed world.

Model the foreign boundary as two axes:

- **Boundary**: *managed* (Scheme ↔ Scheme) vs *foreign* (Scheme ↔ non-Scheme).
- **Direction**: *import* (functionality flows in) vs *export* (flows out).

|          | Import                                    | Export                                  |
| -------- | ----------------------------------------- | --------------------------------------- |
| Managed  | R7RS `import` — the library system        | R7RS `export` — declaring an interface  |
| Foreign  | FFI-in: foreign made callable as Scheme   | FFI-out: Scheme made callable outside   |

Key realization: **the gated primitives already are a Foreign-Import surface** —
a curated, audited, monitored one. FFI is not missing; it is shipped and tamed
inside the TCB. The only real knob is whether that surface is **closed** (only
the runtime adds foreign imports; default, and the natural partner to
link-time adoption) or **extensible** (guests may mint foreign imports, in which
case FFI-import is the privileged *root* of the capability lattice).

The dual that ties this back to exchange: **FFI forces adoption *before* link.**
Foreign code carries its access baked in at compile/load — the function pointer
*is* the authority. So a foreign-bearing library has already adopted authority by
the time you would link it, which is exactly why it cannot be exchanged. The
entire core/periphery seam is one line: **link-time adoption vs pre-link
adoption.** Pure-Scheme libraries defer; foreign code bakes in.

**Foreign-Export** (host adapters, the
[native CLI/daemon adapter](native-cli-daemon-adapter.md)) is the inverted,
underexplored quadrant and is plausibly the orchestration substrate: an external
driver invokes an agent's exported Scheme interface. Its security questions are
the mirror image — what capability context an externally-initiated call runs in,
how the caller is authenticated, and the rule that exported procedures must never
hand a live capability handle across the boundary.

**Resolved (this thread): the foreign plane is held separate and deferred.**
`foreign-export` is a *different plane* from `export`, not a flag on it. It
carries an explicit ABI/marshalling contract (a host-resolved descriptor, so the
unbounded ABI space lives in *data*, not in the language surface); it is lossy
and restricted to marshalable shapes (a value marshalled out and back is not
`eq?`); its contract structurally *cannot express* handing out a capability
handle, so the no-leak rule becomes a property of the form rather than a hoped-for
discipline; and it has different liveness semantics — a stability contract toward
external consumers who cannot follow content-addressed re-linking, making it the
comparatively-fixed *outward* face of an otherwise-molten agent. The reason it
must be separate generalizes: `export` targets one closed, self-describing
consumer (`import`), whereas `foreign-export` couples the interface's meaning to a
party outside the content-addressed world. It is the outbound edge of the
knowable world, dual to FFI-import being the inbound edge of exchangeability.

FFI as a whole is **deferred**. Because the foreign plane couples to an open,
externally controlled world, it is both categorically distinct *and* safely
postponable — and the separation is precisely what makes postponement possible.
The managed library system stands entirely on the existing, closed
gated-primitive surface and waits on nothing foreign. Two thin seams must be
*reserved now* so the deferral stays safe: (1) a **foreignness marker** on a
library that the exchange/admission gate consults, so "exchangeable ⟺
managed-only" is enforceable before FFI exists; and (2) **capability handles stay
opaque and non-marshalable**, asserted as a managed invariant today so no future
`foreign-export` can ever leak one. This mirrors how the standards themselves
leave FFI implementation-defined and outside the library model.

*Forward note (for when FFI is taken up).* The foreign plane will in practice
*be* host OS dynamic linking — loading `.so`/`.dylib`/`.dll` and resolving
machine-ABI symbols. That validates the library grain (the unit the whole systems
world converged on) and the symbolic-resolution-at-link discipline (the dynamic
linker's GOT/PLT is the same "references stay symbolic until link" principle as
WASM's import section and this design). But it imports two cautions: (1) the OS
linker grants *ambient* authority — loaded native code can call any syscall — so
the foreign membrane *cannot* be the in-process capability boundary; it must be an
OS-level isolation boundary (subprocess / sandbox / seccomp). Foreign code is
confined *around* it, not *through* it — a different enforcement substrate than
the managed plane, and another reason the foreign plane is genuinely separate.
(2) The OS identity model (SONAME, symbol versioning) is precisely "DLL hell";
content-addressing is the fix — adopt the OS's grain but reject its identity
scheme. See **Nix/Guix** (prior art, below), whose hash-addressed immutable store
ended OS-level DLL hell for exactly this reason (this design, one level down).
BEAM's **NIFs** are the cautionary
example: in-process foreign code that sacrifices the isolation making everything
else safe (a bad NIF crashes the node) — itself an argument for keeping the
foreign plane separate and likely out-of-process.

*Forward note (generalizing from the existing limited basis).* Both foreign axes
are already implemented to a *limited* extent, and because the problem space
forced those forms, they pre-determine the *core* of any generalization — provided
one separates the **necessary core** (forced by the problem; generalizes) from the
**incidental specifics** (forced by the particular boundary; must not). *Foreign-
import:* the gated primitive already *is* a foreign-import declaration — the
built-in primitive spec (name, host implementation, arity bounds, declared
effects, capability domain, limits), resolved through the backend and wrapped by
the monitor/audit, *is* the generalized declaration's schema. New parts are only
(a) the gate on *who* may declare one (the F1/runtime-author tier) and (b)
resolving *arbitrary* native symbols rather than hand-written backend wrappers
(the OS-linking / ABI-descriptor piece); the hand-written wrapper is the incidental
specific, the declaration-schema-plus-gating the necessary core. *Foreign-export:*
the host-adapter / CLI / daemon `main` already obeys, by necessity, the rules a
general foreign-export needs — it establishes a capability context at the boundary,
marshals arguments in and `value->external` out (never a live handle), and
presents an explicit, versioned contract. Those generalize. The incidental
specifics *not* to generalize: text/external marshaling (a shell artifact — a
structured embedding would marshal structured data), the single entry point, and
the CLI flag vocabulary. The payoff: the existing entry point *reduces* the
foreign-export generalization to its one genuinely open sub-question — the
multi-caller capability-context policy (fixed-at-export vs per-authenticated-caller
vs ambient) — everything else is imitation by necessity of what `main` already
does.

*Status (this thread).* The foreign-import generalization is ~90% present already,
so it is now tracked as **tahoma/agent-scheme#379** — formalize the explicit
declaration spec and make the built-in primitives *comply* as instances of it
(behavior-neutral, closed-default preserved; arbitrary-native resolution remains
later work). On the export side, the **irreducible foreign-export surface is the
OS process boundary** — so lean in: *all foreign interaction is out-of-process; no
in-process general foreign-export.* This is consistent with the deferral, the
"foreign membrane = OS isolation" conclusion, and BEAM's ports-over-NIFs, and it
is largely *already on the roadmap* — the POSIX / process-interface SRFIs
(SRFI 170 and kin) plus the native CLI/daemon contract **are** that
formalization, so it needs framing, not a new issue. The Emacs host adapter is the
in-process exception, but it is runtime-author/TCB foreign-*import* (gated Emacs
capabilities), not general foreign-export, so it does not break the rule.

## Open vs sealed: place the seam, don't pick a pole

The deepest axis is **open vs sealed** (not interpreted vs compiled — SBCL and
Smalltalk prove compiled code can be fully live; the opposite of interactive is
*sealed*, not *compiled*). A fixed program is a live image with the doors welded
shut. The three axes above align into a single seam:

- **Sealed, foreign, compiled core** — the interpreter, the gated primitives
  (tamed Foreign-Import), the host adapters (Foreign-Export). Audited, does not
  change at runtime. This is the TCB; how it is compiled into a host binary
  (whole-program link vs separately-compiled units) is a lower-stakes,
  host-specific concern, separate from this note.
- **Live, managed, pure-Scheme periphery** — content-addressed libraries,
  redefinable, exchangeable, instantiated against capabilities. Grows like a
  hacker's toolkit.

The capability membrane is the weld line between welded core and living
periphery. Architecture here is the *placement of that seam* and the rules for
what crosses it.

R7RS libraries are a fixed-world discipline grafted onto a language with a live
heritage (the pre-module `eval`/`load` top-level had the live soul but no
discipline). The reconciliation: **fixed-world discipline holds *within* an
instance (sealed, hygienic, R7RS-correct); liveness holds *between* instances
(new content → new hash → new version, old importers untouched).** Draw the
open/sealed seam *between* library instances, not *through* them.

## The environment is the runtime value, and reflecting over it is the root capability

Concretely, the living periphery is made of one thing: a first-class,
inspectable, extensible *environment value*. Standard Scheme reifies the
environment only *operatively* — in closures (captured lexical scope) and
continuations (captured control) — and deliberately keeps it *non-reflective*
(the `eval`/`environment` interface is opaque) to protect lexical scope and
compilation. The image-Lisp tradition (Smalltalk; MIT/GNU Scheme's first-class
environments) makes the opposite trade and pays for it in compilability. Agent
Scheme's meta-circular interpreter already reifies environments as data
(`agent-scheme-make-base-environment`, the library registry), so it sits in the
reflective camp by construction — it has reclaimed the open pole standard Scheme
sold for sealing. This is *why* compilation has to be a local-cache optimization
here rather than the foundation.

This makes the environment the concrete substrate of everything else: an agent
*is* (or holds) an environment value; linking a library is extending it;
capability adoption rides on it. And it makes one grant special. The power to
reflect over and mutate an environment is the power to redefine what *every name
in it means* — including rebinding a gated primitive to an ungated one. So
**reflection/mutation over an environment is a meta-capability, and its grant is
the root that governs the integrity of all the others.** If it is ungated, every
other gate dissolves.

*Open idea — hash-addressed context spines (Open question #6).* The same
by-name/by-hash duality used for libraries can be pushed one level down, into the
environment substrate: make the (capability/dynamic) **context spine** an
immutable, **hash-addressed** value layer with a **mutable symbolic resolution
layer** on top — "mutation" (`set!`, grant, revoke) becomes a *functional update*
(new immutable frame, new hash, rebind the symbolic pointer). The same structure
is then viewable from either dimension by parameterizing lookup over the key type:
*symbol*-keyed = the live/redefine-everywhere view; *hash*-keyed = the immutable,
structurally-shared, snapshot-able view. Scope it to the **capability-context
spine**, not the giant mutable global lexical env (which is a hashing-cost sink).
Payoffs: hash-pin *the exact context code ran under* into the audit/transcript
(immutable, verifiable); leases/revocation become functional updates → a sequence
of context hashes (dovetails with the revocable grant cell); cheap
snapshot/compare/share by hash. Implementation strengths: *projective* (freeze to
a hash on demand; keep mutable cells; less invasive) vs *native* (the spine is a
persistent hash-addressed structure; functional mutation; fuller payoff, changes
the eval core). *Current lean: **projective*** — preserve the language's mutation
model (`set!`/cells/redefine-everywhere untouched); the hash is a point-in-time
snapshot computed on demand (so the live path pays nothing per mutation), and
**frame-level hash memoization** (each frame caches its content hash, invalidated
on `set!`) recovers most of native's efficiency without changing the eval core.
The unification it completes: content-addressing as the universal substrate
property across **code** (libraries), **data** (s-expression messages), and
**runtime context** (the capability spine).

## Identity: content-addressing

Identity is the keystone. Once **identity = hash of the canonical source form**,
version conflicts, "is your `(util json)` my `(util json)`," cache coherence, and
safe exchange stop being problems to manage and become problems that cannot
arise. Names become a per-agent resolution layer (name → hash) over an immutable,
content-addressed store. Renaming and upgrading are metadata operations;
re-instantiation under a new hash is how the live periphery evolves without
disturbing existing instances.

The existing `(agent-scheme library)` registry — `library-registry-ref/set!`,
`resolve-library`, `eval-define-library` — is the seed of this store. Growing it
into a content-addressed store is an extension of what exists, not a rewrite.

**Two identities, at different normalization levels.** Because docstrings and
metadata are first-class *data* in the body — not comments, so they survive the
reader into the tree — the store can compute identity at more than one level: a
**behavioral identity** (code only) for dedup, caching, and
"same-implementation" / redefine-everywhere; and a **contract identity** (code +
declared effects/capability metadata + docstring) for consent, admission, leases,
and agent reasoning. A change to the *promise* — the documented contract or the
declared effect/capability profile — yields a new contract identity even when
behavior is byte-identical, so the system *notices* and can re-consent when the
contract shifts (a changed declared capability profile thus becomes a
re-admission event). This is change-*tracking* of the informal contract, not
verification of it — the prose still is not checked against behavior — but it
hoists the most important informal part of the contract into the formal identity
for free, an option comment-based docs cannot offer (the reader discards
comments; they never reach the tree). Cosmetic churn (typo/format edits) is
contained by normalizing doc text before hashing (reader-as-normalizer applied to
strings) and by keying churn-sensitive uses — cache, re-link of unchanged
behavior — on the *behavioral* identity.

*Open refinement — export status as the contract-identity differentiator (Open
question #5).* The export boundary is the public/private contract line, so it is a
principled differentiator for *whose docstring is contractual*: an **exported**
definition's docstring is part of the implicit semantic contract and joins the
contract identity; an **internal** definition's docstring is developer commentary
and joins nothing. The precise claim gates the *docstring*, not the *behavior* —
internal definitions always contribute their behavior (transitively, via
reference resolution) to the contract identity of whatever exported definition
reaches them; only their docstrings are excluded. This makes contract identity
naturally a **library-API** concept (public surface = exported behaviors +
exported docstrings + library-level metadata/declared capabilities), with
behavioral identity staying intrinsic and per-definition, and it auto-filters doc
churn to the right place (internal doc edits change nothing; exported-doc edits
change the contract). Open edges: re-export/rename makes contractual status
*relative to the exporting library*, not intrinsic to the definition; and whether
export *names* and library-level docs/metadata join the contract identity (likely
yes).

*Why this matters most in an agentic environment.* In a normal system a docstring
is out-of-band human advice; in an agentic system the agent **introspects the tool
surface at decision time** to learn how to use it, so the docstring is *in-band* —
an input to the agent's reasoning, with behavior *conditioned on it*. A doc change
can therefore change behavior with byte-identical code, which is the strongest
justification that it is contractual ("literate programming lifted into the
contractual plane" — the prose enters the execution loop). This also
*independently* justifies the export differentiator: the **export surface is the
introspection surface is the contract surface** — three coincide on one boundary.
Two riders: (a) the contract surface is a *gradient* from structured metadata
(effects/params/returns — reliably machine-consumable) to prose docstring (richer,
less formal), and the agent uses both; (b) **doc integrity is part of the trust
surface** — a deceptive docstring is an attack vector that misleads agent
reasoning, so the contract identity (which includes the doc) is part of what
admission/provenance vets.

## Granularity: library policy over definition identity

The grain question forces a split, because two different concerns want two
different units.

- **Library grain — policy, boundary, exchange.** Versioning and blast-radius,
  the exchange unit, the capability adoption/linking boundary, macro/phase
  coherence (a macro and the helpers its expansion references must co-version),
  and the hot-swap/liveness unit. All about *boundaries and policy*; the library
  is their natural home.
- **Definition grain — identity, sharing, equality.** Content-addressed identity
  for sharing/dedup (an unchanged definition keeps its hash across library
  versions), reference resolution (a definition's hash transitively pins the
  definitions it depends on), and — the keystone — **type identity** (a record
  type unchanged across two library versions must stay the *same type*, or values
  made under one fail the other's predicates). All about *identity and equality*;
  the definition is their natural home.

Pure library-grain fails the second set: re-versioning a library re-hashes
everything in it, so unchanged definitions lose identity, structural sharing
across versions is lost, and coexisting versions **fragment type identity** —
data made under one version is unconsumable under another. That fragmentation is
the ugly core that bogs down naïve actor/exchange systems.

**Redefine-one-function-and-see-it-everywhere** lives at the definition grain,
and its mechanism clarifies the whole split. The Lisp ergonomic does *not* come
from dynamic scoping — Common Lisp is lexically scoped yet has it. It comes from
**late binding through a mutable named indirection**: a call to `foo` indirects
through `foo`'s mutable cell, so redefining the cell is seen by every by-name
caller. Scheme deliberately gave this up *across library boundaries* (imported
bindings immutable, references resolve directly — R6RS forbids assigning imports)
in exchange for stability. The content-addressed store **restores it
deliberately: the name→hash resolution layer is the modern symbol-function-cell.**
Referencing a definition *by name* (through the mutable resolution layer) is late
binding — rebind name→new-hash and by-name callers see it; referencing *by hash*
is early binding — stable, reproducible, exchangeable. You want both, for
different purposes, which is exactly why the split is forced.

**Type identity (open — the keystone).** The concrete fork is *structural* vs
*nominal*. Erlang's success at live upgrade — where most actor systems bog down —
comes largely from having *no nominal type identity*: messages are copied
structural data (its records are compile-time sugar over tuples), so data from
old code is consumable by new code with nothing to mismatch. The signal: exchanged
*values* likely want structural or content-scoped type identity (a type unchanged
across versions unifies), even while behavior stays library-grain. This is the
question that decides whether agents exchange *values*, not just code.

**Stateful hot-upgrade** is defused by a decision already made: externalize state
into capability-held stores so libraries are stateless. Stateless code re-links
trivially — no BEAM-style `code_change` migration — which is why the
shared-nothing / externalized-state rule and library-grain liveness fit together.

## What travels: source, with compression; a local cache for speed

The wire question conflates two efficiencies that pull opposite ways:

- **Wire size.** An intermediate IR does *not* help here; macro expansion is the
  opposite of compression (a `define-record-type` call inflates into many
  procedures). The correct answer is **canonical source, entropy-coded**
  (zstd/brotli). Code is highly compressible text.
- **Receiver instantiation cost.** Avoid re-parse/re-expand with a **local,
  content-addressed cache** (expanded core, bytecode, or native) keyed by the
  source hash and **never transmitted**.

So there is no third *wire* format for efficiency alone. The one reason to define
an intermediary as a wire format is a **thin-agent tier**: participants that
carry a core evaluator but not the full hygienic expander. For them the
interchange is **expanded core Scheme** — still S-expression data, still
auditable, hygiene pre-resolved, reduced to the irreducible core. Three
constraints keep it compatible:

1. **Primitive and import references stay symbolic** — never inline the gated
   primitives, or authority is baked in before link and exchange breaks. (The
   non-negotiable one.)
2. Hygiene pre-resolved is acceptable, but it means trusting the sender's
   expansion.
3. **Identity stays the *source* hash.** Expanded core is a derived, *verifiable*
   artifact — a full agent can re-derive expansion and check it against the hash;
   a thin agent trusts it. You can always show the source behind any hash, which
   the redaction/provenance story wants.

WebAssembly's import section — symbolic imports supplied by the embedder at
instantiation — is link-time capability adoption done as ocap-by-construction,
and is the template if a true bytecode tier is ever needed. Expanded-core-as-data
is WASM's import discipline without surrendering the Scheme data model, and is the
better first stop.

## Prior art to study

- **[Unison](https://www.unison-lang.org/)** — content-addressed definitions
  (hash = identity, dependencies referenced by hash, names as metadata), the
  codebase-as-database with hash sync between codebases, and the *abilities*
  algebraic-effects system (a handler provides an ability at a boundary; code
  cannot perform an effect no handler granted — the typed cousin of link-time
  capability adoption). Read critically on two divergences: Unison
  content-addresses at the *definition* grain, not the library grain; and it is
  statically typed and effectively pure, so the *identity* idea ports cleanly
  while the *abilities-as-types* machinery is a design mirror, not a blueprint.
- **Erlang/BEAM** — live per-module hot replacement with two-version coexistence,
  in a distributed system of isolated communicating processes. The closest match
  to "a community of agents exchanging libraries where old instances survive the
  upgrade," and the reference for choosing the *module* as the grain of liveness.
- **SBCL / Common Lisp, Smalltalk, Emacs** — proof that compiled and live
  coexist; `save-lisp-and-die` and the image as a first-class, snapshottable
  runtime value.
- **Nix / Guix** — *functional package management*: a package is a pure function
  of its inputs, outputs land in an immutable hash-addressed store, and many
  versions coexist with no global mutable lib dir. Structural match is exact —
  immutable hashed store + a *mutable name→hash indirection* (Nix
  profiles/generations) + atomic rollback = immutable instances + the name→hash
  resolution layer + revocable functional liveness. Two caveats on what transfers:
  (1) classic Nix is *input*-addressed (hash of the build recipe + dependency
  closure), not content/output-addressed — Unison and this design are on the
  content side (Nix's CA-derivations are the exception); the *coexistence* win is
  shared, the identity *basis* differs. (2) Nix achieves coherence *between*
  environments (the OS analog of shared-nothing) and sits *below* the semantic
  layer — it hashes files, not definitions, with no notion of "the same type" — so
  it validates the store architecture but does **not** answer the in-process
  type-identity question (#375); that is Unison's definition-level layer, one step
  deeper. Guix is itself written in Guile Scheme — directly readable prior art for
  a Scheme system.

## Runtime substrate (related consideration): BEAM as model vs VM

BEAM/OTP keeps surfacing because it is essentially the *reference implementation
of the architecture derived here* — shared-nothing processes, per-module hot swap
with two-version coexistence, transparent distribution, supervision/fault
isolation, structural immutable data (the type-fragmentation escape), and a safe
out-of-process FFI (ports / C-nodes) matching the foreign-plane conclusion. The
**model** fit is excellent. The **VM-as-target** fit is weaker and splits by
strategy. Decisive structural mismatch: **BEAM is not a Scheme host** — the
current model (portable `.sld` on any R7RS implementation) has no slot for it, so
adopting BEAM means reimplementing the runtime in a BEAM language or building a
Scheme→BEAM compiler. Compiling to BEAM also hits **no first-class continuations**
(`call/cc`) — though the meta-circular interpreter's existing CPS/trampoline
absorbs that if the interpreter is *hosted* on BEAM rather than compiled to it;
BEAM's immutability fights the mutable reflective environment unless absorbed by
the interpreter; and BEAM gives *fault* isolation, not *security* isolation, so
the capability membrane is still yours to build. **Leaning (not a decision):**
mine the BEAM/OTP model (already happening), keep BEAM as a candidate
*distribution/supervision substrate* for hosting the interpreter or as a sidecar,
but not the primary runtime target — the payoff does not offset losing
Scheme-host portability and the reimplementation cost, and most value comes from
adopting the *model*, which is buildable on the existing Scheme hosts. (On FFI:
there is no platonic "right" FFI — it is a perf-vs-isolation tradeoff; BEAM offers
both the safe out-of-process path and the dangerous in-process one, which is
better than the strawman implies.)

The **capability system is where Agent Scheme first diverges from BEAM**, and the
divergence is rooted in the *threat model*. BEAM was built for fault tolerance
among trusted-but-fallible code (ambient authority is fine when every process is
yours); Agent Scheme assumes open, mutually-distrusting, possibly agent-authored
code (malice/over-reach, not just crashes), which forbids ambient authority and
forces the membrane BEAM never needed. The two isolations are orthogonal and
*complementary* — fault isolation (integrity under failure) vs authority isolation
(confinement under adversarial operation) — and BEAM's shared-nothing substrate,
built for the former, is exactly what makes the latter clean (no shared mutable
state to leak authority), so the divergence *extends* the model rather than
fighting it ("mine the model" still holds). The new axis: BEAM reifies processes
and messages but not authority; Agent Scheme reifies authority (capabilities,
grants, leases, the gated environment) as a first-class scoped, revocable value.
Honest tension: BEAM's *let-it-crash* and capability *deny* are different failure
shapes — a denial is a recoverable refusal, not a fault, so naïve
crash-and-supervise over denied operations would loop; Agent Scheme treats denials
as handled conditions (approval statuses, eval-error-on-violation), so its failure
model is crash-and-supervise *plus* deny-and-handle. In seam terms: BEAM is the
open shared-nothing periphery; the capability membrane is the gated core the
adversarial threat model forces — the divergence *is* the open/sealed seam through
the actor lens.

*Refinement — BEAM-the-VM as an eventual compiler backend.* Beyond "host the
interpreter," BEAM-the-VM is a plausible *eventual compiler target*, peer to
LLVM-native — with **CPS as the pivot**. One normalized CPS IR feeds three modes:
interpret (today), emit BEAM, emit LLVM-native. CPS *reifies continuations*, so it
removes the need for host `call/cc` — which both unblocks BEAM (no native
continuations) and is the classic lowering toward native — and it mirrors the
existing CPS/trampoline interpreter, so the conceptual distance is near-zero.
BEAM and LLVM-native are *complementary*, not redundant: BEAM targets the
distribution/concurrency/hot-swap/GC'd-portable deployment, LLVM-native targets
raw single-node performance. And "interpreter core + JIT at the edges" is not at
odds with AOT backends — they are points on one continuum over the same CPS IR
(interpret cold, JIT hot, AOT to a backend for a sealed artifact). So BEAM-the-VM
moves from "rejected primary target" to "candidate eventual backend"; mining
BEAM-the-model is unaffected.

## Deployment topology (related consideration): two runtimes, one wire

The s-expression exchange layer is the **narrow waist** of a two-runtime
deployment: **Emacs-hosted orchestrator/interface agents** (interactive, local
heap, inside the editor process — later other editors too) and
**natively-compiled portable R7RS worker agents** (separate processes). They
communicate by exchanging s-expressions. The narrow waist is what makes developing
the two runtimes *in parallel* cost-effective — they need only agree on the wire
(s-expression structure + owned symbol/numeric semantics), never on internals.
Distinguish from the foreign plane: orchestrator↔worker is **managed** exchange
(Scheme↔Scheme across processes — the core inter-agent design), not foreign-export
(which is to non-Scheme); both cross a process boundary, but one is managed and one
is foreign. Roadmap mapping: **chunk 0.15** (host-compiled executables, shipped)
provides the worker runtime; **chunk 0.16** (own symbol identity #346 + numeric
backend #350) makes the bridge *sound* — a message must mean *and hash* the same on
both runtimes, which requires owning both lexical halves. That is why 0.16 is where
bridge-ability becomes real.

Within this topology, "spawn an isolated sub-task" is not a new mechanism to
build: it is the orchestrator-spawns-worker-actor pattern — an ephemeral worker
actor (isolated heap/process, shared-nothing) for a sub-task, scoped authority via
nonce/leased capabilities, s-expression exchange, organized as an OTP-style
supervision/worker tree ("trees of temporary task-lists"). The durable side
already exists in the `job`/`plan`/`task` stores. The one design idea worth naming
is the **promote-to-durable escalation**: ephemeral by default, persisted on
demand (worker result → a job/plan/transcript record) — the same dial as the
harness's chip→issue and as lease-once→lease-persistent.

One unresolved gap this topology exposes: **how does authority cross the bridge?**
Capability handles are non-marshalable (and nonces linear), yet an orchestrator
wants to delegate scoped authority to a worker in another process — so a handle
cannot simply ride a message. This needs a distributed object-capability protocol
(marshalable reference/ticket redeemed by message; the real handle stays home).
Tracked as Open question #7.

## Cross-process capability delegation (distributed ocap)

*Direction for Open question #7.* How does the managed inter-agent bridge carry
**authority**, given handles are non-marshalable and nonces linear? Not by "the
worker asks the orchestrator to act" — that reintroduces **identity-based**
authorization (the holder must decide whether *this* worker may ask), which defeats
the ocap property (possession of the reference *is* the authorization). The answer
is a **distributed object-capability protocol**, CapTP/E lineage:

- **Vats.** Each runtime (orchestrator, each worker) is a vat — an isolated heap
  with its own capability context (our shared-nothing actor). Capabilities stay
  local; the real handle never leaves its vat.
- **Tickets.** To delegate, the holder mints a **marshalable, unforgeable
  reference** — `(capability-ref <vat> <ticket-id> <scope>)` — that carries *no*
  authority by itself; it is a claim redeemable only at the issuing vat. The
  holder keeps an **export table**: `ticket-id → (real handle, scope,
  lease/nonce-count)`.
- **Redemption by message.** The worker sends `(invoke <ticket-id> <op> args…)`;
  the holder validates (exists, unspent, within lease, scope permits) and performs
  the gated op **in its own context — real handle, monitor, audit** — returning the
  result. The effect runs at the holder; the membrane stays intact across the
  boundary.

Two tensions resolve here:

1. **Non-marshalable handle vs. delegation** — the handle stays home; the *ticket*
   (a reference) crosses as ordinary structural data. The proxy respects the
   invariant instead of breaking it.
2. **Linear nonce vs. copyable message** — the ticket (token) is freely copyable
   data; **linearity is enforced at the holder by atomic consume-on-redemption**
   (a second redemption fails because the entry was consumed). So no linear wire
   types are needed; locally a nonce is a linear handle, remotely it is a copyable
   token with server-side single-use.

And it names a principle: **authority is the dual of identity.** Content-addressing
is for things you *want* anyone with the content to have (code, data, contexts);
a capability ticket must be **unforgeable — deliberately not derivable from its
content** — because possession must equal authority. So capabilities sit *outside*
the content-addressing scheme by design; this is why handles are both
non-marshalable and non-content-addressed.

Supporting shape: **two delegation paths** — spawn-time local provisioning (real
handles for the worker's job description; fast, heavy use) vs. runtime ticket
delegation (ad-hoc, scoped, transient; favors coarse-grained authority since each
redemption is a round-trip, which aligns with leases/nonces). **Promise
pipelining** (E/CapTP) hides round-trip latency. **Distributed GC is dissolved by
constraint:** require a lease on *every* cross-vat ticket (no persistent un-leased
cross-vat caps) plus **vat-death reclamation** (a finished/dead worker's tickets
are reclaimed by the holder) — so capabilities are reclaimed by lease-expiry or
vat-death, leak-free by construction, avoiding CapTP's hard distributed-GC problem
entirely. (Permanent cross-process authority is a security smell anyway.) Prior
art: **E / CapTP** (vats, eventual-send, promise pipelining, sturdy-ref =
leased/persistent ticket vs. live-ref = transient nonce) and **macaroons**
(offline-attenuatable caveats for re-delegation). Remaining open sub-parts: bridge
transport security (intra-team trusted; cross-team needs #382) and re-delegation /
attenuation (attenuating forwarders vs. macaroon caveats; revocation propagation).

*Filed as tahoma/agent-scheme#383 (roadmap 0.29.10, immediately before the
cross-process control-loop cluster #57/#286/#289/#321 it is the authority substrate
for; depends on the sound bridge, chunk 0.16).*

## Resolved direction (this thread)

- **Open by necessity.** The periphery is open because agents program; the core
  is sealed and gated *because* the periphery is open. (See premise.)
- **The library is the policy grain** — the unit of naming, versioning,
  blast-radius, exchange, and macro/phase coherence — *over a store that is
  internally definition-addressed* for sharing and dedup. "Library is the atom"
  holds for policy, not for storage.
- **Identity = content hash of canonical source.** Names are a per-agent
  resolution layer. Liveness is functional: new content → new hash → new version;
  old importers keep their instance.
- **Source is the wire format**, entropy-coded; compiled forms are a local cache
  keyed by hash that never travels. Expanded-core interchange only if a
  thin-agent tier exists, and then as a *verifiable derivation* of source whose
  identity is still the source hash.
- **Capability adoption at link, not load.** Loading shares inert code; linking
  binds it to an agent's authority; invoking enforces and audits. Adopt at the
  **link-time** form (close primitive references over the agent's *mutable grant
  cell*, so grants stay revocable), motivated two ways that converge:
  ocap-correctness (no ambient authority) and human-in-the-loop UX. The wetware
  argument is decisive early: humans reason about authority at the level of
  roles/scopes ("may touch the test dir, may call staging"), not per operation, so
  consent belongs at link, not per call — call-time prompts would halt the
  exploratory loop. Keep three clocks separate: **adoption** at link;
  **enforcement + audit** always at invoke (so you observe every effect even
  though you prompted once); **consent** defaulting to link-time manifest approval
  of the declared capability profile, with selective escalation to a call-time
  prompt for a flagged sensitive subset (spend, delete, exfiltrate). The capability
  profile is the manifest — same artifact for admission, link-binding, and the
  consent prompt. Mitigate coarse-grant over-provisioning with tight profiles +
  invoke-time audit; mitigate rubber-stamping by prompting only on the capability
  *delta* on re-link/upgrade and showing provenance alongside. The choice
  generalizes past the paired phase: when agents go autonomous, *policy* approves
  the profile at link in the human's place — same mechanism. **Consent carries a
  lease.** Rather than binary once-vs-forever, a grant is issued for a lease —
  once, a duration, a session/task scope, a count, or a persistent pin —
  implemented as the revocable grant cell with revocation generalized from manual
  to *conditional* (expiry / scope / count). This mitigates both coarse-grant
  failure modes: over-provisioning shrinks to a bounded window (least-privilege
  *in time*), and rubber-stamping is countered by making the *lowest-friction*
  choice (once / this-task) also the *lowest-blast-radius* one — the lazy button
  becomes the safe button. Two orthogonal axes result: *who* (trust regime) × *how
  long/broad* (lease); FFI grants take a short lease by default, never persistent.
  Enforcement rides existing session/task lifecycle and the clock; lease expiry
  mid-operation blocks new acquisition rather than aborting in-flight (grace
  policy TBD). **Leases subsume nonces** (count = 1, single-use) — the safe
  primitive for delegating exactly one action through a message with no standing
  grant and no replay (using it spends it). Nonces require **linear
  (move-not-copy) capability semantics**, which reinforces *and partly explains*
  the opaque/non-marshalable handle invariant: copying a single-use capability
  would duplicate its one use, i.e. forge authority. So capabilities come in two
  flavors unified by the lease count — **copyable standing/leased** (count > 1 /
  persistent) and **linear nonce** (count = 1, move-only); passing a nonce in a
  message *transfers* it. Edges: consume on *success* not attempt; consumption
  atomic under concurrency. With hash-addressed context spines (Open #6), spending
  a nonce is a functional context update → a recorded context-hash transition, so
  single-use authority is auditable.
- **Shared-nothing between agents.** No shared or observable mutable state flows
  through library instances — each agent links its own instance, so cross-agent
  state-sharing is structurally unreachable. Sharing is an *explicit, gated
  effect* (a message, or a granted capability to a shared store), never an ambient
  side effect of importing the same library. Agents thus share immutable code (by
  hash) and explicit messages/capabilities, never mutable memory — the actor /
  BEAM shared-nothing model, which is exactly what makes per-library hot-swap
  safe. Recommended discipline (already the runtime's internal practice via
  explicit `*-store` objects): externalize state into capability-held stores
  rather than library top-level bindings. (Open nuance: instance-local *benign*
  state such as a memoization cache is harmless; only shared or
  semantically-observable mutable state is forbidden.)
- **Provenance is a host-resolved admission policy.** Admitting a received
  library is itself a gated effect, keyed on origin/evidence and the library's
  declared capability profile, expressible in the existing allow/confirm/deny
  vocabulary. The runtime owns the *mechanism* (hash-closure identity, an opaque
  evidence slot, a declared capability profile, the link gate); the host owns the
  *verdict*. **Two trust regimes share this one gate, differing only in which
  identity authority vouches:** intra-team sharing among orchestrated agents is
  *membership-scoped and ambient* (the orchestrator is the root of trust;
  admission is the frictionless fast path, the capability membrane the real
  safety net); external-party libraries use *conventional certified publisher
  identity* (code signing / PKI) with a link-time prompt — "Accept Always | Once |
  Reject from publisher X." The opaque evidence slot is what lets both flow
  through one gate. Signing proves *provenance, not safety*: certified identity
  gates *admission*, the capability profile independently gates *authority*. The
  two regimes are the ends of a trust gradient (team → pinned partner → certified
  unknown → anonymous); "Accept Always" is the operator that promotes an external
  party toward the low-friction pinned tier, and is revocable like any grant.
- **The foreign plane is separate, explicit, and mostly deferred.** Both
  directions are explicit declarations independent of managed `import`/`export`:
  foreign-import explicit at the *binding* site (where native authority enters,
  maximally audited; the resulting gated primitive is used normally by guests, who
  never write `foreign-import`), foreign-export its own construct. **Foreign-import
  surface: hard-default closed** — guests cannot mint foreign imports — with a
  **runtime-author-tier escape (F1)** reserved for genuine new foreign
  capabilities (mechanism undefined until needed). The common multi-host need
  (per-host *native backings of a fixed surface*) is served by the closed surface
  itself — host adapters are the runtime-author foreign-import providers — so it
  does *not* require F1; only true surface *growth* does. When an FFI grant *is*
  made (the F1/runtime-author path, or any future extensible case) it follows the
  same **link-time consent** model as ordinary capabilities — the granularity at
  which humans model authority — but at *elevated scrutiny*: FFI-bind is the
  root/escape capability (granting it grants the power to leave the membrane), so
  it never rides the frictionless ambient-team tier and must be *presented* as
  categorically different from bounded capabilities, not flattened among them. One
  link-time consent model thus spans all authority, with FFI at the high-scrutiny
  top of the gradient. **Foreign-export:
  deferred indefinitely, likely never** — Agent Scheme is an agent runtime, not a
  system-extension language; the separate-plane decision is what makes "decide not
  to decide" safe. The existing host-adapter/CLI entry point is a *constrained*
  foreign-export that stays (its context is the session, fixed at the process
  boundary); only the *general* form (arbitrary procedures, per-call context) is
  deferred. Two managed-side invariants are **decided now** (so they are
  universal by construction, never retrofitted): (a) **every library descriptor
  carries a foreignness marker** — a required field, default *managed*
  (non-foreign) — that the exchange/admission gate reads to enforce *exchangeable
  ⟺ managed-only*. It is present from the *first* library representation, not
  added later; concretely, the field to add to the `<library>` record
  (`make-library`, `runtime.sld`) now as a minimal default-`#f` boolean
  (`foreign?`), widened to richer foreign-plane metadata when FFI lands. **Filed
  as tahoma/agent-scheme#378, scheduled sooner-than-later at roadmap 0.15.7.** (b)
  **Capability handles stay opaque and non-marshalable** — they are inherently
  properties of the host context and have no meaning migrated outside that world,
  so they can never cross `foreign-export`; the no-leak rule is therefore
  *structural*, not a discipline.

## Open questions

1. **Type identity across versions.** Does an exported record/type's identity
   track the library version (fragments — safe, but data made under one version
   fails the other's predicates) or its own content (unifies across versions that
   did not change it)? For a community that exchanges *values*, not just code,
   this is the sharpest unresolved decision; it likely forces type identity to a
   finer grain than the library even while behavior stays library-grain. The
   concrete fork is *structural* vs *nominal* identity — Erlang dodges
   fragmentation entirely via structural, copied data (see Granularity, above).
   **Spike filed: tahoma/agent-scheme#375** (scheduled 0.15.7, immediately after
   the design) — the minimal record-crossing-a-version-boundary experiment to
   prove or break this. Relatedly, inter-agent
   *messages* are s-expression structural data — already structural and
   fragmentation-free, the Erlang escape by construction — so the *message* layer
   leans structural independently of the record question; making that sound
   cross-agent depends on owning portable symbol identity (#346) and numeric
   semantics (#350), the two halves of Scheme's lexical layer (both in chunk 0.16).
2. **Environment reflection as root meta-capability.** How is the
   inspect/extend/rewrite-the-environment grant modeled and constrained? It
   governs the integrity of every other gate. *Tracked (parked): #381.*
3. **Trust residuals (now narrowed).** The root-of-trust split is settled in
   *shape* — intra-team trust roots in the orchestrator, external trust rides
   conventional PKI/code-signing — so neither regime invents a global trust
   fabric. What remains is implementation selection (the team-identity mechanism;
   which external signing ecosystem) plus one genuine cross-cutting case: **trust
   over the closure, not just the sender** (a teammate relaying external
   dependencies does not transitively bless them — provenance is evaluated per
   origin across the hash closure, which can straddle both regimes); revocation of
   pinned-publisher trust and of already-linked grants (future authority only,
   cannot un-run past effects); and closure-level admission UX (per-hash
   confirmation does not scale — needs origin-level or trust-on-first-use
   aggregation). *Tracked (parked): #382.*
4. **Thin-agent tier.** Does the community have participants too constrained to
   run the full macro expander? Only then is expanded-core worth defining as an
   interchange format. (The bootstrap/build path is settled — expander in the
   floor, source universal there; what remains is a possible constrained
   *deployment* tier, defer-until-real.) *Tracked (parked): #380.*
5. **Export status as the contract-identity differentiator.** Should being
   *exported* be what lifts a definition's docstring into (library-API-level)
   contract identity, while internal definitions are behavioral-only? The
   mechanism is clean — gate the *docstring*, not the behavior; internal behavior
   still counts transitively — but the edges need settling: re-export/rename makes
   contractual status relative to the exporting library, and it is unsettled
   whether export *names* and library-level metadata join the contract identity
   (likely yes). See Identity → "Two identities."
6. **Hash-addressed context spines.** Should the (capability/dynamic) context
   spine be an immutable hash-addressed value layer with a mutable symbolic
   resolution layer on top (functional update + rebind on mutation), viewable from
   either dimension by parameterizing lookup over the key type? High-value scope is
   the capability-context spine (auditable hash-pinned contexts, leases/revocation
   as context-hash sequences), not the global lexical env. **Current lean:
   projective** (compute the hash on demand; keep the language mutation model
   unchanged; frame-level hash memoization for efficiency) rather than native
   (persistent functional spine). Completes content-addressing across code, data,
   and runtime context. See Environment → "hash-addressed context spines."
7. **Cross-process capability delegation (distributed ocap).** *Direction
   settled (this thread); spec sub-parts open.* Handles are non-marshalable and
   nonces linear, yet the orchestrator must delegate scoped authority to a worker
   in another process — so authority cannot cross *as a handle*. Direction:
   distributed object-capability protocol, CapTP/E lineage (see "Cross-process
   capability delegation" section). **Filed: tahoma/agent-scheme#383 (roadmap
   0.29.10).** Remaining open sub-parts: bridge transport security
   (confidential/authenticated channel; cross-team needs #382) and re-delegation /
   attenuation (sub-worker narrowing — macaroon-style caveats or attenuating
   forwarders). Distributed GC is dissolved by constraint (lease every cross-vat
   ticket + vat-death reclamation).
