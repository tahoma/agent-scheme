# Plan: Roadmap maintenance pass (issue #364) — slim #53, renumber, reconcile

## IMMEDIATE ACTION (this session only)

User chose **"handoff, then fresh session."** This session does **NOT** execute
Parts P/A/B/C/D. It only:
1. Writes this document verbatim to the repo at
   **`docs/roadmap-reconciliation-handoff.md`** on the current branch
   **`claude/roadmap-maint-issue-364`**.
2. Commits it (`Refs: #364`, no `version.sld` change) and pushes.
A fresh session then checks out that branch, reads the handoff, and executes the
remaining work. **Ground truth has been re-verified against real git/GitHub** (see
"Verified current state"); the fresh session must likewise re-verify before each
mutation and must update **#364's body** so it matches requirement 6 (chunk 0.09
migrates fully; #296 moves to a future chunk — NOT staying live in #53).

## Context

Issue **#53** is the living roadmap (flat chunk map + umbrella index + graph
invariants). It has accumulated ~15 chunks of completed work plus drift, and the
versioning convention hardcodes a `0` major. This is one consolidated "roadmap
maintenance" pass, tracked by the already-created issue **#364**, that slims #53,
renumbers chunks, generalizes the version scheme, and reconciles coverage and
labels.

This plan supersedes the chaotic earlier execution attempt. **Verified current
state (ground truth):**
- Tracking issue **#364** (open) already exists with labels
  `surface:design, documentation, risk:low, size:weekend`.
- Branch **`claude/roadmap-maint-issue-364`** exists and **commit `cad51cd`
  ("chore(version): bump runtime version to 0.15.4", Refs #364) is committed and
  pushed** to `origin`. It contains the `version.sld` → `(agent-scheme-version 0
  15 4)` bump plus matching literal updates in
  `tests/agent-scheme-runtime-test.el`, `tests/agent-scheme-reflect-test.el`,
  `tests/scheme/agent-scheme-eval-test.scm`. **Not yet verified by `make test`.**
- Toolchain: only **Gambit** (`gsi`/`gsc`) installed; **Emacs, Racket, Guile,
  Gauche missing**. The ERT test runner needs Emacs, so `make test` cannot run
  until Emacs is installed.
- #53 is untouched; #274 is still open.

### Versioning boundary (confirmed from git)
`scheme/agent-scheme/version.sld` was first introduced at commit `87b5f95`
(issue **#323**, "add introspectable runtime version") at **`0.14.1`**. So
versioning began at the **start of chunk 0.14**. The committed version order for
chunks 0.14 and 0.15 is authoritative (no synthesis needed):
- **0.14:** #323(.1), #42(.2), #227(.4), #45(.5), #300(.6), simple-string-
  docstrings(.7), #302(.8), #303(.9), #344(.10), #341(.11), #47(.12),
  source-metadata(.13), #325(.14), docstring-retention(.15). (Gaps like .3 exist
  in history; release notes record actual committed numbers, not a renumber.)
- **0.15:** #270(.1), #273(.2 — "compile … with Gambit"), #272 was *not*
  separately versioned in git (closed Racket CS slice; assign .3 in release
  notes for completeness), #364(.4, this branch).
This sets the reorder boundary precisely (requirement 7).

### Consolidated requirements (all confirmed across the session)
1. Reconcile #53 vs the live issue set (coverage + taxonomy).
2. Order completed work by merge order (realized in the new release-notes doc).
3. Renumber `Chunk NN` → `Chunk 0.NN`; derive **both** version major and minor
   from the chunk's dotted number (no hardcoded `0`) → future `Chunk 1.x`.
4. **Prune #274** (abandoned Cyclone) and **close it** (`not_planned`).
5. **Migrate completed chunks out of #53 into `docs/release-notes.md`.**
6. **Per-chunk promotion**, with this refinement (stated by the user three
   times): **chunk 09 must NOT stay live.** It migrates fully to history, and the
   missed open item **#296 is rescheduled into a FUTURE chunk** — NOT chunk 0.15
   and NOT a migrated chunk. Place it in a new late future chunk for capability
   hardening follow-ups (or an existing thematically-near future chunk),
   positioned after the current future chunks and before `Chunk N`.
7. **Reorder scope = pre-versioning only.** The `closed_at` merge-order
   reordering applies **only to chunks 0.00–0.13** (the era before versioning
   existed, when ordinals were never committed). From chunk **0.14 onward**,
   ordering is already correct by versioning discipline — use the **committed
   version order from git** (listed above) and do **not** reshuffle by
   `closed_at`. This means release notes for 0.14/0.15 use real committed
   versions; only 0.00–0.13 versions are *synthesized* from reconciled chunking
   + `closed_at`.
8. **Going-forward migration trigger:** migrate a full chunk from live #53 →
   `docs/release-notes.md` when starting the **first issue of the next chunk**
   (not opportunistically mid-chunk). Document this convention in the version /
   contributing docs.

### Resolved decisions
- Promotion is **per-chunk** (a chunk migrates only when all its issues are
  closed) — preserves open issues' `0.<minor>.<ordinal>` positions. With #296
  moved into the future, **chunks 00–14 all migrate** to history; #53 keeps only
  **chunk 0.15** (shipped #270/#272/#273 + the maintenance issue #364), the
  **future chunks 0.16+** (one of which now carries **#296**), and the special
  `Chunk N`.
- Release-notes file = **`docs/release-notes.md`**.
- Maintenance issue #364 = chunk 0.15, ordinal 4 → **version 0.15.4** (after
  #270=.1, #273=.2, #272=.3; #274 removed).
- One consolidated issue/branch/commit for repo files.

---

## Work

### Part P — Preliminaries
- **P1.** Rename the branch `claude/roadmap-maint-issue-361` →
  `claude/roadmap-maint-issue-364` (cosmetic alignment with #364).
- **P2.** Install Emacs (and, if apt has them, Racket/Guile/Gauche) so
  `make test` can run. apt candidates exist for racket/guile-3.0; gauche has no
  candidate. If a host can't be installed, its shard is reported as skipped.
- **P3.** Obtain the ordering inputs:
  - **Chunks 0.00–0.13 (synthesize):** sort each chunk by `closed_at`, ties →
    ascending issue number, then assign synthetic ordinals `0.NN.O`. NOTE:
    `list_issues` does NOT return `closed_at` (verified) — use per-issue
    **`issue_read` (method=get)**, which does. All members are confirmed closed.
  - **Chunks 0.14 & 0.15 (authoritative):** use the committed git version order
    already captured in the "Versioning boundary" section above — do not
    re-derive from `closed_at`.

### Part A — GitHub-only (no commits, no version impact)
- **A1.** Close **#274** as `not_planned`; remove it from #53 everywhere
  (chunk 15 list, umbrella index, Cyclone clauses in invariants).
- **A2.** Rewrite #53 body: remove migrated chunks **00–14** (add a top link to
  `docs/release-notes.md`); keep **chunk 0.15** (shipped #270/#272/#273 + #364)
  and future chunks 0.16+ renumbered to `### Chunk 0.NN:`, with **#296** placed
  in a future chunk (per requirement 6, NOT chunk 0.15); keep
  the special `Chunk N: Roadmap Maintenance`; update Acceptance Criteria (every
  *open* issue is in #53, completed work in release notes) and the `phase:*`/#295
  wording; keep Umbrella Index + Graph Invariants (may cite shipped issues).
- **A3.** Taxonomy label fixes (verify vs siblings): #296 →
  `surface:portable-core+adapter`,`risk:high`,`host:agent-runtime`,`size:weekend`;
  #340 → `surface:portable-core+adapter`,`documentation`,`host:agent-runtime`,
  `size:weekend`; #237 → drop `surface:design`; #254 → drop
  `surface:portable-core+adapter`.
- **A4.** Retire `phase:*` from all ~150 open issues carrying one (remove only
  that label).

### Part B — Repo files (one commit on the renamed branch)
- **B1.** `docs/release-notes.md` (new): per migrated chunk (0.00–0.14), heading
  `## 0.NN <Title>` then issues as `- 0.NN.O — #NNN <title>`. Ordinals for
  0.00–0.13 are synthesized (P3); 0.14 uses committed git versions. Include a
  short header explaining the synthesized-vs-committed distinction and the
  going-forward migration trigger (requirement 8).
- **B2.** Fix the failed convention edits using the **correct** current text
  (now captured):
  - `AGENTS.md` lines 28–33 ("primary version `0` … secondary … tertiary …").
  - `docs/contributing.md` lines 54–61 (the `- primary version: 0` list +
    `chunk 14 → 0.14.1` example).
  - `docs/feature-reflection.md` lines 128–132 (`primary version 0`, secondary
    `15`, tertiary `2`, `0.15.2`).
  Rewrite each so version = `<major>.<minor>.<ordinal>` with `<major>.<minor>`
  from the chunk's dotted number; note future `Chunk 1.x`; datum shape unchanged
  (backwards compatible). (Use exact-string replace with assertions, operating
  via python since the Edit/Read tooling has been flaky.)
- **B3.** `docs/roadmap.md`: rewrite **Runtime Version Mapping** (lines ~49–63,
  `0.<chunk>.<ordinal>` → new rule); drop completed chunk bands (lines ~27–44),
  describe only 0.15+; fix the executables bullet (lines ~139–141: #272 Racket
  CS, #273 Gambit; **no #274**); add a `docs/release-notes.md` pointer; refresh
  closed #294/#295 references.
- **B4.** `version.sld` is already `0 15 4`; keep it and the test-literal updates.
- **B5.** Commit referencing #364; `git push -u origin
  claude/roadmap-maint-issue-364` (retry w/ backoff). No PR unless asked.

### Part C — Verify
Run `make test` (after P2). Confirm the runtime version suite reports `0.15.4`.
Report honestly which shards ran vs skipped (Gambit available; others depend on
P2). If Emacs cannot be installed, fall back to CI verification on push and say
so explicitly.

### Part D — Versioning convention text (the rewrite applied in B2/B3)
Version = `<major>.<minor>.<ordinal>`, `<major>.<minor>` = chunk's dotted number
(`Chunk 0.15` → 0.15), `<ordinal>` = one-based position (merge-order position for
completed work, recorded in release notes). Remove hardcoded-`0`-major language;
add that major releases are sculpted via `Chunk 1.0`, `Chunk 1.1`, …
`version.sld` keeps shape `(agent-scheme-version <major> <minor> <ordinal>)`.

---

## Critical files / surfaces
- GitHub: #53 body (slim/renumber/reconcile); close #274; labels on ~154 issues;
  #364 already created.
- Repo (one commit): `docs/release-notes.md` (new), `docs/roadmap.md`,
  `AGENTS.md`, `docs/contributing.md`, `docs/feature-reflection.md`,
  `scheme/agent-scheme/version.sld` (done), three test files (done).
- Reference: `docs/issue-taxonomy.md`, `Makefile`, `.github/workflows/test.yml`.

## Risks / notes
- Tooling in this session has intermittently returned replayed/fabricated
  results; every mutation must be re-verified against real git/GitHub state, and
  destructive steps (#53 rewrite, ~150 label edits, #274 close) should be done
  one at a time with read-back. A fresh session is the lower-risk venue.
- No new `phase:*`; no closed-issue body edits beyond closing #274; only
  completed work is merge-ordered (in release notes).
