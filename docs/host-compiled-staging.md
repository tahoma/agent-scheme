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

**The seam, made principled (in part).** A real front-end computes the
module/dependency closure from the program; it does not hand-maintain it. The
runtime already declares its runtime-loaded source set as data: `base.sld`
owns `consent-base-prelude-load-paths` /
`consent-base-syntax-load-paths`, and `library.sld` derives source-library paths
from the manifest-backed seed inventory, then exposes it through one accessor,
`consent-runtime-source-files`. The
embed/install manifest is **derived** from that accessor: `make compile`
enumerates it through the compile host's interpreter, writes a per-host
`runtime-source-manifest`, and both the embedded `(consent embedded-source)`
module and the `Makefile`'s install/dist rules read from it. The runtime is the
single source of truth; the hand-synced `embedded_source_specs()` /
`CONSENT_RUNTIME_LIBRARY_FILES` copies are gone.

Two manifests of the same graph remain hand-maintained, and are the next steps to
fold into the same derivation: the Gambit `compile_gambit_module …` sequence and
the generated mains' prefix-import lists. (Tellingly, the Racket path already
*derives* its module set — `generate_racket_collections` globs every `.sld` —
while the Gambit path still hand-enumerates: the inconsistency a staging script
shows before it fully recognizes itself as a front-end.) The remaining clean
direction is to compute those from the same closure, with the code-generation
backend behind an interface rather than two parallel hardcoded code paths.

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
file capabilities resolve against the host filesystem. The reframes above are
design directions whose seeds and seams are already present and named here —
the embedded store, the `authorize-file-capability` chokepoint, the
`context-file-paths` grant table, the runtime's library-declaration tables. §1's
manifest single-sourcing is **done** — the embed/install manifest is derived from
`consent-runtime-source-files`. The remaining work — folding the Gambit module
list and the generated mains' imports into the same closure, a pluggable code-gen
backend, and the larger §2 surfaces (VFS-backed file capabilities, staged native
sandboxes; tracked as a separate issue) — should build on these seams rather than
reinvent them.
