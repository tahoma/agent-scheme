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
| E | #406–present | project renamed to **consent** | current format; shard names gain `Consent Scheme` |

The Era A→B boundary (#355→#356) is a hard discontinuity *for the portable
side*: the slow single Chibi host (~70s `eval` + a 152s `rest` outlier) was
replaced by parallel fast hosts. Do not compare a portable-host number across it.
The Emacs shards have their own, separate level shift in this window — see the
observations below; it is driven by two runtime changes (#355, #359), not by the
host fan-out.

## Current baseline (Era E, PR ≥ #406, `on/full`, 24 PRs)

ERT seconds unless noted. `Ran` is the per-shard test count (always `1` for a
portable host, which runs its whole suite as one aggregate test — so for hosts
the ERT *is* the signal, with no `Ran`-growth guard to apply).

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
| Compiled Consent Scheme | 1 | 6.6s | 3.8–7.9s | **48s** |
| Gambit native Consent Scheme | 1 | 2.2s | 1.7–2.5s | **185s** |

## Observations

- **Wall time is dominated by recompiles, not tests.** The two build-bound
  portable shards run ~2–7s of tests but cost **185s** (Gambit-native) and
  **48s** (compiled) of wall time — the recompile, not the suite. They are the
  single largest per-push wall cost and exactly what #481 trimmed off the
  per-push lane. Track these by *wall* time; their ERT is nearly noise.

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
