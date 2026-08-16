# Portable Compound Datum Heap Implementation Record

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
   zero fresh revisions, zero mutation-hook calls, and one-sidecar map probes.

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
7. Use scoped intrusive ordinal-sidecar marks for owned objects and host
   identity hashing for host objects, so no transition scans heap history or
   mirrors from an earlier call.
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

## Task 8: Close the measured integration blast radius

The owned representation made several pre-existing linearity and ownership
boundaries material in product paths. The final branch retains the completed
fixes because they are covered behavior, not speculative benchmark prototypes:

1. `(agent memory-key)` prepares exact detached keys for arbitrary finite
   cyclic or shared datums by minimizing their deterministic term graph and
   numbering the quotient canonically. Repeated roots share descriptors through
   dynamic preparation sessions and a store-lifetime interner.
2. `(agent memory)` keeps canonical records as the source of truth while
   maintaining rebuildable live-key, per-scope live-order, latest-access, and
   descriptor indexes. Small indexes remain inline up to a fixed limit of 16
   entries and then upgrade permanently to persistent AVL trees.
3. Append-time sidecars detach identity-sensitive key, id, kind, tag, and
   classification projections. `(agent memory-query)` receives only current live
   records, those sidecars, access maxima, and the scalar next-id clock; it does
   not recover equality from borrowed mutable record fields.
4. Single-pattern find uses prepared KMP state over sequential host-string
   traversal. Selection uses one Aho-Corasick-style automaton for all distinct
   text terms, preserving multiplicity without scanning every record once per
   term. Canonical key identity and bounded content fallbacks avoid an all-pairs
   comparison cache.
5. The OpenAI codec validates pair/vector request graphs with an iterative
   active-color traversal, permits shared acyclic graphs, rejects cycles, and
   bounds plain-R7RS compatibility depth at 64. Provider-error URL extraction is
   sequential rather than repeatedly indexing variable-width host strings.
6. The redaction kernel uses one sequential fixed-state scanner and escapes on
   the first exact marker. Traversal, replacement, logs, trust, and policy stay
   in the source facade.
7. Foreign datum import and export reserve at most 64 distinct host identities
   without hash-backed identity maps. Bulk memory-key compatibility sessions
   use the same fixed 64-entry ceiling. These envelopes fail closed before a
   linear identity alist can become a quadratic heap algorithm.
8. Fresh native result, condition, and writeback topology is charged once at
   source-equivalent value-node cost after reconciliation. Reused borrowed
   identities are not charged again; no-bridge fresh host or cross-heap
   compounds require hash-backed identity maps.

## Objective performance verification

The first frozen end-to-end comparison used one local machine and Gambit. `A`
was the unowned `origin/main` implementation at `722e301e7073`; `B` was the
initial owned-heap snapshot, before the source-realization and performance work
described below. The SHA-256 of the complete `scheme/` file digest for that `B`,
both before and after the run sequence, was:

`64e154c7ff89c34c3fe35d1a111616cb2ab26ca0a098d31ac9a571ef9381f021`

Both targets ran the same frozen evaluator workload through the baseline
wrapper. Its transient copy was not retained as a durable repository artifact,
so this table records historical development evidence rather than a current
reproduction recipe. New matched comparisons must use durable Git worktrees and
checked-in programs. The target alternated between baseline and branch in the
sequence
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

### Current implementation and verification

The current implementation keeps the fast source-copy registry, compact source
notes, native host identity tables, bounded compatibility envelopes, and the
final memory, codec, redaction, and native-result work described above. Its
path-sensitive `scheme/` digest is:

`b24f7ca558cc50555b14cacba5031b00666e550d212bb1a915219f14feb9a76d`

It was produced from the repository root with:

```sh
find scheme -type f -print0 |
  sort -z |
  xargs -0 shasum -a 256 |
  shasum -a 256
```

The runtime reports Consent Scheme 0.18.38. Its compiler image has 51 declared
roots, 54 resolved compilation units, 91 embedded or installed source files,
and 19 exact native-registration roots. The selective native inventories remain
54 procedures and 10 constants.

Binary hashes are intentionally not recorded here. The binaries present in the
development checkout predate the final source graph; assigning their hashes to
this digest would create false provenance. The required CI build jobs compiled
and exercised fresh Gambit and Racket products from the current commit. A future
release artifact ledger should record hashes only from the final rebuilt and
published artifacts.

#### Selective native kernels

The final image does not native-register retaining source facades merely to
make a benchmark green. It registers three pure, callback-free, non-retaining
kernels, each with a fail-closed procedure inventory and zero data bindings:

- `(agent memory-query)` has four procedures for find, tag, recent, and
  selection queries. `(agent memory)` retains the sole mutable store,
  persistent indexes, append-time sidecars, interner, and every mutation and
  replacement operation.
- `(agent models openai-codec)` has three procedures for request projection,
  response parsing, and provider-error record projection. `(agent models
  openai)` retains endpoint choice, transport, retry, callbacks, redaction,
  error orchestration, and result publication.
- `(agent redaction-kernel)` has one fixed-spelling scanner. `(agent
  redaction)` retains traversal, policy, replacement, logs, local-only state,
  provider safety, and pass ordering.

The following isolated compiled prototypes are historical candidate evidence.
Each used an unchanged workload and binary except for the named candidate; none
is an additive prediction or a substitute for a final product comparison.

| Isolated compiled prototype | Before | After | Change |
| --- | ---: | ---: | ---: |
| Memory query, eight-case corpus | 1.30s | 0.77s | -0.53s (-40.8%) |
| OpenAI request and response codec | 2.36s | 1.61s | -0.75s (-31.8%) |
| OpenAI provider error, nine cases | 1.71s | 1.55s | -0.16s (-9.4%) |
| OpenAI provider error, expanded | 3.98s | 3.64s | -0.34s (-8.5%) |
| Redaction scanner, exact corpus | 1.47s | 1.25s | -0.22s (-15.0%) |
| Redaction scanner, expanded corpus | 3.77s | 3.18s | -0.59s (-15.6%) |

A generated-source codec was rejected after 0.58s to 0.57s proved to be noise.
An inline-pair prototype produced no product improvement. An environment
identity index recovered only 1.7% to 4.9% in product runs and did not justify
its additional cache-coherence surface.

#### Superseded matched comparisons

An earlier revision of this record called an intermediate matched A/B table
"final." It measured the tree before the memory-key canonicalizer, live indexes,
multi-pattern matcher, bounded graph compatibility, final codec and redaction
algorithms, native-result charging, and CI restoration landed. Its digest,
artifact hashes, per-program timings, and percentage conclusions therefore do
not describe the current implementation and have been removed.

The complete current-code matrix used for this record is
[GitHub Actions run 31663367899](https://github.com/tahoma/consent/actions/runs/31663367899).
Every required check passed. Representative current-commit wall times include:

| Current final-tree CI surface | Wall time |
| --- | ---: |
| Chibi direct evaluator | 447s |
| Guile direct evaluator | 358s |
| Racket-compiled agent shard | 244s |
| Gambit-compiled agent shard | 227s |
| Racket-compiled memory program | 210s |
| Gambit-compiled memory program | 201s |
| Emacs memory query performance shard | 123s |
| Emacs memory-key refinement performance shard | 117s |

These CI values prove final-tree execution and expose current hot paths; they do
not constitute a same-machine baseline comparison. A release-level percentage
claim requires a new balanced baseline/current run over the current checked-in
programs and this exact `scheme/` digest. This record makes no such claim from
the superseded measurements.

#### Final semantic and scaling gates

Focused current-tree direct Gambit runs report:

- `(agent memory)`: 44 cases and 224 assertions;
- `(consent datum)`: 60 cases and 295 assertions;
- `(consent reader)`: 111 cases and 318 assertions; and
- compiler-plan and testing-plan invariants covering 51 roots, 54 units,
  19 native roots, and the 65-program direct/45-program compiled partitions.

The complete CI matrix additionally passes Emacs/portable parity, the five
direct portable hosts including required Chibi, both compiled self-hosts,
readability, SPDX/REUSE, branding, and the deterministic memory scaling shards.
The no-hash poison gate covers the owned reader plus foreign native-result
rejection without invoking the quadratic identity-list adapter.

The interpreted memory tests remain intentionally visible rather than folded
into product timings. On that CI run, the four Emacs memory query scaling
tests took 121.480s, the memory-key refinement proof took 116.408s, and the
bounded source-backed no-hash route took 25.596s. Those tests exercise cold
source realization and deterministic four-corner work envelopes; they do not
raise any production evaluator default.
