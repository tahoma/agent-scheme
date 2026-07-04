# CI Timing Baselines

This is the recorded baseline the timing-regression heuristic in
[Contributing → Continuous Integration](contributing.md#continuous-integration)
compares against. It is a point-in-time sweep of the historical per-PR timing
comments, not a live dashboard; refresh it when the shard layout changes enough
that the numbers below stop describing reality.

## How this was gathered

The per-PR timing comment (`<!-- consent-ci-timing-summary -->`, and its older
`<!-- agent-scheme-ci-timing-summary -->` form) carries a detailed **Test Shard
Timing** table with a `Selector` column. That table is the one element present
in every era, so the sweep parsed it from the final pre-merge comment of every
merged PR that had one — 50 PRs, from #324 (2026-05-25) through #504
(2026-06-08). Per shard it reads `Ran`, `ERT time`, and `Wall time`, splitting
the `/ source metadata X / docstrings Y` suffix off the shard name and keeping
the canonical **`on/full`** combo (the only combo that runs on every per-push
lane, so it is always present to compare).

To reproduce, harvest the timing comments and parse the detailed table:

```sh
gh api repos/<owner>/<repo>/issues/<pr>/comments --paginate \
  --jq '[.[] | select(.body | test("wall|ERT time|ci-timing-summary"; "i")) | .body] | last'
```

## Format eras (read these before comparing across a boundary)

The comment changed shape several times. ERT is comparable across all of them;
the *set of shards* and the project name are not.

| Era | PR range | Portable side | Notes |
| --- | --- | --- | --- |
| A | #324–#355 | single **Chibi** host (`eval` + `rest` shards) | project named `agent-scheme`; no syntax/docstring cross |
| B | #356 | multi-host (Gambit/Racket/Guile/Gauche) replaces Chibi | the host fan-out lands |
| C | #359–#361 | + source-metadata × docstring combo columns | |
| D | #362–#405 | + Gambit-native compiled shard | still `agent-scheme` |
| E | #406–#518 | project renamed to **consent** | current format; shard names gain `Consent Scheme` |
| F | #520–#651 | compiled shards parallel/incremental/cached | build-bound shards' wall time becomes cache-dependent; see the Era F section |
| G | #652–present | stdlib reference corpus split from library/conformance | compare `Emacs library/conformance` and `Emacs stdlib/reference corpus` as separate rows |

The Era A→B boundary (#355→#356) is a hard discontinuity *for the portable
side*: the slow single Chibi host (~70s `eval` + a 152s `rest` outlier) was
replaced by parallel fast hosts. Do not compare a portable-host number across it.
The Emacs shards have their own, separate level shift in this window — see the
observations below; it is driven by two runtime changes (#355, #359), not by the
host fan-out.

## Historical baseline (Era E, PR >= #406, `on/full`, 24 PRs)

ERT seconds unless noted. `Ran` is the per-shard test count (always `1` for a
portable host, which runs its whole suite as one aggregate test — so for hosts
the ERT *is* the signal, with no `Ran`-growth guard to apply).

The Emacs rows below predate the Era G stdlib reference corpus split. Until a
post-split baseline is refreshed, compare Era G library and stdlib-reference
rows against recent merged Era G PR timing comments rather than against the
single historical `Emacs library/conformance` row below.

| Shard / host | Ran (med) | ERT median | ERT min–max | Wall median |
| --- | ---: | ---: | ---: | ---: |
| Emacs core language/runtime | 86 | 55.7s | 37.1–59.6s | 56s |
| Emacs library/conformance | 94 | 53.6s | 50.6–56.2s | 54s |
| Emacs capabilities/policy | 135 | 46.7s | 38.9–50.3s | 48s |
| Emacs tools/docs/integration | ~162 | 56.5s | 43.1–66.2s | 57s |
| Gambit | 1 | 14.3s | 10.4–15.7s | 15s |
| Racket | 1 | 20.0s | 11.8–26.3s | 20s |
| Guile | 1 | 23.5s | 15.1–26.6s | 24s |
| Gauche | 1 | 10.0s | 8.8–10.8s | 10s |
| Racket-compiled Consent Scheme | 1 | 6.6s | 3.8–7.9s | **48s** |
| Gambit-compiled Consent Scheme | 1 | 2.2s | 1.7–2.5s | **185s** |

## Observations

- **Wall time is dominated by recompiles, not tests.** The two build-bound
  portable shards run ~2–7s of tests but their wall time is almost entirely the
  recompile, not the suite. They are the single largest per-push wall cost and
  exactly what #481 trimmed off the per-push lane. Track these by *wall* time;
  their ERT is nearly noise. The **185s** (Gambit-native) and **48s** (compiled)
  recorded above are the Era E sweep values and are now stale: the level rose to
  ~361s / ~151s before #520, and #520 then made the build parallel, incremental,
  and cached so the wall time is cache-dependent. See the **Era F** section
  below.

- **The Emacs shards are the ERT cost center.** Four shards at ~47–57s each
  dominate ERT. They are also where a real test-cost regression would most
  likely hide, so they are the primary `on/full` ERT series to watch.

- **One whole-run noise spike: PR #355.** Every Emacs shard reads ~10× normal on
  that single run (442s / 803s / 367s / 659s) while `Ran` is unchanged. This is
  runner contention on one run, not a code regression — and it is the reason the
  heuristic compares against the **median of several recent merged PRs**, never a
  single run or the historical max.

- **One sustained level shift, from two runtime changes (#355 and #359) — not
  the runner.** Every Emacs shard's floor stepped up ~5–11s in the #355–#359
  window and stayed there, with `Ran` flat. It resolves into two distinct steps
  that bracket two reader/datum-representation PRs:
  - **#355 "attach source metadata to syntax datums"** lifts the parse/fixture
    shards: `library` 47.7s → 52.8s and `capabilities` 40.7s → 46.1s, both first
    cleanly measured at #356 (and `Ran` unchanged).
  - **#359 "add docstring retention modes"** lifts the eval shard: `core` 40.2s
    (at #356) → ~51s (at #359), `Ran` unchanged at 73. The jump appears in
    **every** syntax/docstring combo, including `off/none` (53.5s) — turning the
    features off does **not** recover the old timing, so the cost is structural
    in the datum representation those PRs added, not in the optional metadata
    payload.

  This is an in-process **ERT** (CPU-time) rise, uniform across shards that run
  on isolated GitHub-hosted VMs, so it is categorically *not* runner contention
  (an earlier draft of this doc misattributed it that way). It is a genuine
  latent regression that landed unflagged — exactly the case the
  [regression heuristic](contributing.md#continuous-integration) now exists to
  catch: #359's core step is +27% and +11s at constant `Ran`, well over the
  ≥20%-and-≥3s threshold. It is now priced into the Era E baseline above.

- **`tools/docs/integration` growth is test-count growth, not regression.** Its
  `Ran` climbed 72 → 179 (≈2.5×) and ERT 30s → 60s over the window, tracking
  steadily added tests. This is exactly the case the heuristic's "flag only when
  `Ran` is unchanged" guard is meant to *not* fire on. `core` grew similarly
  (61 → 86). `library` and `capabilities` `Ran` are nearly flat, so their rise
  is almost entirely the #356 infra step.

- **Portable host ERT is stable and cheap.** Gambit/Gauche sit ~10–15s,
  Racket/Guile ~20–25s, with no drift beyond run-to-run noise. A real per-host
  ERT regression would stand out clearly against these tight bands.

## Era F (PR ≥ #520): compiled shards parallel/incremental/cached

The two build-bound shards changed character at #520. Read this before
comparing their **wall** time across the boundary; their ERT is unaffected.

### The level shift this corrects

The Era E table above records the Gambit-compiled shard at **185s** wall and the
Racket-compiled shard at **48s**. Both were stale by #520: the real pre-fix
level had risen to **~361s** (Gambit-native) and **~151s** (Racket-compiled).
The rise had two compounding causes, neither a test-cost regression:

- **The per-push host-runner second link.** Each compiled shard linked a second,
  non-shipped host-execution executable, and each `gsc -exe` / `raco exe`
  recompiled the full generated-C / library stack from scratch — roughly
  doubling the build. #518 removed that second executable (the product now serves
  as its own host runner under `--host-run`).
- **#516/#518-era growth** in the embedded bootstrap source and the set of
  natively compiled internal modules, which enlarged the one remaining build.

### What #520 changed

#520 leaves *what* is compiled and tested untouched and changes only *how fast*
the same work happens:

- **Gambit** (`tools/compile-portable.sh`): the per-module Scheme→C and C→object
  passes run in a bounded parallel worker pool with per-module logs; the
  generated C is compiled to objects once and the executable is linked from those
  shared objects (`gsc -link` + a final `gsc -exe` over the `.o` set) instead of
  recompiling all generated C at link time; a per-module content-hash incremental
  skip (source + transitive project-import closure + script text + `gsc` version)
  rebuilds only what changed, with `(consent version)` treated as a structurally
  guarded leaf so the every-branch version bump recompiles only the version
  module and relinks; `actions/cache` keeps the `build/compile/gambit` tree warm
  with a `restore-keys` fallback.
- **Racket**: generated collections, the embedded-source module, and the product
  main are written write-if-changed so unchanged sources keep their timestamps;
  `raco make -j` builds bytecode once (before enumeration and before `raco exe`)
  so both reuse it; `actions/cache` keeps `build/compile/racket` (sources and
  their `compiled/` bytecode) warm.
- **Workflow**: `pull_request`-only `cancel-in-progress` retires superseded PR
  runs; pushes to `main`, scheduled runs, and dispatches are never cancelled.

### How to read these shards now

Their wall time is **cache-dependent**, so it is no longer a single level:

- **Warm cache (the common per-push case).** The `restore-keys` fallback restores
  the previous tree and only the changed modules recompile. For a version-only
  bump that is the version module plus the relink on Gambit (and the version
  module plus its bytecode dependents on Racket); the wall is then dominated by
  cache restore and the final link/`raco exe`, not by a full recompile.
- **Cold cache (first run on a new branch, or after cache eviction).** Falls back
  to a full build — parallelized on Gambit, single-`raco exe` on Racket — so it
  is much higher than a warm run and is expected, not a regression.

When checking these shards for a regression, compare **warm runs against warm
runs**: a single cold-cache miss reading high is normal. Flag a sustained rise in
the *warm* wall time (or a fall in the cache hit rate). The base.c C-compile is
the cold-build long pole on Gambit; a real per-push regression there would show
as the warm floor creeping up across several merged PRs.

Local indicative figures (a 20-core M-series workstation, not the CI runners, so
absolute numbers differ — included only to show the *shape*): Gambit clean
build 159s → 79s; Gambit warm rebuild after a version-only bump ~5s (only the
version module recompiles); Racket warm rebuild recompiles **0** bytecode files.
Settle the post-#520 CI levels by reading the warm-cache wall figures from the
per-PR timing comments once a branch's cache is populated.
