# Host-Compiled Staging and the Embedded VFS

This note names two architectural recognitions about what `make compile`
(`tools/compile-portable.sh`) and its install/distribution rules actually are,
so that later work — the native compiler backend and the capability system —
builds *on* named structure rather than beside it. It is a design note, not a
shipped feature description: it records the seams, not a finished API.

## 1. The staging is a compiler front-end with a borrowed backend

`make compile` is usually described as "package the portable runtime through a
mature host compiler." Structurally it is more than that. It:

1. resolves the runtime's library dependency graph,
2. transcodes each module through a host backend — Racket CS (`raco exe`), or
   Gambit (`gsc` → C → native),
3. embeds the libraries the interpreter loads *as data* (the prelude, the syntax
   prelude, and the source-libraries),
4. generates a `main` entry point, and
5. links a single standalone native executable, then stages it for install and
   distribution.

That is the shape of a **compiler driver front-end**: resolve a program and its
closure, hand it to a code-generation backend, link, and package. The backend is
currently *borrowed* — Racket CS and Gambit's C path stand in for the project's
own LLIR/native backend (the Milestone M5 compiler chunks; the roadmap's
`#115`–`#121`). Recognizing this reframes the host-compiled path (Chunk 0.15) as
the staging layer those chunks plug into, not a parallel mechanism.

**The seam, made principled.** A real front-end computes the module/dependency
closure from the program; it does not hand-maintain it. The compiler image in
`scheme/consent/compiler-manifest.sld` declares product roots, generated units,
target-provided library namespaces, and the roots installed as native runtime
libraries. `(consent compiler-plan)` joins those image facts with the canonical
collection manifests, validates project dependencies, rejects cycles, and
produces a deterministic dependency-topological unit plan. Both borrowed-host
backends consume that same plan: Racket precompiles its units and derives the
generated main's project imports from its roots; Gambit additionally uses its
unit order as the native link order. A future Consent-native backend consumes
the same front-end record while selecting a native image whose target-provided
namespaces and primitive realizations differ.

The runtime also declares its runtime-loaded source set as data: `base.sld`
owns `consent-base-prelude-load-paths` /
`consent-base-syntax-load-paths`, and `library.sld` derives source-library paths
from the manifest-backed seed inventory, then exposes it through one accessor,
`consent-runtime-source-files`. This is a related but different projection. The
embed/install manifest is **derived** from that accessor: `make compile`
enumerates it through the compile host's interpreter, writes a per-host
`runtime-source-manifest`, and both the embedded `(consent embedded-source)`
module and the `Makefile`'s install/dist rules read from it. The runtime is the
single source of truth; the hand-synced runtime-source, Gambit module-order,
generated-main project-import, and native-library-registration inventories are
gone. Backend code remains responsible for lowering and linking a resolved
plan, not for choosing the graph it compiles.

Native registration is deliberately narrower than native compilation. The
`consent-runtime` image compiles every root in its plan, but its
`native-libraries` field contains 19 libraries. Thirteen directly linked
Consent core/owner libraries keep one bootstrap ABI. Representation-owner
bindings use explicit preservation policies; default conversion rejects before
it would allocate an unclassified borrowed mirror or callback shim. The other
six entries are `(agent task)`, `(agent transcript)`, `(agent context)`,
`(agent memory-query)`, `(agent models openai-codec)`, and
`(agent redaction-kernel)`. They are stateless call-scoped transforms:
registration validates their complete exact inventory of 54 procedures and 10
constants before any binding is exposed.
The procedure/data counts are `(agent task)` 28/6, `(agent transcript)` 12/4,
`(agent context)` 6/0, `(agent memory-query)` 4/0,
`(agent models openai-codec)` 3/0, and `(agent redaction-kernel)` 1/0.

Three of those roots are selective native kernels behind source facades. The
`(agent memory)` facade retains the sole mutable store, persistent indexes, and
all mutation and replacement operations; `(agent memory-query)` owns only the
read-only find, tag, recent, and selection computations. The
`(agent models openai)` facade retains endpoint and transport effects, retry,
callbacks, redaction, provider-error orchestration, and result publication;
`(agent models openai-codec)` owns request JSON projection, response parsing,
and provider-error record projection. The `(agent redaction)` facade retains
recursive traversal, source and field policy, replacement, logs, local-only
behavior, provider safety, and pass ordering; `(agent redaction-kernel)` owns
only the case-sensitive scan for its fixed secret spellings. Each kernel is
pure, callback-free, and non-retaining, and declares an explicit zero-data
inventory.

The native result boundary charges every genuinely fresh result, condition, or
writeback compound once at the same value-node cost as its source constructor.
Borrowed mirrors that resolve to an existing owned identity are uncharged.
Without an active bridge, scalars and same-context owned compounds remain
available, but importing a fresh host or cross-heap compound requires a
hash-backed identity adapter and otherwise fails closed.

The directly linked `(consent datum)` owner now uses the same compact portable
Scheme representation on both borrowed backends. Pairs are one kind-specific
record with inline `car` and `cdr`; other public compounds have kind-specific
records; heap-level identity and owner data are derived; and cold metadata uses
heap ordinal sidecars. Native registration preserves those owner records and
applies positional conversion only to declared host adapters, callbacks,
indexes, and the frozen-image root list. It introduces no host operation to
reconstruct the retired generic wrapper.

A certified frozen heap supplies the staging boundary for immutable parsed
library forms and literal aggregates. Its reachable public objects may cross
contexts by identity without a borrowed mirror or target-heap reboxing, because
allocation and content mutation have been disabled and the root graph was
validated before publication. Uncertified or mutable cross-heap objects retain
the ordinary import/copy rule. This is a portable bootstrap contract: #120 may
lower heap references, ordinals, sidecars, and image membership into a native
object or image format, but must preserve the same identity, mutation, and
ingress decisions rather than freezing the R7RS record layout as its ABI.

General project roots whose exports can retain a compound value in a closure,
record, parameter, or module state are omitted. An interpreted import then
resolves the canonical embedded source realization, even though the borrowed
backend still compiles and links that root for direct callers. This avoids a
durable borrowed-host compound heap. Expanding the allowlist requires an exact
non-retention audit and a corresponding fail-closed binding inventory. Policy,
state, effects, callbacks, and orchestration stay in the source facade; native
registration is not permission to move them into its kernel. Making compiled
internal libraries consume Consent-owned compounds directly belongs to #120's
native lowering and owned primitive realization.

`(consent reader)` remains native because the compiled evaluator,
interpreter, and `(scheme read)` primitive must share its numeric, character,
symbol, recovery, and datum-owner records. Its generic interpreted bindings do
not thereby gain permission to borrow owned source or option graphs. The
direct `consent-reader-test.scm`, `consent-numeric-test.scm`,
`consent-numeric-generated-test.scm`, `consent-fixture-test.scm`,
`consent-symbol-test.scm`, and `consent-datum-test.scm` exercise those private
reader, evaluator, numeric, symbol, datum-owner, or dispatcher calls and are
explicit #120 self-host gaps; source-realizing an owner would instead create a
second record-owner universe.
Scheme-visible compiled reading stays covered through the context-owned
`(scheme read)` path: focused Racket-compiled runs of the agent reliability and
native CLI daemon adapter programs pass 20 and 238 assertions while reading
their structured fixture files. Compiled random/property suites exercise public
numeric behavior without crossing the private numeric dispatcher boundary.

## 2. The embedded source store is a capability-addressable VFS underlay

The embedded-source mechanism (`consent-register-embedded-source!` /
`consent-embedded-source-ref` in `(consent runtime)`, consulted by
`resolve-source-entry` in `base.sld`) is a `path → content` store that the
resolver falls through to: host-injected search dirs → source tree → embedded
store. That is precisely a layered, read-only **virtual filesystem underlay**,
with the baked content as the lowest mount. Nothing about the substrate is
library-specific; it is "files addressed by path, served from inside the binary."

**The capability layer already has the shape to mount it.** Every gated file
operation flows through one chokepoint in `interpreter.sld`:
`resolve-file-policy-path` → `authorize-file-capability(filename, op, …,
(context-file-paths context))` → *then* a host file operation. Two consequences:

- `context-file-paths` is already a per-context grant table — "this evaluation
  may touch *these* paths." Today a grant authorizes a host path; it could
  authorize a **VFS mount** instead.
- The host file op is just the current backend. Immediately after
  `authorize-file-capability` returns "authorized," the path is handed to the
  host — that is exactly where a VFS backend attaches: serve the authorized read
  from the embedded store (or a mounted content-addressed tree) instead of the
  host. No raw host port crosses the capability boundary, which *strengthens* the
  "no raw host objects" posture rather than bending it.

So the file-capability backend becomes pluggable — host FS, embedded VFS,
content-addressed store — selected by the grant.

**Native populated sandboxes.** With those unified, the staging of §1 gains a
"bundle a sandbox" output mode: bake (a) the script, (b) a populated VFS tree,
(c) a default file grant mounting that tree, and (d) *no* host-FS grant. The
resulting executable runs the script with its `(scheme file)` capabilities
resolving against the baked sandbox, provably fail-closed to the real disk — a
self-contained, hermetic, capability-gated agent or tool that carries its own
data.

**Layering invariant.** The *bootstrap* use of the store — resolving the prelude
and libraries to construct the base environment — must stay *below* the
capability gate: the interpreter has to boot before any grant exists, so that
access is trusted-direct. The *user* sandbox use goes *through*
`authorize-file-capability`. Same store, two access paths; the resolver must not
import the policy layer (the same discipline that keeps the reader's recovery
diagnostics from importing the diagnostics library).

## Where these converge

- **Compiler chunks (M5, `#115`–`#121`).** §1's front-end is what a native
  backend plugs into; the "bundle a sandbox" mode of §2 is an emit target.
- **Content-addressed library store (Chunk 1.1).** A content-addressed VFS is the
  natural shared backing for §2; the embedded store is the "everything inlined"
  special case of the same abstraction.
- **Capability environment** (`capability-environment.md`). File capabilities as
  VFS mounts is a concrete instance of gating effects behind explicit grants.
- **Portable bootstrap ownership (Chunk 0.28).** Owning the value/identity ABI is
  the substrate the native backend freezes; this staging is its front-end.

## Status

What exists today: the embedded store backs bootstrap library resolution; gated
file capabilities resolve against the host filesystem. The compiler image and
compiler plan provide the backend-neutral module graph described in §1, and the
embed/install manifest is independently derived from
`consent-runtime-source-files`. Racket and Gambit remain borrowed lowering and
linking backends; a native code-generation backend has not yet replaced them.
The larger §2 surfaces (VFS-backed file capabilities and staged native
sandboxes, tracked separately) remain design directions. They should build on
these seams rather than creating parallel staging paths.
