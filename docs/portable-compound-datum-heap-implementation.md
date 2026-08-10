# Portable Compound Datum Heap Implementation Plan

> Keep Scheme-visible compound semantics in `(consent datum)`. Treat every
> host container outside the parser, evaluator control domain, or explicit ABI
> adapter as a boundary defect.

**Goal:** Make the portable runtime own compound identity, mutation, cycles,
and sharing while retaining one narrow borrowed-host graph bridge.

**Architecture:** `(consent datum)` owns opaque heap objects and private
storage. Evaluation contexts carry a heap. Heap-taking readers construct
compound values directly; other evaluator publication paths import complete
graphs, and frontend syntax paths project private copies.
Writers and equality operate on owned identity. A native transition borrows
host mirrors only for one outer call and writes mutations back before dropping
that call's identity registry.

**Design reference:**
`docs/portable-compound-datum-heap-design.md`

## Task 1: Add the owned heap library

**Files:**

- Create: `scheme/consent/datum.sld`
- Create: `tests/scheme/consent-datum-test.scm`
- Modify: `scheme/consent/manifest.sld`
- Modify: `scheme/consent/compiler-manifest.sld`
- Modify: `tests/scheme/test-plan.scm`

1. Define opaque heap and compound records with explicit heap/object identity,
   kind, generation, owner, revision, mutability, and traversal metadata.
2. Add typed pair, string, vector, and bytevector constructors, predicates,
   accessors, and setters without exposing private storage.
3. Route every setter through one observer gateway and keep construction-time
   initialization out of the mutation history.
4. Add memoized import and export that preserve mixed pair/vector cycles,
   string/bytevector aliases, and cross-heap topology.
5. Register the owner before reader/runtime in compiler and source manifests.
6. Test identity, metadata, mutation events, cycles, sharing, cross-heap copy,
   and the absence of raw host containers on direct hosts.

## Task 2: Publish owned reader values

**Files:**

- Modify: `scheme/consent/reader.sld`
- Modify: `tests/scheme/consent-reader-test.scm`
- Modify: `docs/development.md`

1. Keep legacy parser construction values private and explicitly document its
   syntax-only entry points.
2. Add heap-first owned reader entry points for complete and incremental reads.
3. Give owned entry points a one-shot exact-shell construction capability;
   fill pair/string/vector/bytevector storage directly, resolve datum labels
   inside the scope, seal, and validate the published graph afterward.
4. Prepare decoded characters and the line index once for repeated incremental
   reads; retain one current snapshot on a textual input port and replace it
   when the source changes.
5. Convert writer, validator, bounded renderer, and source metadata traversal
   to mixed private-syntax/owned accessors during bootstrap. Count only host
   keys retained by a context table in its persistent source-copy ledger;
   owned provenance follows object reachability and has no portable decrement
   hook.
6. Validate ordinary parser-produced, unlabelled private syntax with one
   iterative host-tree pass. Retain the general graph validator for labelled
   syntax, recovery, active metadata sinks, owned datums, and arbitrary public
   inputs.
7. Restore portable and self-hosted assertions for multi-element pair and
   vector datum-label cycles. Poison the host identity-map adapter and prove
   complete plus incremental owned reads still have exact linear allocations,
   zero fresh revisions, zero mutation-hook calls, and one-header map probes.

## Task 3: Carry the heap through runtime state

**Files:**

- Modify: `scheme/consent/runtime.sld`
- Modify: `scheme/consent/interpreter.sld`
- Modify: `scheme/consent/result.sld`

1. Allocate a fresh datum heap in every evaluation context and expose it to
   reader options, allocation charging, and runtime import.
2. Reuse the heap in a persistent interaction context across REPL submissions.
   Reusable public environments retain and reselect the same heap across
   separate evaluation calls.
3. Make quote, quasiquote, literals, rest arguments, constructors, reads,
   errors, result datums, and host-effect results publish owned compounds.
4. Keep parser forms, evaluator frames, environments, manifests, and trampoline
   control lists in the private syntax/host domain.
5. Project owned syntax explicitly before macro expansion, library resolution,
   nested evaluation, and private metadata parsing.
6. Preserve already-owned result identities when stripping identifier wrappers
   or attaching source metadata.
7. Back mutable lexical cells with private heap slot objects and route `set!`,
   recursive-definition initialization, and generated record-binding updates
   through the same mutation observer.

## Task 4: Route compound primitives through the owner

**Files:**

- Modify: `scheme/consent/interpreter.sld`
- Modify: `tests/scheme/consent-eval-test.scm`

1. Replace public pair, list, string, vector, and bytevector primitive storage
   operations with `(consent datum)` accessors and mutation calls.
2. Copy private evaluator argument spines before publishing variadic rest
   bindings or `list` results.
3. Snapshot sources before overlapping `string-copy!`, `vector-copy!`, and
   `bytevector-copy!` mutations.
4. Implement representative compound identity and cycle-safe structural
   equality while leaving the systematic equivalence-family cleanup to #348.
5. Build record field vectors without construction-time mutation events and
   route generated record setters through the owned vector gateway.
6. Make shallow boundary contracts recognize owned compound types.

## Task 5: Bound the borrowed-host call graph

**Files:**

- Modify: `scheme/consent/library.sld`
- Modify: `scheme/consent/interpreter.sld`
- Modify: `tests/scheme/consent-datum-test.scm`
- Modify: `tests/scheme/consent-eval-test.scm`

1. Create one bidirectional graph bridge for each outer native call rather
   than retaining a mirror registry in the datum heap.
2. Share that call-scoped identity registry across arguments, results, and
   raised conditions, then drop it when the outer call unwinds.
3. Reuse an original owned identity when a native result is a current argument
   or subobject, and write host-side mutations back through the heap gateway
   once before the scope ends.
4. Preserve native cycles, shared results, procedures, scalar owners, and
   context-owned provenance for fresh results, including arbitrary compound
   values raised as conditions. Do not attach provenance to borrowed mirrors
   or context-free host projections.
5. Permit callbacks and re-entrant native calls only for scalars; fail closed
   if a nested transition would add or coexist with a compound borrow.
6. Keep retaining or higher-order libraries on their canonical portable source
   realization so neither raw mirrors nor callback shims escape the call.
7. Use scoped intrusive one-header marks for owned objects and host identity
   hashing for host objects, so no transition scans heap history or mirrors
   from an earlier call.
8. Convert a raised argument or subobject while the bridge is active so its
   owned identity survives exception handling; do the same for host
   error-object irritants before the bridge unwinds.
9. Keep `(consent datum)` itself on the preserved owner path when it is linked
   directly into a native Consent realization.
10. Enforce the per-binding borrow policy inside that same graph-discovery
    walk, before a mirror or callback shim is allocated. Do not pre-scan an
    argument graph merely to decide whether the conversion walk may begin.

## Task 6: Add shared behavioral fixtures

**Files:**

- Modify: `fixtures/r7rs/conformance-cases.scm`

1. Add reusable pair and vector alias-mutation cases.
2. Add string and bytevector shared-referent mutation cases.
3. Add mutated pair and vector cycle equality cases.
4. Add `write` and `write-shared` cases after local alias mutation.
5. Exercise the corpus through both portable and Emacs fixture consumers.
6. Describe local alias behavior precisely and keep session-fork isolation
   deferred to #721.

## Task 7: Document and verify the boundary

**Files:**

- Modify: `docs/architecture.md`
- Modify: `docs/multi-host-bootstrap.md`
- Modify: `scheme/consent/version.sld`

1. Document owned identity, private accelerators, syntax/value conversion,
   native graph bridging, and the checkpoint mutation seam.
2. State explicitly that direct storage does not yet provide branch-local
   copy-on-write or complete session-fork isolation; link #721.
3. Bump the roadmap-derived runtime version to 0.18.38.
4. Run focused datum, reader, evaluator, result, library, fixture, and Emacs
   tests on representative hosts.
5. Run `tools/check-owned-reader-no-host-identity.sh` under Racket, Gambit, and
   Guile. Its forced plain-R7RS overlay poisons host identity-map operations,
   checks exact complete and prepared-incremental allocation scaling, and then
   unpoisons the alist to verify legacy private-syntax correctness.
6. Run direct parity, both self-hosted compiled lanes, readability/lint gates,
   and the full test suite before publication.

## Objective performance verification

The first frozen end-to-end comparison used one local machine and Gambit. `A`
was the unowned `origin/main` implementation at `722e301e7073`; `B` was the
initial owned-heap snapshot, before the source-realization follow-up described
below. The SHA-256 of the complete `scheme/` file digest for that `B`, both
before and after the run sequence, was:

`64e154c7ff89c34c3fe35d1a111616cb2ab26ca0a098d31ac9a571ef9381f021`

Both targets ran the same frozen evaluator test file, whose SHA-256 was:

`c9431a67aabd123cce5d93788019006c58f56fdd2f30dd4c40fcb71b085d8c8c`

The command template used the baseline wrapper for both targets:

```sh
BASE=/private/tmp/consent-347-base-bench
BRANCH=/Users/tahoma/src/consent
COMMON=/private/tmp/consent-347-ab-common.TXho9H
PROGRAM="$COMMON/consent-eval-common-test.scm"
RUNNER="$BASE/tools/run-portable-tests.sh"
/usr/bin/time -p -l -o "$OUT/$LABEL.time" \
  env CONSENT_GAMBIT=/opt/homebrew/bin/gsi \
  CONSENT_TEST_SOURCE_METADATA=on \
  CONSENT_TEST_DOCSTRING_RETENTION=full \
  CONSENT_TEST_MAX_SOURCE_METADATA=250000 \
  CONSENT_PORTABLE_HOST=gambit \
  CONSENT_PORTABLE_PROGRAM="$PROGRAM" \
  CONSENT_TEST_TARGET_ROOT="$TARGET" \
  "$RUNNER" >"$OUT/$LABEL.out" 2>"$OUT/$LABEL.err"
```

`TARGET` alternated between `BASE` and `BRANCH` in the sequence
`A1-B1-A2-B2-A3`. The raw results were:

| Run | Wall seconds | Peak RSS bytes | Cases | Passes |
| --- | -----------: | -------------: | ----: | -----: |
| A1  | 73.37        | 408,666,112    | 392   | 889    |
| B1  | 82.16        | 457,211,904    | 392   | 890    |
| A2  | 73.55        | 408,797,184    | 392   | 889    |
| B2  | 82.17        | 456,589,312    | 392   | 890    |
| A3  | 73.19        | 428,326,912    | 392   | 889    |

Every run reported zero failed cases. The feature path executes one
additional assertion from the byte-identical test file. Averaging the
post-warm-up `A2/A3` and `B1/B2` samples, the owned implementation added
11.99% wall time and 9.16% maximum resident set size to the full evaluator.
That is material linear bookkeeping overhead, not a claim that ownership is
free; it remains an optimization target.

A separate local Gambit graph probe isolated the retired identity-map path.
The checked-in benchmark was
`tools/benchmark-compound-datum-graph.scm`, with SHA-256:

`b576e83ab44ee0ba31b81681e2f8709e6b11a84a78b1523d678cb0691f61306f`

It used the same baseline wrapper and selected each target with
`CONSENT_TEST_TARGET_ROOT`. It converted unchanged symbol lists of 1,024,
2,048, and 4,096 nodes eight times per sample and repeated each sample three
times. Gambit's jiffy frequency was 1,000,000 per second, so these raw samples
are microseconds:

| Nodes | A samples                         | B samples            |
| ----: | --------------------------------- | -------------------- |
| 1,024 | 1,183,031  1,185,516  1,191,850 | 33,002  31,300  31,198 |
| 2,048 | 4,654,440  4,666,156  4,649,720 | 67,820  69,456  66,824 |
| 4,096 | 18,702,430 18,781,552 19,062,669 | 126,283 128,221 128,343 |

Comparing each row's minimum, successive input doublings cost 3.930x and
4.022x under the retired implementation, versus 2.142x and 1.890x under the
initial owned snapshot. The initial owned path was 148.10x faster at 4,096
nodes.

The two results answer different questions. The full evaluator comparison
measures the system-wide cost of adopting owned compounds. The graph probe
shows that the specific near-quadratic identity-map path was eliminated: its
near-4x doubling became near-2x linear scaling. Deterministic probe-count and
allocation tests enforce that structural bound without making wall-clock
timing a correctness gate.

### Final source-realization follow-up

CI on the initial snapshot exposed a separate quadratic source-library copy
registry and material provenance overhead. The final implementation uses a
fast identity map for shared cached syntax, reparses labelled source when only
the compatibility identity alist is available, propagates compact immutable
source notes, and uses Gambit's native identity table directly. Its complete
`scheme/` file digest is:

`39c67311cf4583d930bcf86717b92ff49db8bb2d613b1058a0105350f3f7e06a`

The digest is path-sensitive because the inner records contain relative file
names. It was produced from the repository root with:

```sh
find scheme -type f -print0 |
  sort -z |
  xargs -0 shasum -a 256 |
  shasum -a 256
```

A fresh matched cold import used the same program and Gambit process boundary
for clean `origin/main` and the final worktree. The program imported
`(cli repl-shell)`, timed `cli-repl-records-from-string` on the exact source
`"(import (consent eval))\n"`, and reported five returned records:

```sh
CONSENT_LIBRARY_PATH="$TARGET/scheme" /usr/bin/time -p \
  gsi "-:r7rs,search=$TARGET/scheme" \
  /private/tmp/consent-347-eval-import-final.scm
```

Clean `origin/main` reported 12.312099 internal seconds and 12.72 wall
seconds. The final worktree reported 14.499141 internal seconds and 14.99 wall
seconds: +2.187042 seconds and +17.76% internally, or +2.27 seconds and
+17.85% at the process boundary. Both comparisons are below the repository's
dual regression threshold of at least 20% and at least three seconds. On the
same 523,335-byte interpreter source with metadata disabled, one post-fast-path
frozen-tree sample took 1.518137 seconds. The prior minimum of two
pre-fast-path branch-reader samples was 2.006898 seconds; the minimum of three
clean-main-reader/current-source cross-matrix samples was 1.388773 seconds.

The final string-range owner copies only the requested characters. A profile of
the unchanged compiled model test found 12,043 `substring` calls, representing
90.15% of its owned-string allocations, in repeated fixed-marker scans. The
final redaction implementation performs allocation-free prefix matching at
each candidate. Its three final samples were 2.52s, 2.54s, and 2.54s, versus
1.15s and 1.16s on clean main. The means were 2.533s and 1.155s: +1.378s and
+119.34%, below the dual threshold because the absolute increase is under
three seconds.

A fresh standalone Gambit build started successfully with the host library
search path hidden. Its complete compiled selector passed 45/45 programs in
93.43 wall seconds with its six shards running in parallel. The 14-program
agent shard took 11.88s versus 9.12s on clean main: +2.76s and +30.26%, below
the absolute threshold. The two-program property shard took 38.41s versus
35.05s: +3.36s and +9.59%, below the relative threshold.
