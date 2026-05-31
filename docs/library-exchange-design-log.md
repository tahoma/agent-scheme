# Library Exchange — Design Log

> A narrative record of the design conversation that produced
> [Content-Addressed Library Store and Inter-Agent Exchange](content-addressed-library-store.md).
> That note captures *conclusions* (current state, resolved vs. open). This log
> captures the *journey*: the order ideas arrived, the dead-ends that were
> corrected, and why each fork resolved as it did — the reasoning a polished
> design doc deliberately throws away. Chronological. Exploratory; no ratified
> status.
>
> Session date: 2026-05-31.
>
> Maintained **per round** as the canonical running record: each exchange is
> folded into this log (a chronological beat) and into the design note (resolved
> direction / open questions) without waiting on confirmation. To catch up, read
> here and the design note rather than replaying the conversation. Decisions that
> still need the operator live in the design note's **Open questions**, not as
> chat prompts.

## How it started

The opening question was mundane: *how do other compiled Scheme implementations
handle libraries and loading?* Grounding it in the repo surfaced the key framing
that shaped everything after — Agent Scheme has **two loading layers**:

1. a **host layer**, where the R7RS `.sld` runtime is linked into a native
   binary by a host toolchain (Racket `raco exe`, Gambit `gsc`, Cyclone), and
2. a **guest layer**, where `(agent-scheme library)` resolves `import` /
   `define-library` at runtime for user programs the interpreter evaluates.

Almost everything that followed is about the guest layer.

## Two corrections that reframed the problem

**Correction 1 — the #274 misread.** Early on the reasoning treated the closure
of the Cyclone-host issue (#274) as an *architectural* signal ("don't do native
loadable libraries"). The operator corrected this: #274 was closed for
incidental, non-technical reasons, not a design verdict. Cyclone went back on the
table, and any conclusion leaning on that closure was retracted.

**Correction 2 — "compiled = ungateable" was wrong.** The deeper error: equating
*compiled / loadable* native code with *ungateable*. Reading the actual gating
(`check-port-capability-limit!` and the audit calls in `interpreter.sld`) showed
security does **not** live in interpretation. It lives in (a) the **primitive
environment** — guest code can only reach the gated primitives installed for it —
and (b) the **in-primitive monitor + audit**, ordinary Scheme that consults a
threaded `context`. Both survive compilation, *provided* compiled code can only
call the same gated primitives. So "compiled ⇒ ungateable" was a category error.
The real dangerous thing is *foreign* code, which is a different axis entirely
(see FFI, below). This correction is the hinge the rest of the design turns on.

## The host-shape comparison (and why it stopped mattering)

The three hosts differ in *build-time assembly*: Gambit/Racket enumerate modules
explicitly and whole-program link; Cyclone discovers the import closure from a
search path and compiles each `define-library` to its own loadable unit. All
three currently ship a *sealed binary*. So the mismatch that made the Cyclone
integration hard was build-time assembly style (and Cyclone bugs), not a runtime
loadable-library posture forced on the project. Conclusion: host sealing is a
**low-stakes, separable concern** about the TCB; the interesting facility is the
guest library system, built the same way on any host.

## The vision shift: libraries as live, transmissible entities

The operator rejected the sealed-binary framing on principle: Lisp systems grow
as hackers' toolkits, and the goal includes **libraries usable between agent
runtime instances, exchangeable within an orchestrated community of agents**.
This moved the center of gravity decisively. The question became not "permit
loadable libraries for speed" but "design the library as a first-class, live,
shareable entity."

**The unifying thesis.** In ordinary Scheme a library does one job (namespacing
and reuse). In Agent Scheme the *same boundary* can carry three: namespacing,
**capability scoping** (a library instantiates against the importer's grants),
and **inter-agent exchange**. Deliberately align all three on the library
boundary and they become one mechanism.

## Three moments, and the keystone

The model came into focus by separating three moments: **load** (artifact present,
inert, capability-neutral), **link** (references resolve against a particular
agent's gated primitives — authority adheres here), **invoke** (monitor checks +
audits). The keystone, later restated by the operator in linker terms:
**capability adoption happens at link time, not load time.** From that single
placement: exchange is safe (it's a load-time act, no authority moves),
per-agent isolation is free (each link is a separate adoption), liveness is
re-linking.

## FFI is an orthogonal axis (the foreignness/loadability split)

The operator named the axis the earlier confusion had hidden: **FFI is orthogonal
to library loading.** Modeled as a 2×2 — boundary (managed vs. foreign) ×
direction (import vs. export):

- The **gated primitives already are a Foreign-Import surface**, curated and
  tamed inside the TCB. FFI isn't missing; the only knob is whether that surface
  is *closed* (runtime-only) or *extensible* (FFI-import as root capability).
- **FFI forces adoption *before* link** (the function pointer *is* the authority),
  which is precisely why foreign-bearing libraries can't be exchanged — the clean
  dual of "pure-Scheme libraries defer adoption to link."

**Correction 3 — over-unified "three realizations."** An intermediate framing
("one interface, three realizations: to-Scheme, from-foreign, to-foreign") was
rejected by the operator on the export side: external ABI is an unbounded,
externally-controlled space. `foreign-export` must be a **separate plane** from
`export`, not a flag on it. The deeper reason: `export` targets one closed,
self-describing consumer; `foreign-export` couples meaning to a party outside the
content-addressed world. It is the *outbound edge of the knowable world*, dual to
FFI-import being the inbound edge of exchangeability. Putting it on its own plane
buys an explicit ABI/marshalling contract, a lossy/restricted type discipline, a
*structural* no-capability-handle-leak guarantee, and distinct (stability-bound)
liveness.

**FFI deferred.** The operator chose not to resolve FFI yet — and that
unreadiness *is* a reason to keep it on a separate plane, because the separation
is what makes deferral possible. Two seams must be **reserved now** so deferral
stays safe: (1) a foreignness marker the exchange/admission gate reads; (2)
capability handles kept opaque and non-marshalable. This matches the standards,
which leave FFI implementation-defined and outside the library model.

## Open vs. sealed: the deepest axis

The synthesizing move: the real duality is **open vs. sealed**, not interpreted
vs. compiled. SBCL and Smalltalk prove compiled code can be fully live; the
opposite of interactive is *sealed*, not *compiled*. A fixed program is a live
image with the doors welded shut. The architecture is then: a **sealed,
foreign-coupled, gated core (TCB)** and a **live, managed, pure-Scheme periphery**,
with the **capability membrane as the weld line**. R7RS libraries are a
fixed-world discipline grafted onto a live-soul language; the reconciliation is
*functional liveness* — fixed-world discipline holds *within* an instance,
liveness holds *between* instances (new content → new hash → new version).

This is where the line landed that the operator flagged as the keystone:

> *The architecture is the placement of that seam and the rules for what crosses
> it.*

## Identity: content-addressing

Identity is the keystone of the keystone. **Identity = hash of canonical source.**
Names become a per-agent resolution layer; renaming/upgrading are metadata ops.
Prior art surfaced: **Unison** (content-addressed definitions, codebase-as-DB,
abilities = typed cousin of link-time adoption), **Erlang/BEAM** (per-module hot
replacement, two-version coexistence, shared-nothing distribution), **SBCL /
Smalltalk** (compiled-and-live, the image as a runtime value). The operator
recognized content-addressing as "exactly the artifact to design."

## What travels: source, and "don't design an IR to save bytes"

The wire question separates two efficiencies that pull opposite ways: **wire
size** (solved by compressing canonical *source* — macro expansion *inflates*, so
an IR is counterproductive here) and **receiver instantiation cost** (solved by a
*local* content-addressed cache that never travels). The operator's note: many
well-intentioned projects build an IR to save bytes and conflate the two clocks.
Rule: *design IRs to save work, not bytes.* The one wire-format exception is a
**thin-agent tier** (participants without the full expander), for which expanded
core would travel as a *verifiable derivation* of source whose identity is still
the source hash.

## Provenance: deferred to the host as admission policy

The operator flagged provenance/trust as the hardest open problem and wondered if
it defers to the host. Refinement: split it. **Admission** ("link this received
library at all?") is a gated effect resolved by host policy. **Evidence
mechanism** (identity, an opaque provenance slot, a declared capability profile)
must live in the runtime. Synthesis: provenance is the **origin dimension of the
link-time capability-profile decision**, expressible in the existing
allow/confirm/deny vocabulary. You don't have to solve trust to design the store —
ship the hooks and a conservative default. Residuals that *don't* defer cleanly:
trust bootstrapping (key distribution), revocation of already-linked libraries,
and closure-level admission UX.

## Granularity: the library, with eyes open

The operator chose the **library** as the grain of liveness and exchange (the
BEAM choice), noting it fits both the capability model and the Scheme module
system. The honest downfalls were laid out: multiplicity/**type-identity
fragmentation** (two coexisting versions → values from one fail the other's
predicates — the sharpest cost), tension with content-addressing's own structural
sharing (re-versioning re-hashes everything below the library), factoring leakage
(R7RS's DAG constraint pushes co-recursive code into coarser libraries), and the
stateful hot-upgrade problem (BEAM's `code_change`). The one place coarseness is
*correct*: macro/runtime co-versioning. Resolution: **library is the policy grain
over a store that is internally definition-addressed** — atomic for policy, not
for storage.

## Heap-sharing: shared-nothing

The operator closed the last of the three original forks decisively: mutable state
through libraries is "a mess from day one." This *ratifies* what link-time
adoption already implied (no shared link → no shared state). Sharing doesn't
vanish, it **moves**: it becomes an explicit, gated effect (a message, a granted
store capability), never an ambient side effect of importing the same library.
Agents share immutable code (by hash) and explicit messages/capabilities, never
mutable memory — the actor / BEAM **shared-nothing** model, which is exactly what
makes per-library hot-swap safe.

## Open by necessity

The operator's framing that became the premise: **agentic-forward programming
necessarily needs to be open.** Sharpened: a *sealed programming language for
agents is close to a contradiction*, because sealing removes the runtime
generativity that distinguishes a language from a tool API. The author/runtime
distinction collapses — an agent authors *while* running. Crucial refinement:
"open" means open at the *periphery*, and that openness is exactly what makes the
sealed, gated core **non-optional**. Openness raises the stakes on the seam rather
than removing it; every piece of the design (content-addressing, link-time
adoption, provenance, the deferred foreign plane) is *the price of admission for
the openness*.

## The environment is the runtime value

The operator's observation: in a good Lisp/Scheme system the environment is a
runtime value. Sharpened honestly: *standard* Scheme reifies it only operatively
(closures, continuations) and deliberately keeps it non-reflective to protect
compilation; the image-Lisp tradition (Smalltalk, MIT/GNU Scheme) makes the
opposite trade. Agent Scheme's meta-circular interpreter already reifies
environments as data, so it is reflective by construction — it reclaimed the open
pole standard Scheme sold for sealing. Consequence: **reflection/mutation over an
environment is a meta-capability, the root that governs the integrity of every
other gate** (rebinding the environment can redefine what a gated name means).

## Adoption timing: link-time, on wetware grounds

The operator resolved adoption timing with a UX argument that converged with the
earlier ocap argument: capability granting is, early on, a human-in-the-loop
experience, and humans reason about authority at the level of **roles/scopes, not
operations**. Call-time consent would halt the exploratory loop. So **link-time
adoption**, with the manifest/capability-profile as the consent surface. Key
precision: three separable clocks — **adopt** at link, **enforce + audit** always
at invoke (full observability even with one prompt), **consent** mostly at link
with selective call-time escalation for a flagged sensitive subset. Generalizes
past the paired phase: when agents go autonomous, *policy* approves the profile at
link in the human's place.

## OS dynamic linking → the foreign plane's shape

The operator connected library-grain to host OS dynamic linking (`.so`/`.dll`),
noting it could matter for FFI later. Drawn out: the OS model *validates* the
grain and the symbolic-resolution-at-link discipline (GOT/PLT), but it *is* the
foreign plane — ambient authority, name-based identity. Two cautions for the FFI
plane: its membrane must be **OS-level isolation** (subprocess/sandbox), not the
in-process capability boundary (foreign code is confined *around* it, not
*through* it); and adopt the OS's grain but **reject its identity scheme** (SONAME
= DLL hell; content-addressing is the fix — see Nix/Guix). BEAM's NIFs are the
cautionary example: in-process foreign code that sacrifices isolation (a bad NIF
crashes the node).

## Bootstrapping and the expansion-aware compiler

The operator's intuitions: the expander should be in the bootstrap path (partly
"it's already built"), and the compiler wants to stay syntax-expansion-aware.
Drawn out: these are *one* decision — *don't sever expansion from compilation*.
The structural reasons: binding lives in expansion (hygiene = the expander is the
binder), the phase tower makes expander and compiler mutually recursive, and
source provenance (needed by the debugger/transcript and the
`syntax-source-metadata` work) is lost by a macro-blind backend. A
compilation-capable system is *not* a constrained one — for a macro-defined
language, compiling the system *requires* expanding it. So the thin-agent tier
dissolves on the build/bootstrap path (source stays universal there); what remains
of that question is only a possible constrained *deployment* tier — a separate,
defer-until-real axis.

## Hashing the normalized syntax tree

The operator noted that hashing the normalized syntax tree leverages homoiconicity
and makes reformatted variations idempotent. Sharpened: **the reader is the
normalizer** — hash the *datum*, not the text, and formatting/comments/reader
abbreviations/literal spellings collapse for free. But "normalized" is a **dial**:
the surface layer is free, but alpha-equivalence (renaming bound vars), rewrite-
equivalence (`when` vs `if`), and reference-resolution (Unison's hash-the-deps
trick) are *not* free — they need binding/scope/expansion info. Where the dial is
set is *upstream of the type-identity open question*. Project-specific catch:
docstrings/metadata are first-class data in the body (not comments), so they're in
the datum and would be hashed — a reworded docstring would mint a spurious new
version unless the canonical form deliberately strips doc metadata.

## Evidence: two trust regimes

The operator split the provenance/evidence problem by *identity boundary*. Most
dynamic sharing will be **intra-team** — orchestrated agents in one identity
system — where trust is membership-scoped and ambient (orchestrator-rooted,
frictionless, capability-bounded). Sharing from **outside** that boundary is the
classic third-party-library case, served by **conventional certified publisher
identity** ("Accept Always | Once | Reject from Fancy.io"). Drawn out: it is one
admission gate with two identity authorities (the opaque evidence slot is what
lets both flow through); signing proves provenance *not* safety (identity gates
admission, the capability profile independently gates authority); and the binary
is really the ends of a gradient with "Accept Always" as the promotion operator.
This tames the trust-bootstrapping residual — neither regime requires inventing a
global trust fabric (team roots in the orchestrator, external rides existing PKI).
Remaining: closure-spanning trust (a teammate relaying external deps does not
bless them transitively) and the usual revocation caveat.

## FFI decisions: closed surface, escape hatch, explicit planes

The operator made the FFI calls. **Foreign-import: hard-default closed**, with a
**runtime-author-tier escape (F1)** reserved — recognized as not exotic, since the
gated-primitive surface *is* the foreign-import surface and host adapters already
supply its native backings. Key clarification drawn out: multi-host *native
compilation* needs per-host *backings of a fixed surface* (host-adapter work,
compatible with a closed surface), not surface *growth* — so it does not itself
force F1; the escape is reserved for the rarer genuine-new-capability case, left
undefined until needed. **Foreign-export: deferred indefinitely, likely never** —
Agent Scheme is an agent runtime, not a system-extension language; the
separate-plane decision is what makes "decide not to decide" safe, and the
existing host-adapter/CLI entry point (session context fixed at the process
boundary) is a *constrained* foreign-export that stays — only the *general* form
is deferred. **Both directions explicit and independent** of managed
`import`/`export`: foreign-import explicit at the *binding* site (used normally by
guests thereafter), foreign-export its own construct; foreign-import the more
likely of the two to ever exist.

## Granularity, revisited

The operator pushed on the granularity analysis and it firmed up. Two
clarifications: (1) redefine-one-function-and-see-it-everywhere is *not* a
dynamic-vs-lexical-scoping effect (Common Lisp is lexically scoped yet has it) —
it is *late binding through a mutable named indirection* (the symbol-function
cell), and the content-addressed store's name→hash layer is exactly that cell
(by-name = live/redefine-everywhere; by-hash = stable/exchangeable). Scheme gave
this up *across library boundaries* on purpose (immutable imports) for stability;
the store restores it deliberately. (2) "Nobody makes it far with actors" is too
strong — actor systems succeed widely; the ones that nail *live upgrade* (Erlang)
dodge fragmentation by having *no nominal type identity* (structural copied data),
a direct signal for the type-identity question (lean structural for exchanged
values). Conclusion reached: some aspects must be library-grain, some
definition-grain — i.e. the "library policy grain over a definition-addressed
store" already in the note, now justified from three independent directions
(fragmentation, redefine-everywhere, type identity). Stateful hot-upgrade is
defused by the prior externalize-state decision. All collected into the note's
**Granularity** section.

## Foreignness marker locked; capability-handle rationale

The operator upgraded the foreignness marker from a *reserved seam* to a *decided
invariant*: every library descriptor must carry it as a required field (default
*managed*), present from the first representation so it is universal by
construction and never retrofitted — concretely, the field to add to the
`<library>` record (`make-library`, `runtime.sld`; ~8 construction sites in
`library.sld`) now as a minimal default-`#f` boolean, widened when FFI lands.
Capability handles confirmed opaque and non-marshalable, with the operator's
rationale: they are inherently properties of the host context and meaningless
migrated outside it — so they can never cross foreign-export, which makes the
no-leak rule structural rather than a hoped-for discipline. The four prior
concepts (foreign-export-as-separate-plane, FFI-deferred-to-its-own-plane,
provenance-deferred-to-host, library-grain-with-the-type-identity-caveat) were
confirmed already captured in the design note's **Resolved direction**.

## Type-identity spike filed (#375)

The operator flagged the earlier "first build experiment" suggestion as a concrete
issue. Filed **tahoma/agent-scheme#375** — a `surface:design` /
`host:agent-runtime` / `size:weekend` spike: define a library exporting a record
type, make two versions (one with the record unchanged, one changed), and check
whether a value built under v1 satisfies v2's predicate. Baseline measures the
nominal fragmentation; the candidate fix is content-scoped type identity (identity
= hash of the record's normalized definition). Deliverable is evidence plus a
recommendation for Open question #1, not production code. The issue notes it
depends on the (uncommitted) design docs being committed under their own
design/RFC issue.

## Nix/Guix prior art, made precise

The operator noted Nix/Guix lead the OS-side fight on library versioning.
Captured as prior art with two accuracy caveats (correcting an earlier loose
"content-addressed"): classic Nix is *input*-addressed (hash of the build recipe +
closure), not content/output-addressed like Unison and this design (Nix
CA-derivations are the exception) — the coexistence win is shared, the identity
basis differs; and Nix achieves coherence *between* environments (the OS analog of
shared-nothing), sitting below the semantic layer, so it validates the
immutable-store + mutable-name→hash-profile + rollback architecture but does not
answer the in-process type-identity question (#375). Guix is itself written in
Guile Scheme — directly readable prior art for a Scheme system.

## BEAM as a runtime target? model vs VM

The operator asked whether BEAM should be a/the runtime target. Analysis: the
*model* fit is excellent (BEAM is the reference implementation of the derived
architecture — shared-nothing, hot-swap/two-version, distribution, supervision,
structural data, safe out-of-process FFI via ports/C-nodes). The *VM-as-target*
fit is weaker and splits by strategy: the decisive mismatch is that BEAM is **not
a Scheme host**, so it has no slot in the portable-`.sld`-on-any-R7RS model —
adopting it means reimplementing in a BEAM language or a Scheme→BEAM compiler.
Compile-to-BEAM also hits no `call/cc` (already absorbed by the interpreter's
CPS/trampoline if the interpreter is *hosted* rather than compiled), immutability
fights the mutable reflective environment, and BEAM gives fault isolation, not
security isolation (capability membrane still yours). On the FFI parenthetical:
there is no platonic "right" FFI — it is a perf-vs-isolation tradeoff, and BEAM
offers both the safe out-of-process path (ports/C-nodes) and the dangerous
in-process one (NIFs), so its FFI is better than the strawman implies. Leaning
(not a decision): mine the model (already happening), keep BEAM as a candidate
distribution/supervision substrate for *hosting the interpreter*, but not the
primary target — most value is in the model, buildable on the existing Scheme
hosts.

## FFI grants at link-time granularity too

The operator's intuition: the wetware argument for link-time grants — aligning the
grant boundary with the granularity at which humans model authority — is also the
right granularity for *FFI* grants. Affirmed, with two refinements. (1) Same
three-clocks model: adopt the FFI capability at link, audit every foreign call at
invoke, consent at link via the capability profile/manifest. Per-call FFI consent
is both noisy and useless (a human cannot meaningfully judge one foreign call).
(2) FFI-bind is the *root/escape* capability — granting it grants the power to
leave the membrane — so even at link-time granularity it warrants *elevated
scrutiny*: never the frictionless ambient-team tier, and presented as
categorically different from bounded capabilities, not flattened among them (else
the human rubber-stamps the one grant that matters most). Given the closed-surface
default, this mostly governs the F1/runtime-author path, not routine guest grants.
Net: one link-time consent model spans all authority, with FFI at the
high-scrutiny top of the gradient.

## Consent leases, and documentation in the formal identity

Two refinements from the operator. **Consent leases:** the over-provisioning and
rubber-stamping costs of coarse link-time consent are mitigated by a *spectrum of
lease periods* — once, durations, session/task scopes, counts, persistent pins —
implemented directly on the revocable grant cell, with revocation generalized
from manual to *conditional* (expiry / scope / count). Over-provisioning shrinks
to a bounded window; rubber-stamping is countered because the lowest-friction
choice (once / this-task) is now also the lowest-blast-radius one — the lazy
button becomes the safe button. Two axes: *who* (trust regime) × *how long/broad*
(lease); FFI short-lease by default. **Documentation in identity:** because
docstrings and metadata are first-class data in the tree (not reader-discarded
comments), the store can hash at two levels — *behavioral* identity (code only;
dedup, cache, redefine-everywhere) and *contract* identity (code + declared
effects/capabilities + docstring; consent, admission, leases, agent reasoning). A
changed promise (doc or declared effect profile) mints a new contract identity
even with byte-identical behavior, so the system notices and can re-consent — a
changed declared capability profile becomes a re-admission event. This is
change-*tracking* of the informal contract, not verification. The earlier
docstring choice pays off: the informal contract becomes formally identifiable for
free, which comment-based docs cannot do. Cosmetic churn contained by normalizing
doc text and keying churn-sensitive uses on behavioral identity. (Reverses an
earlier framing that treated docstrings-in-the-datum as a churn hazard to strip.)

## Export as the contract-identity differentiator (open)

Building on the behavioral-vs-contract identity split, the operator proposed that
*export status* be the differentiator: an exported definition's docstring is part
of the implicit semantic contract (include it in identity), while an internal
definition's is developer commentary (behavioral identity only). Sharpened: the
differentiator gates the *docstring*, not the *behavior* — internal behavior
always contributes (transitively, via reference resolution); only internal
docstrings are excluded, so behavioral fidelity is preserved. This makes contract
identity naturally a *library-API* concept (exported behaviors + exported
docstrings + library metadata), answering the operator's "even more so at the
library-API level," while behavioral identity stays intrinsic and per-definition.
It also auto-filters doc churn to the right place (internal doc edits change
nothing; exported-doc edits change the contract). The re-consent matrix is clean:
cosmetic/behavior-preserving change → nothing (normalization eats it); behavior
change reachable from the API → re-consent; exported-doc change → re-consent;
internal-doc change → nothing. Open edges: re-export/rename makes contractual
status relative to the exporting library, not intrinsic; and whether export names
+ library-level metadata join the contract identity. Kept as Open question #5.

## Tracked: issue #376, PR #377, roadmap 0.15.6

The operator called the conversation past the point of needing real tracking.
Filed the design/RFC umbrella **#376** (`surface:design` / `documentation` /
`size:umbrella` / `host:agent-runtime` / `risk:medium`), inserted at "now" in the
roadmap (#53) as chunk **0.15.6**, created branch
`tahoma/issue-376/library-exchange-design`, bumped `version.sld` 0.15.4 → 0.15.6,
committed both design docs, and opened **PR #377** targeting `main`. The spike
**#375** now references #376 as its parent. #376 stays open as an umbrella
coordinating the spikes and eventual implementation; the docs remain
living/exploratory (committing preserves and tracks, it does not ratify).

## Generalizing the foreign axes from the existing limited basis

The operator observed that both foreign axes are already implemented to a limited
extent, and — because the problem space forced those forms — the limited basis
pre-determines the core of any generalization ("imitation by necessity"). Useful
refinement: separate the *necessary core* (generalizes) from the *incidental
specifics* (do not). **Foreign-import:** the gated primitive already *is* a
foreign-import declaration; the built-in primitive spec
(name/impl/arity/effects/capability-domain/limits), backend-resolved and
monitor-wrapped, is the generalized declaration's schema — so the schema is
already written. New parts: only the F1 gate on who-may-declare and
arbitrary-native-symbol resolution (ABI/OS linking); the hand-written wrapper is
the incidental specific. **Foreign-export:** the CLI/daemon `main` already obeys,
by necessity, context-at-boundary + marshal-not-handles + explicit-versioned-
contract (the necessary core); text marshaling, single entry point, and CLI vocab
are incidental specifics. Net: the existing basis *reduces* the foreign-export
generalization to its one open sub-question — multi-caller capability-context
policy. Analysis of the deferred plane, not a decision; captured as a forward note
in the design note's FFI section.

## Where it landed

The judgment-call forks are resolved (see the design note's "Resolved direction").
What remains is empirical or FFI-adjacent — chiefly **type identity across
versions** (the value-exchange keystone) and the **environment-reflection
meta-capability** — the kind of thing that only settles on contact with real code.
The recurring shape of the whole conversation: the same seam kept reappearing
under every lens (open/sealed, managed/foreign, `export`/`foreign-export`,
load/link, environment reflection), and the strongest validation was that
independent arguments — ocap-correctness and human-in-the-loop UX, or
expander-in-floor and the expansion-aware compiler — kept converging on the same
answer.
