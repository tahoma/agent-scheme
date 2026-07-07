# Library Surface and Manifests

Consent Scheme's importable library surface is owned by Scheme-readable
manifests, not by hand-curated resolver lists. The manifests are the durable
inventory for issue #483: they say which libraries exist in the seed runtime,
which names are ordinary public imports, which names are internal substrate, and
which imports are host-conditional capability surfaces.

## Manifest Topology

The default seed root is `scheme/`. The top-level seed index is
`scheme/manifest/index.sld`, which defines `(manifest index)` and links the
collection-local manifests. The index also references itself through a
`manifest` collection entry, so the aggregate manifest library is part of
the same manifest graph rather than a special library outside the catalog:

- `scheme/consent/manifest.sld` for R7RS-small, core Consent Scheme, and runtime
  implementation libraries.
- `scheme/stdlib/manifest.sld` for optional stdlib, SRFI, and R7RS-large-facing
  aliases or owned portable libraries.
- `scheme/agent/manifest.sld` for public agent APIs and internal agent primitive
  backing libraries.
- `scheme/cli/manifest.sld` for CLI adapter-facing libraries.
- `scheme/emacs/manifest.sld` for Emacs host-adapter capability libraries.
- `scheme/manifest/index.sld` for the aggregate manifest collection itself.

Collection manifests use collection-local `source-file` values. For example,
`scheme/agent/manifest.sld` records `memory.sld`, not
`scheme/agent/memory.sld` and not `../agent/memory.sld`. The top-level manifest
index provides the collection's `source-root`, so a resolver configured with a
different seed root can still aggregate the same collection without child
manifests peeking up into sibling directories.

The Emacs Lisp bootstrap and portable Scheme bootstrap both consume this seed
index. The default seed root happens to be `scheme/`, but the resolver logic is
about a configured seed root, not a hard-coded repository path.

Manifests do not become the only authority for imports. A library already
registered in an evaluator context, including a library defined ad hoc in a REPL
session with `define-library`, remains importable even when no manifest entry
exists for it. Manifest records provide durable seed inventory and catalog
metadata; the live registry remains the authority for libraries that have
already been defined in the current context.

The top-level index also assigns each collection a default catalog `category`.
Collection-local entries inherit that value unless they declare their own
`category`. This is how `(scheme ...)` R7RS-small libraries remain categorized
as `standard` even though their manifest is owned by the `consent` collection,
and how R7RS-large or SRFI-facing entries remain categorized as `stdlib`
without resolver code testing library-name prefixes.

## Visibility Tiers

Manifest entries use the following visibility vocabulary:

- `public`: Importable by ordinary user or agent code. This is a compatibility
  promise and should appear in user-facing discovery.
- `public-consent`: Curated `(consent ...)` libraries that are part of the
  user-facing Consent Scheme API even though they share the `consent` root with
  runtime internals.
- `internal-runtime`: Reader, evaluator, macro, runtime, bootstrap, resolver,
  primitive backing, and pass libraries that are implementation substrate.
- `internal-agent-model`: Agent primitive or model backing libraries used to
  implement public `(agent ...)` APIs.
- `host-adapter`: Host-specific capability-adapter libraries whose availability
  depends on host posture, capability policy, or adapter support.
- `alias`: A compatibility spelling that resolves to a target library and does
  not own implementation semantics.

Ordinary user imports of internal visibility tiers fail deterministically. Tests,
bootstraps, and host adapters use an explicit internal posture
(`internal-libraries-allowed`) rather than a separate resolver bypass. Public
imports and public aliases continue to work without that posture.

## Source Kinds

The seed manifests currently use these source kinds:

- `base-snapshot`: `(scheme base)` is registered from the current base
  environment snapshot.
- `source-library`: The resolver loads a checked-in `.sld` source file from the
  configured seed root.
- `primitive-library`: The resolver asks the host for the primitive
  implementation identified by manifest `implementation-id`.
- `derived`: The resolver derives the library from already-available libraries
  or runtime facilities; `(scheme r5rs)` is the current example.
- `facade`: A public or documented facade whose availability may vary by host.
- `alias`: The entry points at a target library and may optionally reduce the
  target's exported identifiers.

Primitive routing is by manifest `implementation-id`, not by library-name
prefix. This keeps names such as `(agent io)`, `(cli process-host primitive)`,
and `(emacs buffer)` from being special cases in resolver code. Provider-owned
primitive registration is still a larger #681/#682 follow-up, but #483 already
removes namespace-prefix dispatch from the import path.

## Exports

Repo-owned built-in collection manifest entries must declare `exports` for every
source kind: source libraries, primitive libraries, derived libraries, facades,
and aliases. This keeps reflection, search, public/internal enforcement, and
future provider-owned registration on the same explicit metadata surface. For
primitive libraries there is no source library to inspect, so the manifest is
the only readable contract.

Imported or adapted library entries use `upstream-source-url` for provenance
links to external source material. The field is deliberately named as upstream
metadata rather than local resolver state; local loading paths remain
`source-file` plus the collection's manifest-index `source-root`.

User-provided or ad-hoc source-library manifest entries may declare `exports`,
but they do not have to. When omitted, the catalog reads the source library's own
`export` declarations. When present, the manifest export list is a reducing
filter over the library-defined export list. For plain source libraries every
manifest-named export must exist in the source library. For source libraries with
a primitive overlay, such as `(agent approval)`, `(agent memory)`, and
`(agent session)`, the filter applies to the final overlaid library surface.
This lets user-provided collections publish a narrow contract without forking a
source library or making the resolver guess.

Alias manifest entries may also declare `exports`; the alias exposes only the
declared subset of the target library's exports.

## Availability

Manifest entries are `required` unless they say otherwise. Optional entries use
`availability . optional` plus an `availability-condition`, such as:

```scheme
(availability . optional)
(availability-condition . (host emacs))
```

An optional library remains visible as catalog metadata, but
`library-available?` reports false when the condition is not satisfied, and a
direct import fails with an unavailable-library error. This is intentionally not
a fallback path: optionality is manifest-declared availability, not permission
for the resolver to reconstruct old hard-coded registries.

## Prior Art

R7RS-small defines library names, imports, exports, and `cond-expand`; it does
not define a public/internal visibility taxonomy. R7RS library names are lists of
identifiers and exact non-negative integers; `define-library` declares exports;
import sets can use `only`, `except`, `prefix`, and `rename`; and
`cond-expand` can test `(library <library-name>)`. R7RS says implementations
that store libraries in files should document the name-to-file mapping. Consent
therefore layers visibility and seed-root mapping metadata on top of R7RS
without changing R7RS import syntax.

R7RS `define-library` also does not include R6RS-style phase or version
specifications. Version selection, dependency solving, and versioned resolution
behavior belong to #50 and the shared manifest schema work in #682, not to this
issue's public/internal surface enforcement.

SRFI 0 and R7RS `cond-expand` are availability checks, not manifest schemas.
SRFI 0 deliberately leaves the mechanism that makes a feature present to module
systems, configuration files, command-line options, dependency declarations, or
other implementation mechanisms. Consent should not treat feature presence as a
visibility contract.

SRFI 7 is a separate feature-based program configuration language with
`requires`, `files`, `code`, and `feature-cond` clauses. It is useful historical
context for machine-readable feature requirements, but it is not Consent's
library manifest model.

SRFI 97 is relevant to public import spellings. It standardizes SRFI library
references such as `(srfi :1)` and `(srfi :1 lists)`, says versioning
information is not used there, and distinguishes SRFIs that can be provided as
libraries from SRFIs that globally change syntax, top-level semantics, or
standard bindings. Consent preserves that split: public SRFI and stdlib aliases
are user-facing import names, while global runtime behavior and internal
substrate do not become public merely because a source file exists.

SRFI 103, although withdrawn, is useful file-layout prior art. It maps
list-of-symbol library names to filesystem components, searches directories,
recognizes file extensions, specifies ordering among multiple matching files,
and encourages precise dialect or format extensions. It informs source location
metadata without supplying a visibility model.

The R7RS-large Committee B docket is a planning list of portable libraries
grouped into dockets such as Red, Tangerine, Hypnos, Eos, Orange, Urania,
Selene, and Pan. Red and Tangerine are voted docket groups; other entries are
SRFI or non-SRFI candidates. The docket informs optional stdlib and SRFI alias
provenance, but it is not a manifest schema or visibility rule.

SRFI 233 is an INI-file library. It is generic configuration-file prior art, not
an upstream Scheme library-manifest standard.

Guile modules provide useful public/interface vocabulary: `define-module` names
a module, `#:export` and `define-public` declare public interface bindings,
`#:re-export` forwards imported bindings, `#:replace` marks intentional
replacement, and `@@` can access unexported bindings as a last-resort/debugging
escape. Consent keeps ordinary imports on explicit public exports and makes
internal access a deliberate posture.

Racket packages separate package management from module import paths. A package
is a set of modules or collections, but the package name is not mentioned in
`require`; packages manage collections rather than becoming module references.
Racket also treats two packages that contain the same module as conflicting.
Consent keeps the same conceptual split: roots and manifests manage
availability, while the public library surface is the importable library name
plus visibility metadata.

CHICKEN eggs and ASDF systems are package/build metadata precedents rather than
direct visibility models. CHICKEN `.egg` files record version, dependencies,
license, platform constraints, components, sources, and module/component
metadata. ASDF `defsystem` records Common Lisp systems, components,
dependencies, versions, pathnames, and feature conditions while Quicklisp
handles distribution. Those precedents are useful for #682 and #50; #483 uses
them only to motivate explicit metadata fields that later package and resolver
work can consume.

## Ownership Boundaries

#483 owns the current visibility vocabulary, seed manifest inventory, and
ordinary import enforcement for public versus internal libraries. #484 owns the
agent model/API namespace cleanup. #682 owns the full shared manifest schema and
load-light aggregation contract. #681 owns provider-owned primitive-library
registration. #50 owns package roots, dependency solving, version selection,
conflict records, and versioned resolution behavior.
