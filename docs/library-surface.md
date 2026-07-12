# Library Surface and Manifests

Consent Scheme's importable library surface is owned by Scheme-readable
manifests, not by hand-curated resolver lists. The manifests are the durable
inventory for issue #483: they say which libraries exist in the initial runtime,
which names are ordinary public imports, which names are internal substrate, and
which imports are host-conditional capability surfaces.

## Manifest Topology

The only built-in filesystem convention is that each configured manifest root is
a directory with a top-level `manifest.sld`. The default system manifest root in
a source checkout is `scheme/`, whose `scheme/manifest.sld` defines
`(manifest index)` and links the collection-local manifests. The index also
references itself through a `manifest` collection entry, so the aggregate
manifest library is part of the same manifest graph rather than a special
library outside the catalog:

- `scheme/consent/manifest.sld` for R7RS-small, core Consent Scheme, and runtime
  implementation libraries.
- `scheme/stdlib/manifest.sld` for optional stdlib, SRFI, and R7RS-large-facing
  aliases or owned portable libraries.
- `scheme/testing/manifest.sld` for reusable portable testing facilities;
  project-specific test programs, plan data, and fixtures remain outside the
  manifest graph.
- `scheme/agent/manifest.sld` for public agent APIs and internal agent primitive
  backing libraries.
- `scheme/cli/manifest.sld` for CLI adapter-facing libraries.
- `scheme/emacs/manifest.sld` for Emacs host-adapter capability libraries.
- `scheme/manifest.sld` for the aggregate manifest collection itself.

Collection manifests use collection-local `(source (path ...))` values. For
example, `scheme/agent/manifest.sld` records `(source (path "memory.sld"))`,
not `scheme/agent/memory.sld` and not `../agent/memory.sld`. The top-level
manifest index provides the collection's `source-root`, so a resolver configured
with a different manifest root can still aggregate the same collection without
child manifests peeking up into sibling directories.

The Emacs Lisp bootstrap reads ordered `consent-library-system-path` and
`consent-library-user-path` root lists. The portable Scheme runtime exposes the
same split as system and user directory lists, with the older combined search
directory setter preserved as a compatibility shim for host runners. Compiled
products also carry the embedded `manifest.sld` graph as the final system root,
after configured filesystem roots. Catalog resolution uses a deterministic
precedence order: ad-hoc manifests added at runtime, explicit manifest-root
inputs added at runtime, then the built-in manifest seed assembled from the
configured system/user roots. Duplicate names are first-wins and produce
conflict records and catalog diagnostics rather than silently disappearing.

Manifests do not become the only authority for imports. A library already
registered in an evaluator context, including a library defined ad hoc in a REPL
session with `define-library`, remains importable even when no manifest entry
exists for it. Manifest records provide durable initial inventory and catalog
metadata; the live registry remains the authority for libraries that have
already been defined in the current context.

The top-level index also assigns each collection a default catalog `category`.
Collection-local entries inherit that value unless they declare their own
`category`. This is how `(scheme ...)` R7RS-small libraries remain categorized
as `standard` even though their manifest is owned by the `consent` collection,
and how R7RS-large or SRFI-facing entries remain categorized as `stdlib`
without resolver code testing library-name prefixes.

## Shared Manifest Schema

The canonical shared metadata record is a tagged Scheme datum. New authored
metadata should use `manifest-entry` for owner-authored records and
`manifest-index-entry` for derived index records:

```scheme
(manifest-entry
  (schema-version 1)
  (kind library)
  (name (agent task))
  (owner agent-domain)
  (provider repo-source)
  (visibility public)
  (layer api)
  (source-kind source-library)
  (source (path "task.sld"))
  (api-version (compat 0))
  (source-version unknown)
  (realization portable-source)
  (exports (make-task task? task-field-value))
  (dependencies ((library (scheme base))))
  (effects ())
  (capabilities ())
  (documentation ((summary "Task records and helpers.")))
  (provenance ((origin repo)))
  (status available)
  (canonical #t))
```

Schema version `1` has these required common fields:

- `schema-version`: manifest schema version. This is independent from the
  Consent runtime version, library API versions, source revisions, and
  dependency constraints.
- `kind`: subject category, such as `library`, `primitive-library`,
  `library-alias`, `stdlib-entry`, `package-root`, `skill-library`,
  `realization`, or `manifest-index`.
- `name`: Scheme-readable subject name. Library names are lists.
- `owner`: semantic owner of the contract, such as `consent-core`, `stdlib`,
  `agent-domain`, `host-adapter`, `project`, `user`, or `skill`.
- `provider`: declaration provider, such as `repo-source`, `portable-runtime`,
  `emacs-host`, `agent-memory`, or a configured manifest root.
- `visibility`: a visibility tier documented below.
- `layer`: the layer vocabulary from #484 or a standard layer such as
  `standard`, `stdlib`, `runtime`, `adapter`, `primitive`, `alias`, or
  `package`.
- `source-kind`: declaration source category, such as `source-library`,
  `primitive-library`, `mixed`, `vendored-source`, `shim`, `alias`,
  `generated`, `host-adapter`, `manifest`, or `external-package`.
- `source`: source metadata that is useful without loading implementation code,
  such as `(path "agent/task.sld")`, `(target (stdlib json))`,
  `(implementation-id agent-memory)`, `(upstream-url "...")`, or richer
  provenance records.
- `api-version`: compatibility version for the Scheme-visible API when the
  subject is importable or otherwise user-facing, such as `(compat 0)`,
  `internal`, or `(inherits (stdlib json))`.
- `source-version`: upstream, package, generated-source, vendored-source, or
  runtime source identity when known; use `unknown` when there is no independent
  source version and `runtime` for runtime-owned primitive or snapshot
  surfaces.
- `realization`: broad implementation category, such as `portable-source`,
  `host-primitive`, `emacs-primitive`, `vendored-source`, `runtime-snapshot`,
  `shim`, `derived`, or `alias`.
- `exports`: exported identifiers when known load-light. See the export rules
  below for omission and alias inheritance.
- `dependencies`: explicit edges to other manifest subjects. Library edges use
  `(library <library-name>)`; version constraints may appear as data, but #50
  owns their resolver meaning.
- `effects`: effect metadata when relevant.
- `capabilities`: capability requirements when relevant.
- `documentation`: summary text, documentation hooks, or references to
  docstring metadata.
- `provenance`: origin, license, vendoring, pin, source revision, content hash,
  or generated-from metadata.
- `status`: state such as `available`, `implemented`, `shimmed`, `alias`,
  `internal`, `experimental`, `missing`, or `disabled`.
- `canonical`: true when this record is owner-authored metadata for its subject.

Consumers must ignore unknown fields unless a field is documented as mandatory
for the record's `kind`. This lets #681 primitive declarations, #50 package
roots, #486 realization records, and future skill/package manifests add local
metadata without defining separate envelopes.

Built-in collection manifests are authored in the tagged vocabulary above.
Both the Emacs and portable Scheme bootstraps read `manifest-entry` and
`manifest-index-entry` records directly, then derive their internal catalog
route fields from `source`, `target`, and the root index. Ad-hoc manifests,
manifest-root inputs, package roots, skill roots, and future external metadata
use the same tagged shape.

Version metadata stays separated:

- `schema-version` validates the manifest record shape.
- The runtime version comes from `(consent version)`.
- `api-version` records compatibility for the Scheme-visible API.
- `source-version`, source revisions, content hashes, and pins record source
  or provenance identity.
- Dependency constraints are data until #50 defines resolver policy.
- R7RS import syntax is unchanged; version selection is not a new import form.

## Derived Index Entries

Derived records use the same field vocabulary but mark themselves as
non-canonical and point back to their source:

```scheme
(manifest-index-entry
  (schema-version 1)
  (kind library-alias)
  (name (srfi 180))
  (target (stdlib json))
  (derived-from (stdlib manifest))
  (visibility public)
  (layer alias)
  (source-kind alias)
  (api-version (inherits (stdlib json)))
  (canonical #f))
```

Canonical metadata is authored by the semantic owner. Derived records are built
by aggregation, alias expansion, reflection, or resolver indexing. A derived
record must not override canonical visibility, ownership, capability, or effect
semantics, and a public alias must not make an internal target public.

## Load-Light Aggregation Contract

Catalog aggregation may read checked-in manifest data, manifest libraries
intended to be load-light, registry declaration data, provider-owned declaration
datums, vendored manifest metadata, and ad-hoc manifest roots supplied as data.
It must not initialize an agent domain implementation, host adapter transport,
process/network provider, UI adapter, persistence backend, or arbitrary
project/user library just to inspect metadata. Fields that are not knowable
load-light should be omitted or recorded as `unknown` or `deferred`; aggregation
must not silently load implementation code to fill them.

This contract is why provider and owner are distinct. A host adapter may provide
declarations for host-backed primitives, but that does not make the adapter the
semantic owner of a portable `(agent ...)` API. Primitive-library declarations
from #681 are canonical for provider-owned primitive surfaces; portable
semantic ownership remains with the library or domain that defines the
Scheme-visible contract.

## Manifest Root And Index Vocabulary

Each manifest root is a directory containing a top-level `manifest.sld`. That
file is load-light metadata, not an arbitrary implementation module. It defines
the root index library, normally `(manifest index)`, whose index entries expose
collection manifests without hard-coded child-directory knowledge.

Root index records use these fields:

- `collection`: collection identifier within the root.
- `category`: default catalog category for entries in that collection.
- `manifest-library`: load-light library name that owns the collection manifest
  datum.
- `manifest-variable`: variable containing the quoted collection manifest.
- `manifest-file`: root-relative path to the collection manifest file.
- `source-root`: root-relative directory prefix applied to collection-local
  `(source (path ...))` values.
- Root identity fields such as root kind, provider, trust tier, provenance,
  source revision, or source hash may be represented as manifest data for
  system, user, project, skill, or explicit manifest roots.

The only built-in filesystem convention is that top-level `manifest.sld` file.
Collection manifest paths and library source paths are relative to the root that
declared them. A manifest entry must not require a resolver to know that the
root is named `scheme`, peek above the configured root, or hard-code sibling
collection directories.

The reflected resolver surface includes `library-resolve`, `library-load`,
`library-solve-dependencies`, `library-paths`, `library-conflicts`, and
`library-snapshot`. Resolution records report name, resolved target, root,
source kind, source identity, visibility, layer, owner, provider, trust, status,
and denial or availability reason when applicable. `library-conflicts` reports
the candidate set behind a duplicate name; `library-snapshot` records the
selected library and dependency closure in resolver order.
`library-solve-dependencies` reports `unsatisfied-dependency` and
`missing-dependencies` when a transitive manifest edge is absent. The SRFI
intake helper `vendored-srfi-manifest` derives a `vendored-srfi` record from the
same catalog, preserving implementation library, import aliases, source URL,
upstream revision or tag, license/local-license fields, local patches,
dependencies, status, tests, and shim classification.

## Visibility Tiers

Manifest entries use the following visibility vocabulary:

- `public`: Importable by ordinary user or agent code. This is a compatibility
  promise and should appear in user-facing discovery.
- `public-consent`: Curated `(consent ...)` libraries that are part of the
  user-facing Consent Scheme API even though they share the `consent` root with
  runtime internals.
- `internal-runtime`: Reader, evaluator, macro, runtime, bootstrap, resolver,
  primitive backing, and pass libraries that are implementation substrate.
- `internal-agent-primitive`: Agent primitive backing libraries used to attach
  host-provided effects to public `(agent ...)` APIs.
- `host-adapter`: Host-specific capability-adapter libraries whose availability
  depends on host posture, capability policy, or adapter support.
- `alias`: A compatibility spelling that resolves to a target library and does
  not own implementation semantics.

Ordinary user imports of internal visibility tiers fail deterministically. Tests,
bootstraps, and host adapters use an explicit internal posture
(`internal-libraries-allowed`) rather than a separate resolver bypass. Public
imports and public aliases continue to work without that posture.

## Agent Domain Layers

Public agent-domain APIs live at `(agent <domain>)`. When the domain has
host-neutral records, constructors, stores, predicates, selectors, or pure
transformations, the portable source library at that public name owns them
directly. Do not introduce a private `(agent model <domain>)` tier merely to
hide the backing implementation behind a public veneer.

Host effects for an agent domain live behind explicit primitive backing
libraries such as `(agent memory primitive)` or `(agent session primitive)`.
Those entries use `visibility . internal-agent-primitive`, `layer . primitive`,
and `source-kind . primitive-library`; ordinary user imports are denied unless a
bootstrap, test, or host adapter opts into `internal-libraries-allowed`.

Model-provider routing is a different layer. The public model protocol lives at
`(agent models)`, provider-specific portable adapters live under
`(agent models <provider>)`, and host-owned routing or live transport effects
remain behind `(agent models primitive)`. The `models` plural is intentional:
it names backend model providers and should not be confused with agent-domain
record/model data.

## Source Kinds

The seed manifests currently use these source kinds:

- `base-snapshot`: `(scheme base)` is registered from the current base
  environment snapshot.
- `source-library`: The resolver loads a checked-in `.sld` source file from the
  manifest root that declared the collection.
- `primitive-library`: The resolver materializes provider-declared primitive
  exports through the host resolver named by manifest `implementation-resolver`.
- `derived`: The resolver derives the library from already-available libraries
  or runtime facilities; `(scheme r5rs)` is the current example.
- `facade`: A public or documented facade whose availability may vary by host.
- `alias`: The entry points at a target library and may optionally reduce the
  target's exported identifiers.

Primitive routing is by provider-owned manifest declarations, not by library-name
prefix or resolver-owned `implementation-id` switches. This keeps names such as
`(agent io)`, `(cli process-host primitive)`, and `(emacs buffer)` from being
special cases in resolver code. `implementation-id` remains provider identity
metadata; `implementation-resolver` names the host module/procedure that
materializes primitive implementations, and `primitive-exports` declares the
binding surface.

## Provider-Owned Primitive Declarations

Primitive libraries may add provider-owned export metadata without making the
resolver enumerate the provider's primitive surface. The manifest keeps the
existing flat `exports` list as the catalog-visible binding list and adds
`primitive-exports` for per-binding primitive metadata:

```scheme
(primitive-exports
 ((name current-budget)
  (primitive primitive-current-budget)
  (arity 0 0)
  (effects (reflection))
  (capabilities ()))
 ((name budget-yield)
  (primitive primitive-budget-yield)
  (arity 0 0)
  (effects (state-write reflection))
  (capabilities ())))
```

Each primitive export must declare its Scheme-visible `name`, primitive
implementation identifier, exact arity range, effect metadata, and capability
requirements. The resolver validates declarations, checks duplicate and
conflicting provider entries, and preserves metadata inspection without loading
the implementation module. Host implementation functions are materialized only
when the selected primitive library is imported.

Repo-owned primitive libraries use provider-owned declarations instead of a
resolver-owned routing table. Package/root precedence, realization/parity
reporting (#486), and generalized foreign-import schema work (#379) consume this
data plane; they do not require the resolver to relearn each provider's exported
primitive surface.

## Exports

Repo-owned built-in collection manifest entries that own an implementation
surface must declare `exports`: source libraries, primitive libraries, derived
libraries, and facades. This keeps reflection, search, public/internal
enforcement, and future provider-owned registration on the same explicit
metadata surface. For primitive libraries there is no source library to inspect,
so the manifest is the only readable contract.

Imported or adapted library entries use `upstream-source-url` for provenance
links to external source material. The field is deliberately named as upstream
metadata rather than local resolver state; local loading paths are derived from
`(source (path ...))` plus the collection's manifest-index `source-root`, both
relative to the manifest root that supplied the entry.

User-provided, project, skill, ad-hoc, or otherwise external source-library
manifest entries may declare `exports`, but they do not have to. Omission means
the exports are unknown to load-light metadata until a safe source parser or an
already-loaded library definition reports them; aggregation must not evaluate
the project library just to discover exports. When present, the manifest export
list is a reducing filter over the library-defined export list. For plain source
libraries every manifest-named export must exist in the source library. For
source libraries with a primitive overlay, such as `(agent approval)`,
`(agent memory)`, and `(agent session)`, the filter applies to the final
overlaid library surface. This lets user-provided collections publish a narrow
contract without forking a source library or making the resolver guess.

Pure alias manifest entries may omit `exports`; the alias then inherits the
target library's full export surface. Reducing alias entries declare `exports`,
and the alias exposes only that declared subset of the target library's exports.
The built-in manifests use this rule to avoid repeating large SRFI and R7RS-large
alias export lists while keeping subset aliases such as `(stdlib json read)`
explicit.

A public alias must not use inheritance or export reduction to make an internal
target public. Visibility and capability semantics come from the canonical
target metadata, not from the derived alias record.

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
therefore layers visibility and manifest-root mapping metadata on top of R7RS
without changing R7RS import syntax.

R7RS `define-library` also does not include R6RS-style phase or version
specifications. R7RS feature identifiers include implementation names and
implementation name-version identifiers, but those are feature flags for
`cond-expand` and `features`, not library API versions. Consent therefore keeps
`api-version`, `source-version`, source hashes, dependency constraints, and
provenance pins in manifest metadata. Version selection, dependency solving, and
versioned resolution behavior belong to #50.

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
and encourages precise dialect or format extensions. It also describes
environment variables and extension lists for searched library directories. It
informs `source`, `source-kind`, dialect/format, and search metadata without
supplying package manifests, source provenance, public/internal visibility,
version selection, or dependency solving.

The R7RS-large Committee B docket is a planning list of portable libraries
grouped into dockets such as Red, Tangerine, Hypnos, Eos, Orange, Urania,
Selene, and Pan. Red and Tangerine are voted docket groups; other entries are
SRFI or non-SRFI candidates. The docket informs optional stdlib and SRFI alias
provenance, but it is not a manifest schema or visibility rule.

SRFI 233 is an INI-file library. It is generic configuration-file prior art, not
an upstream Scheme library-manifest standard.

R6RS is the main Scheme standard prior art for versioned library references.
R6RS library names may include versions, imports may constrain imported library
versions, and imports can specify levels/phases with `for`. Version references
support exact sub-version matches plus `>=`, `<=`, `and`, `or`, and `not`. R6RS
also leaves the choice implementation-dependent when a reference identifies
more than one library, and warns implementations to avoid coexisting
incompatible same-name libraries because of type and state problems. Consent
uses this as prior art for representing version constraints as data; #50 owns
how to choose, reject, or report versions.

Guile modules provide useful public/interface and version vocabulary:
`define-module` names a module, `#:export` and `define-public` declare public
interface bindings, `#:re-export` forwards imported bindings, `#:replace` marks
intentional replacement, and `@@` can access unexported bindings as a
last-resort/debugging escape. Guile's `#:version` and `use-modules #:version`
preserve R6RS-compatible version references in an implementation setting, and
Guile errors when a same-name loaded module is incompatible with a requested
version. Consent keeps ordinary imports on explicit public exports and makes
internal access a deliberate posture.

Racket packages separate package management from module import paths. A package
is a set of modules or collections, but the package name is normally not
mentioned in `require`; packages manage collections rather than becoming module
references. Racket package metadata includes package names, checksums, versions,
dependencies, `info.rkt` fields, package sources, and SPDX-shaped license
metadata. It treats checksum as release/update identity even when version does
not change, and dependency entries may name a package source plus an optional
lower-bound version. Consent keeps the same conceptual split: roots and
manifests manage availability, while the public library surface is the
importable library name plus visibility metadata.

CHICKEN eggs are close practical Scheme-readable manifest prior art. `.egg`
files record versions, synopsis, author, maintainer, category, license,
dependencies, test/build/foreign dependencies, platform constraints,
distribution files, components, source files, module names, component
dependencies, compile/link options, and conditional `cond-expand` entries.
Dependencies may be simple egg names or `(EGGNAME VERSION)` entries where the
version means that version or higher.

ASDF is Common Lisp build-system prior art, not a package manager. It defines
systems, components, dependencies, pathnames, versions, feature conditions, and
operations while Quicklisp handles finding and downloading libraries. ASDF's
`x.y.z` version convention, feature dependencies, and `:if-feature` clauses
support Consent's separation between manifest metadata and #50 resolver
behavior.

Guix and Nix are the strongest provenance and content-addressed deployment
prior art. Guix package definitions are written in Guile Scheme and include
fields such as `name`, `version`, `source`/`origin`, source URI, `sha256`, build
system, inputs, synopsis, description, home page, and license. Guix and Nix use
immutable store paths, per-user profiles, transactional upgrades, rollbacks,
garbage collection, and coexistence of multiple package versions. For Consent
this informs provenance, source hash, stable identity, reproducible metadata,
and future content-addressed exchange while leaving Scheme library import
syntax separate from package deployment.

The existing `(stdlib manifest)` is Consent-local prior art for this schema. It
already records source URLs, upstream revisions, licenses, local patches, import
aliases, dependencies, and test status for stdlib libraries. This shared schema
folds that shape into common fields rather than replacing it with an unrelated
envelope.

The content-addressed library store design treats the library as the policy
grain for naming, versioning, exchange, blast radius, capability adoption, and
macro/phase coherence, while allowing internal definition-addressed sharing and
type identity. It also treats liveness as re-linking: new content gets a new
hash/version and existing importers keep their old link. This schema preserves
the metadata hooks for that direction without implementing exchange, package
deployment, or dependency solving here.

## Ownership Boundaries

#483 owns the current visibility vocabulary, seed manifest inventory, and
ordinary import enforcement for public versus internal libraries. #484 owns the
agent-domain, primitive-backing, and model-provider layer rule. #682 owns the
shared manifest schema and load-light aggregation contract documented here.
#681 owns provider-owned primitive-library registration using this schema. #50
adds package roots, dependency solving, conflict records, trust gates, and
snapshot-oriented resolution behavior. #486 owns realization and parity content
using this schema rather than a second metadata envelope.
