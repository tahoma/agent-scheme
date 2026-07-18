# Portable Symbol Identity and Interning Implementation Plan

> Execute this plan test-first and stop if a failing test does not demonstrate
> the behavior named by its task. Keep commits coherent and preserve the
> existing red-black Mapping implementation as the standard default.

**Goal:** Make the portable runtime own symbol identity through a
checkpoint-visible intern table backed by a public persistent AVL tree, and
offer that tree through an optional AVL-backed SRFI 146 Mapping provider.

**Architecture:** `(data avl-tree)` owns a dependency-light persistent ordered
map. `(stdlib mapping)` gains an internal ordered-provider seam while retaining
the existing red-black provider and standard aliases. `(data mapping avl)` adds
AVL-selecting constructors for ordinary Mapping objects. `(consent symbol)`
owns portable symbol records and symbol-table handles, while the portable and
Emacs reader/evaluator boundaries carry an explicit table through evaluation
state.

**Implementation style:** Portable R7RS-small Scheme, immutable AVL nodes,
SRFI 128 comparators at the Mapping facade, shared Scheme test programs, ERT
adapter coverage, and manifest-owned discovery.

**Design reference:**
`docs/portable-symbol-identity-design.md`

**Initial AVL API:**

- `(make-avl-tree less?)`, `avl-tree?`, `avl-tree-valid?`,
  `avl-tree-ordering`, `avl-tree-empty?`, and `avl-tree-size`;
- `avl-tree-contains?`, `avl-tree-ref`, `avl-tree-ref/key`, and
  `avl-tree-ref/default`, with the `avl-tree-ref` optional failure/success
  protocol matching `mapping-ref` and stored-key lookup accepting required
  failure/success handlers;
- `avl-tree-adjoin`, `avl-tree-set`, `avl-tree-replace`, and
  `avl-tree-delete`, where adjoin and replace leave the tree unchanged when
  their respective absent/present precondition is not met;
- `avl-tree-for-each`, `avl-tree-fold`, and `avl-tree-fold/reverse`;
- `avl-tree-min`, `avl-tree-max`, `avl-tree-key-predecessor`, and
  `avl-tree-key-successor`, using failure thunks at empty or missing edges;
- `avl-tree-split`, returning the five `<`, `<=`, `=`, `>=`, and `>` trees;
- `avl-tree-catenate` and `avl-tree-map/monotone` for ordered composition;
- `avl-tree->alist` and `alist->avl-tree` for `(key . value)` associations.

Minimum and maximum return key and value as two values. Catenation requires
compatible ordering semantics and retains the left tree's ordering procedure.
No node accessor, balance factor, height, rotation, or mutable operation is
public.

## Task 1: Register the public `data` collection

**Files:**

- Create: `scheme/data/manifest.sld`
- Modify: `scheme/manifest.sld`
- Modify: `scheme/consent/library.sld`
- Modify: `scheme/consent/interpreter.sld`
- Modify: `scheme/consent/eval.sld`
- Modify: `lisp/consent-library.el`
- Modify: `scheme/consent/manifest.sld`
- Modify: `tests/consent-library-test.el`
- Modify: `tests/scheme/consent-eval-test.scm`
- Modify: `tests/scheme/consent-module-boundary-test.scm`
- Modify: `tests/scheme/test-plan.scm`

1. Add failing manifest and source-inventory tests for a `data` collection with
   public source libraries and root-relative paths.
2. Run the focused library tests and confirm the missing collection/spec
   failures.
3. Add the top-level `data` collection index entry and a load-light
   `(data manifest)` containing placeholder-free canonical entries as libraries
   land.
4. Generalize the standard/stdlib source-spec filtering helper so both
   bootstraps can request data-library specs without duplicating manifest
   parsing. Export `consent-data-source-library-specs` through the portable
   facade only where the existing standard and stdlib accessors are exported.
5. Verify direct manifest discovery, ordinary public visibility, missing-file
   diagnostics, and module-boundary tests.
6. Add `data` as a first-class test-plan tag included by the direct and compiled
   library shards; do not classify data libraries as stdlib.
7. Commit as `feat(library): register public data collection`.

## Task 2: Build the persistent AVL lookup and insertion core

**Files:**

- Create: `scheme/data/avl-tree.sld`
- Create: `tests/scheme/data-avl-tree-test.scm`
- Modify: `scheme/data/manifest.sld`
- Modify: `tests/scheme/test-plan.scm`
- Modify: `docs/portable-test-audit.md`

1. Add the new test program to the portable plan with `full`, `direct`,
   `compiled`, `data`, and `registered` coverage tags.
2. Write failing tests for construction, predicate rejection, emptiness,
   constant-time size, absent/present lookup, stored `#f`, containment,
   insertion, replacement, adjoin, and persistence of prior roots.
3. Add targeted insertion sequences that require left, right, left-right, and
   right-left rotations. Export a representation-neutral invariant predicate
   for tests and diagnostics without exposing nodes publicly.
4. Implement opaque tree and node records, cached heights, rotations,
   rebalancing, and allocation-free iterative lookup. The public constructor
   accepts a strict ordering procedure; equivalent keys are those for which
   neither ordering direction holds.
5. Export and document the initial `avl-tree-*` API with metadata conforming to
   `docs/scheme-style.md`.
6. Run the test on a representative portable host, then the portable library
   shard.
7. Commit as `feat(data): add persistent AVL tree core`.

## Task 3: Complete the public AVL ordered-map API

**Files:**

- Modify: `scheme/data/avl-tree.sld`
- Modify: `tests/scheme/data-avl-tree-test.scm`
- Modify: `scheme/data/manifest.sld`

1. Add failing model-based tests for deletion of absent, leaf, one-child,
   two-child, and root entries, including every deletion rebalance shape.
2. Add failing tests for ascending/reverse folds, `for-each`, minimum, maximum,
   predecessor, successor, split, catenate, monotone map, alist conversion, and
   count preservation.
3. Generate deterministic mixed operation sequences and compare results to a
   sorted alist oracle after every operation. Confirm prior roots retain their
   old contents.
4. Implement persistent deletion and the ordered operations without exposing
   representation records. Keep lookup allocation-free and updates limited to
   changed paths plus rotations.
5. Run portable direct and compiled coverage for the AVL program.
6. Commit as `feat(data): complete AVL ordered map operations`.

## Task 4: Introduce the internal ordered-Mapping provider seam

**Files:**

- Create: `scheme/stdlib/mapping/implementation.sld`
- Create: `scheme/stdlib/mapping/rbtree.sld`
- Modify: `scheme/stdlib/mapping.sld`
- Modify: `scheme/stdlib/manifest.sld`
- Modify: `tests/scheme/stdlib-mapping-test.scm`
- Modify: `tests/scheme/stdlib-mapping-conformance-test.scm`
- Modify: `tests/scheme/stdlib-rbtree-test.scm`

1. Add regression tests proving that `(stdlib mapping)`, `(scheme mapping)`,
   `(srfi 146)`, and `(srfi srfi-146)` still construct red-black-backed values
   and retain the complete current export set and behavior.
2. Add provider-preservation tests for mapping set, delete, copy, filter,
   partition, range, split, catenate, union, and monotone map results.
3. Move the shared Mapping record and SRFI 146 algorithms into an internal
   implementation library. The record stores the key comparator, ordered
   provider, and provider-owned root.
4. Define the smallest internal ordered-provider operation bundle required by
   existing Mapping algorithms: empty root, search/edit, ordered folds,
   predecessor/successor, split, catenate, and monotone map. Common operations
   must not assume hashing; ordered operations live in the ordered extension.
5. Adapt the existing `(stdlib rbtree)` procedures to that bundle without
   changing their balancing code. Keep `(stdlib mapping)` as a thin standard
   facade whose constructors select this adapter.
6. For mappings with different providers, use provider-independent folds and
   insertion into the result provider rather than passing foreign roots to an
   optimized same-provider operation.
7. Run the original compact and upstream-derived conformance suites unchanged
   against the default constructors.
8. Commit as `refactor(stdlib): separate Mapping storage providers`.

## Task 5: Add the optional AVL Mapping provider

**Files:**

- Create: `scheme/data/mapping/avl.sld`
- Create: `tests/scheme/data-mapping-avl-test.scm`
- Modify: `scheme/data/manifest.sld`
- Modify: `tests/scheme/test-plan.scm`
- Modify: `tests/scheme/stdlib-mapping-conformance-test.scm`
- Modify: `docs/portable-test-audit.md`

1. Write failing tests that import `(scheme mapping)` and
   `(data mapping avl)` together without identifier collisions. Import
   `(scheme comparator)` separately for comparator constructors.
2. Specify and test `avl-mapping`, `avl-mapping-unfold`, and
   `alist->avl-mapping`. Confirm returned objects satisfy the standard
   `mapping?` predicate and retain AVL storage through derived operations.
3. Implement the AVL ordered-provider adapter using `(data avl-tree)` and the
   ordering predicate of an ordered SRFI 128 comparator.
4. Parameterize the existing SRFI 146 conformance harness over a constructor
   bundle, then run the same corpus for red-black and AVL. Do not copy the
   assertions into a second suite.
5. Add mixed red-black/AVL tests for union, intersection, difference, xor,
   equality, catenate, and result-provider selection.
6. Verify standard aliases still default to red-black and that no AVL-specific
   identifiers leak from them.
7. Commit as `feat(data): add AVL Mapping provider`.

## Task 6: Add the portable owned-symbol library

**Files:**

- Create: `scheme/consent/symbol.sld`
- Create: `tests/scheme/consent-symbol-test.scm`
- Modify: `scheme/consent/manifest.sld`
- Modify: `tests/scheme/test-plan.scm`
- Modify: `docs/portable-test-audit.md`

1. Write failing direct tests for opaque symbol records, immutable names,
   symbol-table handles, repeated interning, isolated handles sharing an old
   persistent root, branch-local insertion, and same-name equality across
   handles.
2. Test that the symbol table exposes a runtime root value without exposing AVL
   nodes, and that installing a new root in one handle leaves a sibling handle
   unchanged. This supplies checkpoint-root coverage without implementing
   checkpoint lifecycle operations.
3. Implement `(consent symbol)` over `(data avl-tree)` with a private record
   constructor, process-default table handle, explicit table construction/root
   accessors for the runtime, interning, predicate, name, and equality helpers.
4. Keep host-symbol conversion out of the public library surface. Any
   bootstrap helper must be private and named as a host adapter.
5. Run the direct and compiled symbol tests.
6. Commit as `feat(runtime): add owned portable symbols`.

## Task 7: Route the portable reader through symbol-table state

**Files:**

- Modify: `scheme/consent/reader.sld`
- Modify: `scheme/consent/runtime.sld`
- Modify: `scheme/consent/interpreter.sld`
- Modify: `scheme/consent/base.sld`
- Modify: `tests/scheme/consent-reader-test.scm`
- Modify: `tests/scheme/consent-symbol-test.scm`
- Modify: `tests/scheme/consent-eval-test.scm`

1. Add failing tests showing that ordinary identifiers, vertical-bar symbols,
   quote-family shorthand heads, repeated reads, incremental reads, recovery
   reads, and evaluated `string->symbol` all return owned symbols from the same
   explicit table.
2. Add a symbol-table field to the portable evaluation context and construct
   the context before reading evaluation source. Pass the table through every
   reader option path used for program input and source libraries.
3. Preserve a documented bootstrap mode for reading implementation library
   declarations before the owned symbol library is installed. Normalize those
   bootstrap identifiers at the boundary and prevent them from escaping as
   user datums.
4. Replace user-datum calls to host `string->symbol`, `symbol?`, and
   `symbol->string` with `(consent symbol)` operations. Keep explicitly renamed
   host procedures only for private bootstrap metadata where unavoidable.
   Do not rename or redefine the standard `(scheme base)` bindings inside
   shared libraries; name every mixed-symbol operation at its boundary call
   site.
5. Route `string->symbol` through the context table after charging the existing
   budget once per evaluated call. Reader-created symbols remain charged to
   reader/value limits rather than that evaluation counter.
6. Run reader, evaluator, symbol, and budget-focused portable tests.
7. Commit as `feat(reader): intern portable identifiers in context`.

## Task 8: Migrate portable equality, bindings, macros, and writing

**Files:**

- Modify: `scheme/consent/interpreter.sld`
- Modify: `scheme/consent/runtime.sld`
- Modify: `scheme/consent/macro.sld`
- Modify: `scheme/consent/library.sld`
- Modify: `scheme/consent/reader.sld`
- Modify: `tests/scheme/consent-eval-test.scm`
- Modify: `tests/scheme/consent-reader-test.scm`
- Modify: shared parity fixtures selected after inspecting current coverage

1. Add failing tests for `symbol?`, `symbol->string`, `symbol=?`, `eq?`,
   `eqv?`, and `equal?`, including same-name symbols from isolated roots and
   rejection of strings or bootstrap host symbols.
2. Add failing macro literal, syntax-introduction, feature identifier, library
   import/export, reflection, and writer/read round-trip cases that would fail
   if host identity were consulted.
3. Change equality primitives to use owned record identity with the approved
   name fallback. Make `equal?` reach the same symbol rule through `eqv?`.
4. Normalize binding, library, export, primitive dispatch, feature, and
   reflection keys to symbol-name strings plus existing syntax-context
   metadata. Remove `eq?`, `memq`, and `assq` assumptions where those keys are
   user-visible symbols.
   Shared source libraries must retain their ordinary `(scheme base)` bindings;
   borrowed-host native execution uses explicit internal boundary operations
   and installs the evaluation context's table around native calls that can
   construct symbols.
5. Update the writer to recognize owned symbols and feed their names through
   existing R7RS identifier escaping without converting to host symbols.
6. Run portable macro, library, reader/writer, evaluator, reflection, and
   conformance shards.
7. Commit as `feat(runtime): own symbol equality and binding keys`.

## Task 9: Align the Emacs bootstrap and explicit table plumbing

**Files:**

- Modify: `lisp/consent-reader.el`
- Modify: `lisp/consent-runtime.el`
- Modify: `lisp/consent-eval.el`
- Modify: `lisp/consent-interpreter.el`
- Modify: `lisp/consent-library.el`
- Modify: affected private host adapters found by the symbol-boundary audit
- Modify: `tests/consent-reader-test.el`
- Modify: `tests/consent-runtime-test.el`
- Modify: `tests/consent-eval-test.el`
- Modify: `tests/consent-library-test.el`

1. Add failing ERT tests for explicit symbol-table handles, context-before-read
   plumbing, inherited-root identity, isolated insertion, and the unchanged
   process-default behavior.
2. Refactor the existing Emacs `consent-symbol` intern table into an explicit
   handle carried by `consent--eval-context`; keep the current hash-backed host
   adapter rather than duplicating the portable AVL implementation in Emacs
   Lisp.
3. Pass the handle through all Emacs reader entry points used by evaluation,
   recovery, source libraries, and interaction input. Preserve direct public
   reader calls by defaulting to the process table.
4. Audit conversions from `consent-symbol` to Emacs symbols. Keep only named
   private adapters at genuine dispatch or host-integration boundaries; use
   strings for binding and library keys.
5. Confirm the existing interning budget, receipts, writer behavior, and public
   reader API remain compatible.
6. Run focused Emacs core, library-runtime, stdlib, and integration suites.
7. Commit as `refactor(runtime): carry explicit symbol tables`.

## Task 10: Add shared parity and checkpoint-root fixtures

**Files:**

- Modify: the existing shared parity fixture corpus and its expected records
- Modify: `tests/consent-parity-test.el`
- Modify: `tests/scheme/consent-symbol-test.scm`
- Modify: `docs/portable-test-audit.md`

1. Add shared cases for reader/`string->symbol` identity, isolated-root
   same-name equivalence, quote heads, macro-introduced identifiers, library
   lookup, symbol writer output, and interning-budget receipts.
2. Add root-level checkpoint simulations: create sibling table handles from one
   persistent root, insert in one sibling, verify the other does not observe the
   new name, and verify inherited symbols remain identical/equivalent.
3. Explicitly document that actual checkpoint fork, commit, resume, and abort
   orchestration remains in #716/#721.
4. Run `make test-parity` and the representative portable and Emacs shards.
5. Commit as `test(runtime): cover owned symbol identity parity`.

## Task 11: Finish manifests, documentation, versioning, and issue metadata

**Files:**

- Modify: `scheme/consent/version.sld`
- Modify: `scheme/manifest.sld`
- Modify: `scheme/data/manifest.sld`
- Modify: `scheme/consent/manifest.sld`
- Modify: `scheme/stdlib/manifest.sld`
- Modify: `docs/architecture.md`
- Modify: `docs/library-surface.md`
- Modify: `docs/stdlib.md`
- Modify: `docs/portable-test-audit.md`
- Modify: other source/compiled inventories identified by manifest tests
- Possibly modify: `docs/release-notes.md` and roadmap issue #53 if the standing
  completed-chunk check finds a fully shipped earlier chunk

1. Add failing reflection/manifest assertions for visibility, dependencies,
   exports, provenance, source paths, tests, and compiled-host availability of
   `(data avl-tree)`, `(data mapping avl)`, and `(consent symbol)`.
2. Complete all manifest records and source/compiled inventories. Mark data
   libraries public, symbol ownership internal, and Mapping implementation
   helpers internal. Preserve standard Mapping aliases and their inherited API.
3. Document the `(data ...)` admission policy, AVL persistence/ordering
   contract, AVL Mapping usage, owned symbol boundary, checkpoint-visible root,
   and private host-adapter rule.
4. Set `(consent-version 0 18 33)`.
5. Check issue #53 for any fully shipped earlier chunk that still needs
   retirement, and update release notes/roadmap in the same branch if required.
6. Run documentation checks and manifest/reflection tests.
7. Commit as `docs(architecture): document owned symbol storage` or fold these
   files into the final feature commit when that produces the more coherent
   history.

## Task 12: Complete verification and delivery

1. Run focused tests after each task; do not defer red/green feedback to the
   aggregate gate.
2. Run formatting and static checks:

   ```sh
   git diff --check
   make lint-portable
   make lint-elisp
   make lint-branding
   make lint-line-length
   ```

3. Run representative semantic gates:

   ```sh
   make test-portable-racket
   make test-emacs-core
   make test-emacs-library-runtime
   make test-emacs-library-stdlib-core
   make test-emacs-library-stdlib-manifest
   make test-parity
   ```

4. Run compiled and alternate-host gates:

   ```sh
   make test-portable-compiled
   make test-portable-gambit-native
   make test-portable-guile
   make test-portable-gauche
   ```

5. Run the full repository gate:

   ```sh
   make test
   ```

6. Review the complete diff for host-symbol leakage, public API consistency,
   licensing/SPDX headers, unrelated changes, and version/manifest completeness.
7. Push the issue branch, open a PR targeting `main` with `Refs: #346`, and
   describe the provider refactor, checkpoint-root boundary, verification, and
   deferred checkpoint/hash work.
8. Watch every PR check to completion. After green CI, compare the timing
   summary with recent merged PRs and report any meaningful regression.
