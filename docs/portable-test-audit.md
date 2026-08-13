# Portable Test Coverage Audit

Issue #659 establishes `tests/scheme/` as the canonical test home for
host-neutral behavior. This audit records why ERT coverage remains where it
does; retaining an ERT test does not make it the semantic source of truth.

## Migrated semantic suites

- Reader, evaluator, macro, runtime, standard-library, agent-record, REPL
  contract, and conformance semantics have canonical files in `tests/scheme/`.
- The pure `(agent context)`, `(agent diagnostics)`, `(agent diff)`, `(agent
  network)`, `(agent plan)`, `(agent redaction)`, `(agent session store)`,
  `(agent task)`, and `(agent vcs)` datum/parser suites run under SRFI 64 across
  the direct portable host matrix. Their ERT counterparts remain only to
  preserve Emacs-bootstrap import, primitive-adapter, audit, session, buffer,
  process, and policy coverage.
- The portable OpenAI-compatible model suite injects a deterministic retrieval
  adapter and owns retry, HTTP failure, decode failure, bounded-detail, and
  credential/prompt-redaction semantics without routing those checks through
  an Emacs transport fake.
- SRFI 180 valid and invalid JSONTestSuite fixtures, including
  `y_foundationdb_status.json`, explicit exclusions, implementation-defined
  classifications, JSON Lines, and JSON Text Sequences are canonical in
  `tests/scheme/stdlib-json-reference-test.scm`.
- Shared R7RS and REPL corpora are exercised by both portable and Emacs hosts.
- `(consent numeric)` exact limbs, rational arithmetic, binary64 fallback, and
  conversion semantics are canonical in
  `tests/scheme/consent-numeric-test.scm`. The suite exercises the default
  30-bit profile, an alternate 14-bit bootstrap profile, and a 62-bit native
  limb profile at `B - 1`, `B`, `B + 1`, `B^2 - 1`, and `B^2`, plus the
  separate positive and negative fixnum limits, promotion, and demotion.
  Multi-limb division, GCD, square root, rational reduction, radix conversion,
  and uncached binary64-to-host reconstruction keep checked acceleration and
  owned fallback in one cross-host boundary corpus. Reproducible generated
  differential tests add adversarial limb shapes, exact/rational host oracles,
  finite binary64 significand/exponent patterns, software-versus-host IEEE
  arithmetic, and direct dispatcher coverage. Structural ERT checks forbid
  text conversion in binary64 host seams and repeated mixed-symbol resolution
  in combination dispatch, while a shared compiled hot-loop fixture exercises
  both paths behaviorally.
- Portable reader numeric grammar coverage is canonical in
  `tests/scheme/consent-reader-test.scm`: valid radix/exactness orderings,
  decimal exponent and implicit-imaginary forms, numeric-like peculiar
  identifiers, and malformed numeric rejection all run through the native
  Scheme test plan. Representative cases remain in the shared R7RS corpus for
  Emacs/portable reader parity.
- `(data avl-tree)` semantics are canonical in
  `tests/scheme/data-avl-tree-test.scm`; its public smoke corpus also runs on
  compiled hosts. The direct-host suite alone imports the internal invariant
  checker so opaque nodes remain outside the user API. Deterministic permuted
  insertion and deletion stress checks every intermediate root, while focused
  cases cover persistence, equivalent keys, rotations, range boundaries,
  traversal, conversion, handlers, and contracts.
- `(data transient-map)` mutable-overlay, materialization, deletion, reset,
  collision, and resize semantics are canonical in
  `tests/scheme/data-transient-map-test.scm`. AVL and alist adapters establish
  backend independence; a model-driven history additionally covers cached
  reads, tombstones, stored false values, pending-count transitions,
  collisions, resizing, idempotent materialization, and callback contracts.
- `(data mapping avl)` constructor, provider-preservation, and mixed-provider
  semantics are canonical in the compact and upstream-derived Mapping suites.
- `(consent symbol)` owned-record, interning, persistent-root, and isolated
  handle semantics are canonical in `tests/scheme/consent-symbol-test.scm`.
  Its adversarial cases cover mutable-name ownership, returned-name isolation,
  exact hash collisions, repeated lookup across resizes, root replacement with
  pending entries, branch identity, and argument contracts. Shared R7RS
  fixtures additionally exercise reader/conversion/macro identity and
  escaped-symbol writer round trips on both bootstraps. ERT retains the Emacs
  adapter checks for explicit hash-table handle plumbing, input-name ownership,
  isolated handles, bulk identity, recovery, and incremental reads.
- `(consent datum)` heap identity, metadata, mutation gateway, graph
  import/export, cross-heap topology, and borrowed-host call bridge are
  canonical in `tests/scheme/consent-datum-test.scm`. Shared R7RS fixtures
  exercise pair/vector aliases, string/bytevector mutation, cyclic equality,
  and writer labeling through both evaluator bootstraps. Reader tests retain
  multi-element pair and vector datum-label cycles in both direct and
  self-hosted lanes.
- `(consent runtime-storage)` bounded growth, allocation counters, clearing,
  arena ownership, reset/release, exception cleanup, continuation re-entry, and
  pre-reserved collector workloads are canonical in
  `tests/scheme/consent-runtime-storage-test.scm`. The portable plan runs the
  same library on direct and compiled hosts, while ERT exercises its Emacs
  source-library route.
- `(consent character)` owned-record construction, the complete Unicode scalar
  boundary, host/native adapter contracts, and NUL-through-maximum nested datum
  round trips are canonical in `tests/scheme/consent-character-test.scm`.
  Exhaustive finite bootstrap classification, digit, whitespace, mapping, and
  comparison tables live in the shared fixture corpus so they execute through
  both evaluator bootstraps; direct portable and ERT reader suites retain their
  respective reader-object and bootstrap-diagnostic boundaries.

## Actual case ownership

`tests/scheme/ert-portable-parity-map.scm` is the canonical Scheme-data
inventory for every checked-in ERT file. The repository audit rejects an
unmapped ERT file, a missing portable program, or a portable program absent
from the Scheme-native test plan. Surfaces that are wholly repository policy,
build orchestration, or Emacs host adapters carry an explicit boundary reason.

The 15 mixed source-backed surfaces are stricter: every ERT case is partitioned
between a named portable case/check marker and a concrete Emacs-only boundary.
The audit rejects duplicates, omissions, and portable markers that no longer
exist. Shared-corpus and dual-core surfaces retain their distinct ownership
forms because their parity unit is respectively the common fixture corpus or
the separately exercised runtime implementation, rather than a copied ERT case
body.

Raw ERT-test and Scheme-assertion totals are deliberately not used as a parity
claim: one ERT case may contain many assertions, while one registered portable
case retains each SRFI 64 result. The ownership map and executable marker checks
answer the meaningful question: which environment owns each semantic case, and
what portable test makes a host-neutral claim executable?

## Justified ERT coverage

- SRFI 180 reference semantics have no ERT copy. The portable corpus owns valid,
  invalid, classified-exclusion, implementation-defined, JSON Lines, and JSON
  Text Sequences coverage and runs through both compiled self-hosts. Emacs keeps
  generic file-capability adapter coverage without using JSON as the workload.
- Buffer, window, overlay, interactive command, prompt, and Emacs incremental
  REPL tests exercise host-adapter behavior that R7RS Scheme cannot observe.
- Process launch, executable discovery, compilation, installation, CI YAML,
  repository lint, and packaging tests exercise the build/host boundary.
- Emacs capability adapters retain ERT checks for live buffers, filesystem and
  process callbacks, persistence, approval UI, and native Emacs object
  translation. Portable tests own their Scheme-readable records and pure logic.
- `(testing plan)` and `(testing runner)` own the Scheme-readable program plan,
  shard selection, assertion results, and exit semantics.
  `tools/run-portable-tests.sh` remains responsible only for tool discovery,
  invoking each selected `tests/scheme/` program, and attaching host/file names
  to failures.

The audit groups the remaining ERT files by the boundary they exercise:

| ERT surface | Canonical portable coverage or reason retained |
| --- | --- |
| `consent-base`, `consent-budget`, `consent-eval`, `consent-macro`, `consent-reader`, `consent-result`, and `consent-runtime` | `consent-reader-test.scm`, `consent-eval-test.scm`, shared fixtures, and parity tests own language semantics; ERT retains the Emacs evaluator and bootstrap realization. |
| `consent-agent-*`, `consent-context`, `consent-diagnostics`, `consent-diff`, `consent-memory`, `consent-models`, `consent-network`, `consent-plan`, `consent-redaction`, `consent-session`, `consent-task`, `consent-transcript`, and `consent-vcs` | Source-backed datum and pure-library behavior is covered by the corresponding portable agent suites; the exact mixed-surface map identifies the remaining primitive adapters, audit effects, persistence, live buffers, processes, and policy gates case by case. |
| `consent-capability`, `consent-approval`, `consent-job`, `consent-repl-comint`, and `consent-repl-stream` | These tests exercise dual-core capability enforcement or Emacs buffers, processes, callbacks, prompts, grants, and interactive session state; portable runtime and REPL tests own the shared language/interaction contracts. |
| `consent-library`, `consent-compile-*`, `consent-ci`, `consent-smoke`, and module/ownership tests | These validate manifest discovery from the Emacs bootstrap, compilation, packaging, repository layout, CI configuration, and executable discovery rather than host-neutral library semantics. |
| `*-doc-test`, Scheme documentation lint, and branding/style tests | These inspect checked-in documentation and source conventions using repository tooling; they are build-policy tests, not Scheme runtime semantics. |

Portable files predating this issue may still contain local failure counters.
That is a Scheme-harness consistency concern rather than missing portable
semantic coverage. New and migrated semantic suites use SRFI 64 plus the
`(testing registry)` and `(testing runner)` path; #883 tracks conversion of those
older portable files without moving their assertions back through ERT.

New ERT tests must update the Scheme ownership map. A mixed source-backed case
must either name its portable case/check marker or state the concrete Emacs-only
boundary; a new ERT file cannot enter the suite unclassified.

## ERT capability comparison

The portable stack now provides the semantic assertions and the complete batch
runner workflow that ERT supplied. Remaining gaps are native stack rendering,
an interactive result browser, and conversion of older portable files whose
checks still execute through file-local counters instead of registered cases.

| Capability | Portable facility | Status versus ERT |
| --- | --- | --- |
| truth, equality, approximate, and error assertions | SRFI 64 `(stdlib testing)` | parity |
| named groups and cleanup | SRFI 64 `test-group` and `test-group-with-cleanup` | parity |
| skip and expected failure | SRFI 64 runner directives | parity |
| generated/property assertions | SRFI 252 plus SRFI 158/194 generators | exceeds ERT core |
| table/comprehension assertions | SRFI 78 plus SRFI 42 | exceeds ERT core |
| actual/expected values and arbitrary result properties | SRFI 64 result alists | parity |
| deterministic batch failure and summary receipts | `(testing harness)` and `(testing runner)` over SRFI 64 | parity; runner exits distinguish test and configuration failures |
| named cases, selectors, tags, listing, and selective reruns | `(testing registry)` plus `(testing runner)` | parity for registered suites; selectors are composable Scheme data |
| multi-program plans and shard selection | `(testing plan)` plus `(testing runner)` | exceeds ERT core; project plans are validated Scheme data |
| source locations and per-test timing | registry case metadata and runner jiffy clock | parity, with opt-in explicit portable source metadata |
| assertion details and arbitrary result properties | assertion alists retained in each case report | parity |
| persisted failed-test inspection and rerun | `--report` and `--rerun-failed` | batch parity through Scheme-readable reports |
| backtraces and host diagnostics | rendered portable conditions plus registry diagnostic hook | partial; native stack capture remains a host adapter responsibility |
| interactive result browser | reports contain the required data, but no portable terminal UI | not yet parity |

`(testing harness)` is a test-only orchestration extension, not another
assertion framework. `testing-harness-run` supplies the repeated SRFI 64 lifecycle,
machine-readable summary datum, and nonzero host exit on unexpected failure or
success. `testing-harness-check` adapts silent SRFI 78 checks into one named SRFI
64 result. Test bodies continue to use the SRFI forms directly. The library
lives in the manifested `scheme/testing/` namespace so it is
available to downstream users. The executable suites and cases under
`tests/scheme/` remain outside runtime manifests. Further libraries in the
testing namespace must be named for the missing test facility they provide;
`(stdlib ...)` remains reserved for the portable standards shelf.

`(testing registry)` carries names, tags, optional source metadata, timing,
status, and host diagnostics without replacing SRFI 64 assertions. R7RS does
not standardize stack capture or an interactive UI, so the registry exposes a
diagnostic hook and Scheme-readable reports that host adapters can render and
augment rather than embedding one host's debugger in the portable layer.

`(testing runner)` turns those facilities into a complete batch entry point.
It parses portable selector data, lists cases, installs the clock and diagnostic
adapters, preserves full assertion result alists, writes reports, reruns failed
case names from a prior report, and owns process exit status. The Context,
Diagnostics, Diff, Network, Plan, Redaction, Session Store, Task, and VCS
semantic suites use this path directly; remaining legacy portable files still
need conversion from file-local counters before their individual checks become
registry-visible.

`(testing plan)` supplies the layer above an individual registered suite. It
validates tagged program records and named shard selectors without turning
project test programs into runtime libraries. The checked-in Consent plan is
ordinary Scheme data under `tests/scheme/`; the shell launcher consumes only
the selected path stream needed for host process invocation. Process isolation
is intentional even though R7RS also provides `(scheme load)`. Separate
`live-direct` and `live-compiled` selectors keep nested-evaluator and
self-hosted interaction-context programs explicit instead of hiding that host
execution distinction in ERT. `make test-live-model-portable` invokes those
Scheme-plan shards directly; the aggregate live targets run the Emacs-host
checks beside them, never as their discovery or process-control parent.

The same plan makes compiled self-host coverage auditable rather than an
allowlist hidden in shell orchestration. All 65 ordinary `full` programs carry
exactly one of `compiled` or `self-host-gap`: 44 are compiled and 21 are named
gaps. The compiled selector contains 45 programs because it also includes the
compiled-only runtime manifest smoke program. The current gaps are acceptance
inputs to #120, #346, and #432. Their issue comments name the exact registered
cases or first failing manual checks. As those runtime defects ship, their
programs move into `compiled`; the plan test rejects an unclassified full-suite
program or a program tagged both ways.

The #120 set includes `consent-reader-test.scm`, `consent-numeric-test.scm`,
`consent-numeric-generated-test.scm`, `consent-fixture-test.scm`,
`consent-symbol-test.scm`, and `consent-datum-test.scm`. They directly import
private portable reader, evaluator, numeric, symbol, datum-owner, or dispatcher
APIs whose borrowed-host calls may retain source, options, closures, or
representation-owner records; native registration therefore rejects their
owned compound arguments instead of constructing a durable host mirror.
Compiled Scheme-visible reading remains exercised without that ABI: the agent
reliability and native CLI daemon adapter programs read structured fixture
files through `(scheme read)`, with 20 and 238 assertions in focused
Racket-compiled runs. The compiled-only manifest smoke additionally reads a
labelled cycle through `(scheme read)`, checks self-identity and mutation, and
verifies its canonical `write-shared` representation. Compiled standard-library
random and property programs exercise public numeric semantics without crossing
the private numeric dispatcher boundary.

The plan also partitions the 65 direct programs exactly once across seven
behavior surfaces (`runtime`, `evaluator`, `integration`, `agent`, `library`,
`random`, and `property`) and the 45 compiled programs exactly once across six
parallel counterparts. CI uses those names as first-class Guile, Gauche,
Gambit-compiled, and Racket-compiled jobs; aggregate local and exhaustive-lane
runs launch the same selectors through `tools/run-portable-test-set.sh` and
retain one log per group. The CI timing parser additionally records each
program's wall time, so a new within-group outlier can be moved or split using
measured evidence rather than host-wide totals.
