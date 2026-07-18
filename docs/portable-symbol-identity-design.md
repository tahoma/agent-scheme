# Portable Symbol Identity and Interning Design

**Issue:** #346

**Roadmap version:** 0.18.33

**Status:** Approved for implementation planning

## Summary

Consent Scheme will own the identity and interning of user-visible symbols
instead of inheriting those semantics from the host Scheme or Emacs Lisp
runtime. A focused internal `(consent symbol)` library will own symbol records,
symbol tables, and interning. Evaluation contexts will carry an explicit
symbol-table handle whose persistent root is visible to the runtime state model
and can later participate in checkpoint fork, commit, and abort work.

This ownership is also the native-compiler end state. A native Consent image
will compile and link this same portable symbol library and use its table as
the only symbol table. It will not acquire a second interning authority from
its code generator, runtime, or platform. Host-symbol conversion described
below exists only at a borrowed-host bootstrap ABI and disappears when both
sides of a call use Consent's native value representation.

The symbol table will be backed by a new public persistent AVL tree library,
`(data avl-tree)`. The AVL tree is a general-purpose portable data structure,
not symbol-specific implementation substrate. A second public consumer,
`(data mapping avl)`, will provide AVL-selecting constructors for the existing
SRFI 146 Mapping interface. The existing red-black implementation remains the
default Mapping backend; its balancing implementation is not replaced.

This produces the following dependency direction:

```text
(consent symbol)          (data mapping avl)
        |                         |
        +------> (data avl-tree) <+
                         |
                   (scheme base)

(stdlib mapping) -- default provider --> (stdlib rbtree)
        |
        +---------- shared ordered-Mapping implementation
                         ^
                         |
                 AVL provider adapter
```

## Goals

- Give Consent Scheme symbols a portable representation and stable name-based
  semantics independent of host-native symbol identity.
- Make `(consent symbol)` the single semantic owner that a future native
  compiler links directly, without a backend-specific symbol table.
- Intern every user-visible symbol through an explicit symbol table.
- Make the symbol-table root part of evaluation state so later checkpoint work
  can share and branch it without copying the whole table.
- Preserve the current process-wide default identity behavior for callers that
  do not provide an explicit symbol table.
- Keep symbol-table lookup allocation-free and lookup, insertion, and deletion
  logarithmic.
- Introduce a supported public namespace for portable, project-owned data
  structures not covered by Scheme standards or SRFIs.
- Expose the AVL implementation as a useful persistent collection rather than
  an incidental core detail.
- Exercise the AVL abstraction through both symbol interning and an optional
  SRFI 146 Mapping provider.
- Keep the existing red-black Mapping behavior, aliases, and default constructor
  semantics compatible.

## Non-goals

- Implement checkpoint fork, commit, or abort. Issues #716 and #721 own those
  operations; this issue only exposes the persistent symbol-table root they
  will need.
- Implement `(scheme mapping hash)` or the SRFI 146 hash variant. Issue #624
  remains responsible for that work.
- Change `(scheme mapping)`, `(srfi 146)`, or `(srfi srfi-146)` to default to
  AVL storage.
- Expose symbol-table operations as a public user collection API.
- Expose AVL nodes, rotations, heights, or balance factors.
- Make host-native symbols valid Consent Scheme symbol values.
- Add uninterned or generated-symbol semantics beyond the existing language
  requirements.

## The `(data ...)` Namespace

`(data ...)` is the public home for portable, general-purpose data structures
that Consent Scheme supports but that do not have a standard Scheme or SRFI
library name. Admission to the namespace requires a reusable abstraction with
documented semantics; an internal helper does not become public merely because
it stores data.

Libraries in this namespace:

- use `visibility public` in their collection manifest;
- avoid dependencies on Consent runtime, evaluator, reader, policy, or host
  adapter libraries;
- expose abstract values rather than representation records;
- use the leaf library name as the exported identifier prefix, such as
  `avl-tree-ref` and `avl-tree-delete`;
- retain their project-owned API if a later standard covers similar behavior,
  with a standard adapter or compatibility library added separately.

The implementation adds a `scheme/data/manifest.sld` collection manifest and
registers it through the same manifest and source-library inventories as other
portable collections.

## Public Persistent AVL Trees

### Library and representation

`scheme/data/avl-tree.sld` defines `(data avl-tree)`. It imports only
`(scheme base)`.

An AVL tree value contains:

- a strict ordering procedure;
- an opaque persistent root node or the empty root;
- an exact entry count.

Each opaque node contains a key, value, left child, right child, and cached
height. The entry count belongs to the tree wrapper rather than every node.
Lookup does not allocate. Updates allocate only a new tree wrapper and the
nodes on changed search and rotation paths; unchanged subtrees are shared.

The ordering procedure must describe a strict total order. Two keys identify
the same entry when neither orders before the other. This deliberately avoids
a dependency on SRFI 128 comparators. A Mapping adapter can derive the ordering
procedure from an ordered comparator, while `(consent symbol)` can pass
`string<?` directly.

### Public surface

The first public surface is a coherent ordered map rather than a symbol-table
special case. It includes:

- construction and predicates;
- emptiness and constant-time size;
- containment, value lookup, and stored-key lookup with explicit failure
  handling;
- persistent adjoin, set, replace, and deletion;
- ascending and descending traversal and folds;
- minimum, maximum, predecessor, and successor queries;
- split, catenate, and monotone mapping operations needed by ordered Mapping;
- alist conversion conveniences.

Exact procedure signatures will be fixed in the implementation plan and tests.
All public names use the `avl-tree-` prefix. Procedures ending in `!` are not
introduced: the collection's contract is persistent, and linear-update aliases
belong to the Mapping facade where SRFI 146 requires them.

AVL invariants are implementation guarantees:

- keys in the left subtree precede the node key;
- node keys precede keys in the right subtree;
- cached heights are correct;
- left and right heights differ by at most one;
- the tree count equals the number of associations.

The representation-neutral invariant checker is public for tests, diagnostics,
and user verification.  Node representation and accessors remain private.

## Mapping Provider Layer

### Semantic capabilities

Mapping storage is classified by semantics rather than by one implementation
technique. Every provider supplies common finite-mapping operations such as
lookup, insertion, deletion, traversal, and size. Ordered providers additionally
supply minimum, maximum, predecessor, successor, ordered folds, ranges, split,
catenate, and monotone mapping.

Red-black and AVL trees implement the common and ordered capabilities. A future
hash table, HAMT, or association-list provider would implement the common
capabilities without claiming ordering. Hashability is a requirement of
particular providers, not the definition of an unordered Mapping.

Persistence, weak keys, concurrency, and external storage are orthogonal
semantic dimensions. This issue does not generalize the provider protocol to
support contracts that SRFI 146 ordered Mapping does not already permit.

### Refactoring the existing Mapping implementation

The current `(stdlib mapping)` implementation remains the single owner of the
SRFI 146 ordered algorithms and remains backed by the existing
`(stdlib rbtree)` by default. This issue does not reimplement red-black
balancing.

The implementation will separate the existing Mapping record and algorithms
from the selected ordered storage operations. A Mapping value will retain:

- its SRFI 128 key comparator;
- its ordered provider identity or operation bundle;
- its provider-owned persistent root.

The existing red-black functions are connected to that seam with a thin
adapter. The AVL adapter delegates to `(data avl-tree)`. Generic Mapping
operations preserve the source Mapping's provider when producing a derived
Mapping. Operations involving two mappings use provider-independent logic when
the providers differ, while same-provider paths may use split or catenate
optimizations.

The shared implementation substrate is not a second public Mapping API. Public
facades select constructors and export only their intended surface, preventing
internal provider hooks from leaking through the standard aliases.

### `(data mapping avl)`

`scheme/data/mapping/avl.sld` defines the optional public library
`(data mapping avl)`. It exports AVL-selecting constructors, initially:

- `avl-mapping`;
- `avl-mapping-unfold`;
- `alist->avl-mapping`.

The returned values satisfy the ordinary `mapping?` predicate and work with
all procedures imported from `(scheme mapping)`, `(srfi 146)`, or
`(stdlib mapping)`.

Typical use is:

```scheme
(import (scheme comparator)
        (scheme mapping)
        (data mapping avl))

(define table
  (avl-mapping string-comparator
               "alpha" 1
               "beta" 2))

(mapping-ref table "alpha")
```

`(data mapping avl)` does not re-export the standard `mapping-*` identifiers.
That avoids import collisions and keeps responsibilities clear: the standard
library owns Mapping operations, while the data library selects AVL storage.

The existing Mapping conformance corpus will run against both the default
red-black constructors and the AVL constructors. Tests are parameterized rather
than copied.

## Portable Symbols

### Owned representation

`scheme/consent/symbol.sld` defines the internal `(consent symbol)` library. A
Consent Scheme symbol is an opaque record with an immutable string name. The
record is the only user-visible symbol representation accepted by `symbol?`.
Host Scheme and Emacs Lisp symbols remain valid only as private bootstrap,
dispatch, and metadata keys.

The library owns:

- symbol construction through interning;
- symbol predicates and name access;
- symbol-table construction and root access needed by runtime state;
- name-based symbol equality helpers;
- conversion at explicitly named private host boundaries.

The symbol record constructor is not a general public escape hatch. All normal
creation paths intern through a symbol table.

### Symbol tables

A symbol table is a runtime-owned handle whose current persistent root is a
`(data avl-tree)` mapping from symbol-name strings to owned symbol records. The
handle permits an evaluation to install a new persistent root after insertion
while existing roots remain valid snapshots.

Interning performs these steps:

1. Validate or normalize the requested name as a string.
2. Search the current AVL root with `string<?`.
3. Return the existing record without allocation when present.
4. Otherwise allocate one symbol record, persistently insert it, install the
   resulting root in the handle, and return the record.

The runtime owns one default process symbol table. Existing entry points that
do not receive an explicit table use this default, preserving same-name symbol
identity across ordinary calls. Each evaluation context carries a symbol-table
handle explicitly. Later checkpoint work can fork a handle from a saved root
and choose how roots are committed or discarded without changing symbol or AVL
representation.

This issue exposes no public fork, commit, or abort procedures.

### Equality

Symbol equality follows the existing Consent behavior while becoming portable:

- `eq?` and `eqv?` first recognize identical owned records, then treat two
  owned symbols with equal names as equivalent;
- `symbol=?` compares the names of all supplied owned symbols;
- `equal?` reaches the same result through its `eqv?` case;
- symbols and strings are never equivalent;
- host-native symbols are not Consent Scheme symbols.

The name fallback makes symbols created from explicit isolated roots behave
consistently across checkpoint or transport boundaries. Interning still
provides the fast identity path within a shared table.

### Reader, evaluator, and macro integration

Evaluation entry points create the evaluation context before reading source and
pass its symbol-table handle through reader options. Every reader path that
produces a user datum uses that table, including:

- ordinary identifiers;
- vertical-bar identifiers;
- quote, quasiquote, unquote, and unquote-splicing heads;
- datum labels whose referenced values contain symbols;
- recovery and incremental reader entry points;
- source-loaded user libraries and program input.

Bootstrap-only host identifiers may continue to exist while the source-library
machinery is establishing the portable core, but they must not escape as user
datums. Boundary code normalizes bootstrap and library identifiers to strings
before using them as registry or binding keys.

Macro-introduced identifiers intern through the evaluation context's table.
Lexical and syntax identity remains the combination of the symbol name and
syntax-context metadata; it does not depend on host symbol identity. Binding,
library, export, primitive-dispatch, and reflection indexes normalize symbolic
names to strings plus whatever syntax-context information their layer owns.

### Base primitives and writing

The `(scheme base)` symbol procedures delegate to `(consent symbol)`:

- `symbol?` recognizes owned records;
- `symbol->string` returns the immutable name value according to R7RS rules;
- `string->symbol` interns through the current evaluation context;
- `symbol=?`, `eq?`, `eqv?`, and `equal?` use the owned semantics above.

The writer recognizes owned symbols and uses the existing R7RS identifier
escaping rules on their names. Read/write round trips must not convert through
host-native symbol identity.

Host adapters that genuinely require an Emacs Lisp or host Scheme symbol use
private, explicitly named conversion functions at that boundary. These adapters
do not change the language-level predicate or equality rules.

Portable libraries import `(scheme base)` without renaming or locally
redefining these procedures. When a borrowed R7RS compiler executes one of
those libraries natively as an internal runtime backend, the native-call bridge
converts owned symbols to ordinary host symbols before native code sees them.
The inverse bridge interns host symbols from native results in the calling
evaluation context before interpreted code sees them. Callback arguments and
results consumed by the native library cross the same two conversions in their
corresponding directions. Opaque host controls preserve callback results until
the outer result barrier, avoiding a redundant whole-graph round trip.
The central runtime barrier may also perform the owned-to-host conversion for
compiled CLI or adapter code on that borrowed host, because its `(scheme base)`
still denotes the host implementation. Reader-owned forms remain opaque until
evaluation, and values that re-enter Consent are interned into the active
context.
The outer borrowed-host egress handles long proper-list result spines
iteratively; cycle-aware recursive conversion remains for nested graphs. This
keeps large audit streams and file-driven workloads linear in result size.
The compiled library therefore remains representation-agnostic and uses only
the ordinary procedures it imported from `(scheme base)`.

### Native compiler invariant

The borrowed-host bridge is bootstrapping scaffolding, not part of the symbol
model. Compiler plans include `(data avl-tree)`, `(data transient-map)`, and
`(consent symbol)` as ordinary repository-owned source units with dependency
order derived from collection manifests. On a borrowed R7RS host, those
libraries are compiled and linked so that compiled `(consent symbol)` calls
its compiled dependencies directly. The borrowed-host image also registers
those compiled realizations for interpreted imports so both sides share the
symbol owner's record types and single table. The public AVL root type crosses
that boundary with it. The transient overlay remains a direct compiled
dependency and may be source-evaluated for an explicit interpreted import
because its private records do not cross the core interface. Callback and
opaque-record wrappers are strictly bootstrap ABI. A native Consent backend
compiles callers and callees into one Consent value domain and therefore needs
no such wrappers.

A native Consent backend therefore:

- uses the portable symbol record as its runtime symbol representation;
- links the portable transient and persistent table implementation directly;
- carries the evaluation context's table through reading, expansion,
  evaluation, and compiled execution;
- performs no host-symbol conversion between Consent-compiled libraries; and
- confines any foreign symbol conversion to an actual FFI or bootstrap edge.

No optimization may introduce an independent backend intern table. A native
backend may specialize or inline the portable operations only while preserving
the one table's identity, root, budget, and checkpoint semantics.

## Resource Accounting

The existing `interned-symbols` budget remains an evaluation budget for
evaluated `string->symbol` operations. Each evaluated call is charged before
the lookup, including a call that finds an existing symbol, preserving current
stop-receipt behavior.

Reader-created identifiers are bounded by the reader's existing datum, source,
and value-node limits rather than charged as evaluated `string->symbol` calls.
An insertion allocates at most one symbol record plus the AVL update path.
Repeated reads or conversions of an existing name allocate no new symbol and no
new AVL path.

## Error Handling

- Public AVL operations reject invalid tree arguments and non-procedure ordering
  arguments with ordinary Scheme errors.
- Missing AVL lookups use an explicit failure thunk or documented default form;
  stored `#f` values remain distinguishable from absence.
- AVL Mapping constructors require an ordered SRFI 128 comparator.
- Mapping operations preserve existing SRFI 146 preconditions and error
  behavior regardless of backend.
- Symbol primitives reject host-native symbols and other non-symbol values.
- Exhausting the interning budget produces the existing `interned-symbols`
  stop reason.

## Verification Strategy

### AVL tree

Portable tests compare arbitrary insertion, replacement, deletion, and lookup
sequences against a simple alist model. After every update, private white-box
checks verify ordering, height, balance, count, and structural persistence.
Targeted cases cover all single and double rotations, root deletion, internal
deletion, absent deletion, predecessor/successor edges, split/catenate, and
ascending/reverse traversal.

### Mapping provider

The existing compact and upstream-derived SRFI 146 suites run once with the
red-black constructors and once with the AVL constructors. Additional tests
cover provider preservation, mixed-provider operations, absence of import-name
collisions, manifest discovery, and unchanged standard-alias defaults.

### Symbols

Shared portable tests cover:

- repeated reader and `string->symbol` interning;
- identity across reader and evaluator paths sharing a table;
- same-name equivalence across isolated table roots;
- symbol predicates, names, equality, and writer round trips;
- quoted and macro-introduced identifiers;
- binding and library lookup without host-symbol identity;
- process-default and explicit-table behavior;
- interning-budget preservation and exhaustion receipts;
- bounded growth for repeated existing names.

The corpus runs through the portable Scheme hosts and the Emacs bootstrap.
Parity tests confirm that both bootstraps observe the same public values,
diagnostics, and receipts. Compiled-host smoke tests cover the new source
libraries and manifests.

## Delivery and Documentation

Implementation updates include:

- the canonical version datum to `0.18.33`;
- the new `data` collection manifest and library inventories;
- Consent runtime and stdlib manifest records, dependencies, visibility, and
  verification metadata;
- architecture and library-surface documentation for `(data ...)`;
- stdlib documentation explaining the unchanged red-black default and optional
  AVL provider;
- portable-test audit entries and host wiring;
- source and compiled library inventories for all supported hosts.

The final change must pass the focused AVL, Mapping, symbol, reader, evaluator,
manifest, and writer suites, followed by parity, compiled-host, and full
repository verification.

## Future Extensions

- #716 and #721 can fork symbol-table handles from persistent roots and define
  commit/abort policy without replacing the symbol or AVL representation.
- #624 can add the official hash Mapping facade by implementing the common
  provider capabilities without the ordered extension.
- Additional `(data ...)` libraries can follow the namespace policy without
  depending on Consent runtime internals.
- Additional ordered Mapping providers can reuse the same constructor/provider
  seam while leaving the standard red-black default stable.
