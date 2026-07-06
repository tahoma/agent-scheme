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
>
> Method: the conversation is intentionally **breadth-first** — threads are
> fanned out as they arise rather than deferred (the value is in the edges between
> threads, which deferral loses). This log is the raw fan-out in arrival order;
> the design note is the synthesis target. Coherence is combed out of the log into
> the note incrementally, per round, not reconstructed later from scratch.

## How it started

The opening question was mundane: *how do other compiled Scheme implementations
handle libraries and loading?* Grounding it in the repo surfaced the key framing
that shaped everything after — Consent Scheme has **two loading layers**:

1. a **host layer**, where the R7RS `.sld` runtime is linked into a native
   binary by a host toolchain (Racket `raco exe`, Gambit `gsc`, Cyclone), and
2. a **runtime library layer**, where `(consent library)` resolves `import` /
   `define-library` at runtime for user programs the interpreter evaluates.

Almost everything that followed is about the runtime library layer.

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
environment** — evaluated code can only reach the gated primitives installed for it —
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
runtime library system, built the same way on any host.

## The vision shift: libraries as live, transmissible entities

The operator rejected the sealed-binary framing on principle: Lisp systems grow
as hackers' toolkits, and the goal includes **libraries usable between agent
runtime instances, exchangeable within an orchestrated community of agents**.
This moved the center of gravity decisively. The question became not "permit
loadable libraries for speed" but "design the library as a first-class, live,
shareable entity."

**The unifying thesis.** In ordinary Scheme a library does one job (namespacing
and reuse). In Consent Scheme the *same boundary* can carry three: namespacing,
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
opposite trade. Consent Scheme's meta-circular interpreter already reifies
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
Consent Scheme is an agent runtime, not a system-extension language; the
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
issue. Filed **tahoma/consent#375** — a `surface:design` /
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
default, this mostly governs the F1/runtime-author path, not routine script grants.
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

## Tracked: issue #376, PR #377, roadmap 0.15.5

The operator called the conversation past the point of needing real tracking.
Filed the design/RFC umbrella **#376** (`surface:design` / `documentation` /
`size:umbrella` / `host:agent-runtime` / `risk:medium`), inserted at "now" in the
roadmap (#53) as chunk **0.15.5**, created branch
`tahoma/issue-376/library-exchange-design`, bumped `version.sld` 0.15.4 → 0.15.5,
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

## S-expressions as actor/message firmament

The operator: s-expressions have always seemed a fertile substrate for actor-style
systems, and structure is "half of what Scheme's lexical layer is about, numeric
representations the other half." Affirmed and grounded. The two halves are
accurate — the reader's *complexity* weight is the recursive s-expression
structure plus the (disproportionately fiddly) numeric sublanguage;
symbols/strings/chars are minor. Why s-expressions are fertile for actors:
messages are structural data *for free* (`read`/`write` is the wire codec);
structural (not nominal) data inherits Erlang's fragmentation escape — a message
built by old code is consumable by new code with no nominal type to mismatch
(directly the structural lean for open #1); symbols give Erlang's tagged-tuple
idiom natively (`(request ,from ,payload)`). The deepest point: one substrate
serves code, data, messages, *and* the content-addressing identity normal form —
quadruple duty is the fertility. The sticky wicket: s-expressions give the
*substrate* (structural, fragmentation-free messages), not the
*contract/capability discipline* — structural messages are fragmentation-free
*because* contract-free, so the contract layer (behavioral-vs-contract identity,
the capability membrane) is grown on top. The firmament is fertile; it is not the
crop. Grounded payoff: a *sound cross-agent* message substrate requires owning
*both halves* — portable symbol identity (#346) and portable numeric semantics
(#350), both already in chunk 0.16 — because "same message on every agent" demands
identical structural equality of symbols and numbers everywhere (the same property
content-addressing needs). The bootstrap-ownership roadmap is already laying this
ground, perhaps without having framed it as such.

## Where the capability system diverges from BEAM

The operator noted the capability system is where Consent Scheme first diverges from
otherwise-aligned BEAM semantics. Analysis: up to capabilities the designs are
strikingly convergent (shared-nothing, message passing, hot-swap, structural
data); the divergence is rooted in the *threat model*. BEAM = fault tolerance
among trusted-but-fallible code (ambient authority fine); Consent Scheme = open,
mutually-distrusting, possibly agent-authored code (malice/over-reach), which
forbids ambient authority and forces the capability membrane BEAM never needed.
The two isolations are orthogonal and complementary — fault isolation (integrity
under failure) vs authority isolation (confinement under adversarial operation) —
and BEAM's shared-nothing substrate (built for fault isolation) is exactly what
makes authority confinement clean, so the divergence extends the model rather than
fighting it ("mine the model" still holds). Deeper: BEAM reifies processes and
messages but not authority; Consent Scheme reifies authority as a first-class
scoped, revocable value. Honest tension: let-it-crash vs deny-and-handle — a
denial is a recoverable refusal, not a fault (naïve crash-and-supervise over
denials would loop), so Consent Scheme's failure model is crash-and-supervise *plus*
deny-and-handle. In seam terms: BEAM is the open shared-nothing periphery; the
capability membrane is the gated core the threat model forces — the divergence
*is* the open/sealed seam through the actor lens.

## Foreignness-marker down payment filed as a real issue (#378)

Correction/upgrade: the foreignness-marker "code down payment" had only been a
`spawn_task` *chip* (a local worktree-spinoff, not tracked, dismissable, no
roadmap trace) — which does not actually satisfy "make certain it is there now."
The operator's reading is the right one: it should be a real issue scheduled
sooner-than-later. Filed **#378** (Add universal foreignness marker to the
`<library>` record; `surface:portable-core+adapter` / `host:agent-runtime` /
`risk:low` / `size:weekend`), scheduled in the current chunk at **0.15.7**
(adjacent to its parent #376), and commented on #376 to supersede the spawned
chip. The decided invariant in the design note now points at #378.

## Hash-addressed context spines; BEAM as compiler backend; Guix to references

Several threads. **GitHub as design surface** — the operator confirmed that doing
part of the design in GitHub (issues referencing in-progress docs) works for them;
stop hedging, keep filing/referencing freely. **Hash-addressed context spines
(new, Open question #6):** push the by-name/by-hash duality down from libraries to
the environment substrate — the (capability/dynamic) context spine as an immutable
hash-addressed value layer + a mutable symbolic resolution layer; mutation =
functional update + rebind; same structure viewed by symbol-key (live) or
hash-key (immutable) via key abstraction. Scope to the capability-context spine
(auditable hash-pinned contexts; leases/revocation as context-hash sequences), not
the global env. Completes content-addressing across code/data/context.
**"Lisp-ish OTP":** precisely, OTP's model on a Scheme substrate plus the authority
axis OTP omits. **BEAM-the-VM as compiler backend (refinement):** repositioned from
rejected-primary-target to candidate eventual backend, peer to LLVM-native, with
CPS as the pivot (one CPS IR → interpret / BEAM / native; CPS reifies
continuations so it unblocks BEAM's missing `call/cc` and mirrors the existing
CPS/trampoline interpreter). Interpreter-core + JIT-edges and AOT backends are
points on one continuum over the same IR, not at odds. **Guix → references.md:**
added (with Nix and Unison) under a new Related Systems section, the parallels
having continued (Scheme-written functional package manager, hash-addressed
store). **BEAM's two FFIs** validate the out-of-process foreign-plane conclusion
(ports/C-nodes safe; NIFs the labeled-dangerous in-process escape).

## Docstrings-as-contract in agentic introspection; nonces as single-use leases

**Docstrings-as-contract, agentic angle:** the operator noted that in an agentic
environment the agent *introspects tool surfaces at decision time* for semantics,
so the docstring is in-band — behavior is conditioned on it, a doc change can
change behavior with identical code. That is the strongest justification that the
docstring is contractual ("literate programming lifted into the contractual
plane") and it independently justifies Open #5: the export surface = the
introspection surface = the contract surface, three coinciding on one boundary.
Riders recorded: the contract surface is a gradient (structured metadata ↔ prose,
agent uses both); and doc integrity becomes part of the trust surface (a deceptive
docstring misleads agent reasoning → admission/provenance vets the
doc-bearing contract identity). **Nonces as single-use leases:** a nonce is a
lease with count = 1 (the "once" corner), so it falls out of the lease abstraction
for free — and it is the safe authority-delegation primitive for shared-nothing
message passing (hand a nonce in a message → exactly one action, no standing grant,
no replay). The gem: nonces require *linear (move-not-copy)* semantics, which
reinforces and partly explains the non-marshalable handle invariant (copying a
single-use cap would forge authority). Capabilities thus come in two flavors
unified by the lease count: copyable standing/leased vs linear nonce. Edges:
consume-on-success, atomic consumption, message-pass transfers ownership; spending
a nonce is a recorded context-hash transition under Open #6.

## Foreign-import formalization issue; foreign-export = process boundary; two-runtime topology

Three threads. **Generalized foreign-import (#379):** the operator agreed we are
~90% to a generalized foreign-import spec (it is the built-in primitive spec), so
filed #379 to formalize the explicit declaration and make the primitives *comply*
as instances of it — behavior-neutral, closed-default preserved, arbitrary-native
resolution left as later foreign-plane work. Elegant shift (primitives become
instances of the spec they implied; F1 becomes a small later step). Placement TBD
(does not fit current chunk themes). **Foreign-export = OS process boundary:** the
irreducible foreign-export surface is the process boundary, so lean in — *all
foreign out-of-process; no in-process general foreign-export.* Consistent with the
deferral + foreign-membrane-as-OS-isolation + BEAM ports-over-NIFs, and largely
already on the roadmap (POSIX/process SRFIs + the native CLI/daemon contract) — so
framing, not a new issue. Emacs host adapter is the in-process exception
(runtime-author/TCB foreign-*import*, not general foreign-export). **Two-runtime
topology:** Emacs-hosted orchestrator/interface agents (interactive, local heap,
in the editor process) + natively-compiled portable R7RS worker agents (separate
processes), exchanging s-expressions. The exchange layer is the narrow waist that
makes parallel development of the two runtimes pay off (agree on the wire, not
internals). Orchestrator↔worker is *managed* exchange (Scheme↔Scheme across
processes), not foreign-export. Roadmap: chunk 0.15 (host-compiled executables)
gives the worker runtime; chunk 0.16 (own symbol identity #346 + numeric backend
#350) makes the bridge sound — same meaning *and hash* on both runtimes requires
owning both lexical halves. That is why 0.16 is where bridge-ability gets real.

## Projective lean for hash-addressed context spines (Open #6)

The operator leans **projective** over native for hash-addressed context spines,
on the decisive ground of *not changing the language mutation model*. Recorded as
the current lean on Open #6. Rationale captured: projective keeps
`set!`/cells/redefine-everywhere untouched (hash-addressing is an additional view,
not a replacement); the hash is a point-in-time snapshot computed on demand (no
per-mutation cost on the live path); and **frame-level hash memoization** (each
frame caches its content hash, invalidated on `set!`) recovers most of native's
efficiency without touching the eval core. Also clarified this round (non-design):
the "chip" mechanism is a coding-agent **harness/session feature** (`spawn_task` →
a clickable UI chip that spins a side-task into an isolated worktree session, or
is dismissed), *not* a GitHub feature — ephemeral and untracked, which is why it
did not satisfy "make certain it is there" (hence #378). "Lisp OTP + capabilities"
adopted as the framing because it foregrounds capabilities as the novel plane.

## #379 placement, PR hygiene, the chip pattern, and catching up

**#379 placement:** the operator's sequencing — formalize foreign-import *before*
the SRFI primitive wave so new primitives are born compliant. Placed at chunk
**0.16.7** (before the SRFI surface at 0.18+; core-mechanism ownership fits 0.16),
recorded in #53 and via a comment on #379. **PR hygiene:** adopt the convention
that each PR description states safe merge order and the issue(s) it closes;
applied to #377 as the first instance (added a Merge & dependent issues section
covering #375/#378/#379). **The chip pattern:** the harness chip (capture-at-
discovery, isolated worktree spinoff, ephemeral) maps onto Consent Scheme's own
design — orchestrator-spawns-worker-actor (isolated heap, nonce/leased authority,
s-expr exchange) organized as OTP-style supervision/worker trees ("trees of
temporary task-lists"), with the durable side already in `job`/`plan`/`task`. The
named idea: **promote-to-durable escalation** (ephemeral by default, persist on
demand) — the same dial as chip→issue and lease-once→lease-persistent. The chip is
a coding-agent harness feature, not a design artifact. **Process:** the operator
caught up on the backlog —
back in sync — so the no-trailing-questions constraint relaxes (interactive Q&A
resumes); per-round checkpointing continues (now load-bearing for the issues/PR).

## Thread survey post-sync; cross-process capability delegation (Open #7)

With the backlog caught up, surveyed remaining threads. Highest-leverage empirical
pull: run spike #375 (type identity, structural vs nominal) — it gates value
exchange and everything downstream. Standout *unexplored* design thread, newly
named as **Open question #7 — cross-process capability delegation (distributed
ocap)**: handles are non-marshalable and nonces linear, yet the orchestrator must
delegate scoped authority to a worker in another process, so authority cannot
cross as a handle; likely shape is a marshalable reference/ticket redeemed by
message to the holder (real handle stays home), à la the E language / CapTP
lineage. Designed-but-underspecified threads ripe for a spec pass: the
normalization dial (what is in each hash; underpins #1/#5) and the
capability-context/lease/nonce/linear model. Parked by design: foreign plane
(#379), thin-agent (#4), env-reflection meta-cap (#2), trust residuals (#3).
Process: merging #377 greens the dependent-issue references. (Also trimmed an
earlier misattribution from this log per operator.)

## Working model clarified; parked open questions filed (#380–#382)

Clarified the working model: **active design** stays in-context under #376 (and is
captured to its docs); **implementation** gets its own issue/branch (#375/#378/#379
pattern); **parked future-work** is filed as tracked issues so it is not lost.
Applied: filed the three parked open-question follow-ups — **#380** thin-agent
deployment tier (Open #4), **#381** environment-reflection meta-capability (Open
#2), **#382** provenance trust residuals (Open #3) — all unscheduled/parked,
referencing #376; the open-questions list now points at them. Decisions recorded:
the active *design* threads — cross-process capability delegation (Open question
#7, distributed ocap) and the spec-pass items (normalization dial; the
capability/lease/nonce/linear model) — stay *in-context* under #376, with
implementation issues to follow when concrete. The operator
also noted the roadmap-scheduling convention: **filed + unscheduled = active/now
candidate; filed + scheduled = deferred to its slot** — so #375 (type-identity
spike) is deliberately left unscheduled to keep it "do next." #377 merging is the
housekeeping that greens the dependent references.

## Everything placed in the roadmap

Per the operator's "everything goes somewhere in the roadmap": **#375** placed at
**0.15.7** — immediately after the design issue #376 (0.15.5), shifting **#378** to
**0.15.8** (renumber noted on #378). The three parked issues placed in their
natural homes: **#380** (thin-agent tier) → chunk **0.39 Orphans and Unloved
Issues** (the honest catch-all for a parked, doesn't-fit-a-theme decision);
**#381** (environment-reflection meta-capability) and **#382** (provenance trust
residuals) → chunk **0.40 Capability Hardening Follow-ups** (exact thematic fit).
So nothing is unscheduled now. Note this *does* defer the parked items (scheduled =
deferred, per the prior convention) to their late chunks, which is the intent;
#375 is scheduled at the *front* (0.15.7), so it stays the "do-next" pull despite
now being on the map. Convention clarified: the roadmap tracks *issues* (the
work), not *PRs* (the delivery mechanism) — so **PR #377 has no roadmap slot**; it
is the vehicle that delivers issue #376 (roadmap 0.15.5) and carries the matching
version bump. Roadmap slot 0.15.5 = issue #376 = delivered by PR #377. (GitHub
shares one number sequence across issues and PRs, so the PR opened right after the
issue took the adjacent number — easy to mistake for a sibling issue. Convention:
always write "issue #N" / "PR #N" explicitly to disambiguate.) This leaves a
**gap in the issue numbering at 377** (issues run …375, 376, _, 378…), and because
a PR is-an-issue in GitHub's model, `gh issue view 377` even *returns* the PR — so
the gap appears "filled" by the PR. This is a cosmetic GitHub-numbering artifact,
**not a roadmap gap**: the version-bumping change is fully on the roadmap as issue
#376 (0.15.5), which PR #377 delivers. #377 is the only PR in the #375–#382 range,
so it is the only such gap.

## Cross-process capability delegation worked through (Open #7 direction)

Pulled the marquee in-context design thread. Option A (workers just ask the
orchestrator) rejected: it reintroduces identity-based authorization, defeating
ocap (possession of the reference must *be* the authorization). Direction settled:
a **distributed object-capability protocol, CapTP/E lineage** — vats (per-runtime
isolated capability contexts), **tickets** (marshalable, unforgeable references;
real handle stays home), **redemption by message** (op runs in the holder's
context under its monitor/audit), holder-side **export tables**. Two dangling
tensions resolved: (1) non-marshalable handle vs. delegation → ticket-proxy crosses,
handle stays; (2) linear nonce vs. copyable message → token is copyable, linearity
enforced at the holder by atomic **consume-on-redemption** (no linear wire types
needed). New principle named: **authority is the dual of identity** —
content-addressing is for things you want shared (code/data/context); capability
tickets must be unforgeable, *not* content-derived; so capabilities sit outside the
content-addressing scheme by design (explains non-marshalable + non-content-addressed
handles). Supporting shape: two delegation paths (spawn-time local provisioning vs.
runtime tickets, favoring coarse-grained authority); promise pipelining for latency;
**leases double as distributed GC** (auto-reclaim export entries on expiry). Prior
art: E/CapTP (vats, eventual-send, promise pipelining, sturdy-ref=leased ticket vs.
live-ref=nonce) and macaroons (offline-attenuatable caveats for re-delegation). Open
sub-parts: bridge transport security (intra-team trusted; cross-team needs #382),
re-delegation/attenuation, full GC for persistent caps. Captured to the design note
("Cross-process capability delegation" section); Open #7 upgraded from gap to
settled direction.

## Distributed-ocap filed (#383); dependencies fix its position; sub-parts explained

**Dependencies / placement:** the distributed-ocap work is clamped — *after* the
sound two-runtime bridge (chunk 0.16: owned symbol #346 + numeric #350) and the
local capability/lease/nonce model (#376); *before* the cross-process
control-loop/protocol cluster in chunk 0.29 (#57, #286/#287, #289, #321), for which
it is the authority substrate; independent of #379/#381; cross-team extension only
depends on #382. Filed as **#383** and placed at **0.29.10**, immediately before
#57. **Sub-parts explained:** (1) *bridge transport security* — tickets are bearer
tokens, so the vat channel must be confidential + authenticated (intra-team
trusted via spawn-controlled channel; cross-team needs #382; leaked tickets bounded
by lease/nonce); (2) *re-delegation / attenuation* — sub-worker narrowing via
attenuating forwarders (revocation-propagating) or macaroon-style offline caveats;
(3) *distributed GC* — **dissolved by constraint**: require a lease on every
cross-vat ticket (no persistent un-leased cross-vat caps) + vat-death reclamation,
so caps are reclaimed by lease-expiry or worker-death, leak-free by construction
(avoids CapTP's hard distributed-GC problem; permanent cross-process authority is a
security smell anyway). The GC lever captured into the design note.

## Distributed-ocap sub-parts scoped; design conversation reaches completion

Closing decisions on #383's sub-parts: **cross-team transport security is out of
scope** for now (Byzantine threat) — intra-team only, on the spawn-controlled
trusted channel; **re-delegation = attenuating forwarders** (option b, soft —
revocation-propagating by construction; macaroons only if offline re-delegation is
later needed); **distributed GC confirmed dissolved by constraint** (lease every
cross-vat ticket + vat-death reclamation), so no GC follow-on issue is needed
unless persistent un-leased cross-vat caps are ever permitted (then it gets its own
issue). With these, the active design conversation has reached a natural
completion: every major thread is decided-and-captured, filed as an issue
(#375/#378/#379/#380/#381/#382/#383), or parked. The only remaining work is
operational — publishing these doc changes to PR #377 and the operator's review +
merge of it.

## Drive-by: resolved graph invariants migrated out of #53

At the operator's direction, slimmed the roadmap (#53) Graph Invariants section by
migrating invariants whose referenced issues are **all closed** into a new
`docs/resolved-graph-invariants.md`, mirroring the chunk-to-release-notes
migration. Correct split (after a fix — see below): **37 of 100 migrated, 63
retained**; the retained set is the open/future cluster (LLIR/GC/byte-code
backends, bootstrap ownership, task control loop, providers, VCS, capability
domains, SRFI, etc.) plus the standing structural rules. Done as an isolated
commit on the #376/#377 branch per the operator's call (their review;
roadmap-maintenance precedent #364 is closed).

**Bug caught (by the operator's verification question) and fixed.** The first pass
used a shell-loop classifier that over-migrated — it filed 39 invariants
referencing *open* issues (e.g. #115 LLIR, #346 portable-symbol-ownership, #286
task control loop) as "all closed." The fix: pull authoritative per-issue state in
a single `gh issue list --state all --json number,state` call, partition
closed/open from that one source, and reclassify with an `awk` pass (no shell-loop
subtleties). Verified: **0** migrated invariants reference any open issue. This is
exactly the silent graph-corruption the migration was warned to avoid; the
verification step is now mandatory for any such migration.

## Version corrected to 0.15.5 (avoid orphaning) + version-everywhere fix

Two operator catches, both mine to own. (1) **Orphaning:** main is at 0.15.4 and
0.15.5 (#367, unmerged) sits ahead of #376 in the chunk map, so bumping #377 to
0.15.6 would skip 0.15.5. Since #377 is what actually merges next, it should take
**0.15.5**; swapped the chunk map so #376 = 0.15.5 and #367 = 0.15.6 (#367 not yet
merged, so free to move). (2) **Version-everywhere + untested commit:** the runtime
version is asserted in several tests (`consent-runtime-test.el`,
`consent-eval-test.scm`, `consent-reflect-test.el`); I bumped only
`version.sld`, so every CI job went red on the version mismatch — and I had
committed without running the suite. Fixed: set `version.sld` + all 8 true version
assertions to 0.15.5 (the static `since` doc-metadata fixtures, which do not track
the runtime version, were correctly left at 0.15.4), then **ran the full local
suite green** (Emacs core/library/capabilities/tools + Gambit/Gauche/Guile/Racket/
Cyclone-compiled hosts, 0 unexpected) *before* committing. Lesson recorded:
`make test` must pass locally before any commit that touches `version.sld` or code.

## Scrub for follow-through gaps; version-footprint trim; CI-monitoring rule

Three operator wrap-up asks. **(1) Version footprint trim:** the runtime version is
hardcoded in ~9 places (version.sld + 8 test assertions). Recommendation: refactor
the version-asserting tests to *derive* the expected value from
`consent-version-datum` (assert machinery/consistency, not a literal), leaving
version.sld the sole per-PR update point. Filed as **#387** (DX, 0.15.9). **(2)
Scrub of the design log vs. GitHub:** open questions #1-#4/#7 are tracked
(#375/#381/#382/#380/#383), but #5 and #6 had no issues, and — the real gap — the
*core artifact had only the RFC (#376), no build issue*. Filed **#384** (Open #5,
0.17), **#385** (Open #6, 0.40), and **#386** the content-addressed store +
exchange *implementation* phase 1 (0.17; depends on #375/#50/bridge-0.16) — the
follow-through anchor. So every open question and the core build are now tracked.
**(3) CI-monitoring rule:** filed **#388** to encode in AGENTS.md that after any
commit to an open PR one must background-monitor CI to completion (never declare
success on a partial signal) and compare posted shard-timing data against recent
merged-PR timings to catch regressions. Adopted behaviorally as of this PR (the
version fix was pushed only after a full local green, then CI watched to 56/0).

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
