# CI Run Record

The test workflow emits one structured, machine-readable record per run so the
project accumulates a longitudinal dataset for later analysis — questions like
"how did this metric drift across the last N pull requests" that the
human-facing timing summary and PR comment cannot answer because they describe a
single run and are not retained in a queryable shape.

The record is produced by `consent-ci` (`lisp/consent-ci.el`) over the same
shard logs the combined timing summary already collects, in the `test-summary`
job. It is not a parallel mechanism: the shard outcomes come from
`consent-ci-parse-log-file`, and the run/change/parity provenance comes from the
CI environment.

## Format

- **JSON Lines.** One JSON object per line, written append-only, so multiple
  runs accumulate in a single file without rewriting prior entries.
- **Self-describing.** Every object carries an integer `schema_version`
  (`consent-ci-run-record-schema-version`).
- **Single line per run.** The current workflow writes one record per
  `run-record.jsonl`; the file is JSON Lines so a future durable sink can
  concatenate runs without reformatting.

## Schema (`schema_version: 1`)

Any field may be `null` when its source is unavailable (for example, change
scope on `push` and `schedule` lanes, which have no pull request to size).

| Field | Type | Meaning |
| --- | --- | --- |
| `schema_version` | integer | Record schema version. |
| `generated_at` | string \| null | UTC ISO-8601 timestamp the record was written. |
| `run.repository` | string \| null | `owner/name`. |
| `run.event` | string \| null | Trigger event (`pull_request`, `push`, `schedule`, `workflow_dispatch`). |
| `run.run_id` | string \| null | GitHub Actions run id. |
| `run.run_attempt` | integer \| null | Run attempt number (>1 indicates a re-run). |
| `run.run_url` | string \| null | Link to the workflow run. |
| `run.actor` | string \| null | Triggering actor. |
| `run.runner_os` | string \| null | Runner OS of the summary job. |
| `run.runner_arch` | string \| null | Runner architecture of the summary job. |
| `change.pr_number` | integer \| null | Pull request number. |
| `change.base_ref` | string \| null | Base branch (or pushed ref). |
| `change.head_sha` | string \| null | Head commit SHA. |
| `change.base_sha` | string \| null | Base commit SHA. |
| `change.changed_files` | integer \| null | Files changed in the PR. |
| `change.insertions` | integer \| null | Lines added in the PR. |
| `change.deletions` | integer \| null | Lines removed in the PR. |
| `change.version_changed` | boolean \| null | Whether `scheme/consent/version.sld` is among the PR's changed files. |
| `parity.result` | string \| null | Outcome of the Emacs/portable parity gate job (`success`, `failure`, `skipped`, ...). |
| `totals.shards` | integer | Number of shards in this record. |
| `totals.ran` | integer | Total tests run across shards. |
| `totals.expected` | integer | Total expected results. |
| `totals.unexpected` | integer | Total unexpected results. |
| `totals.skipped` | integer | Total skipped results. |
| `totals.ert_seconds` | number | Summed ERT time across shards. |
| `totals.wall_seconds` | number | Summed CI wall time across shards. |
| `totals.all_passed` | boolean | True when no shard reported an unexpected result. |
| `shards[]` | array | One entry per shard, in stable display order. |
| `shards[].name` | string | Shard base name (variant suffix split out). |
| `shards[].selector` | string | ERT/portable selector the shard ran. |
| `shards[].source_metadata` | string \| null | Source-metadata variant (`on`/`off`), when present. |
| `shards[].docstrings` | string \| null | Docstring-retention variant (`full`/`simple`/`none`), when present. |
| `shards[].ran` / `expected` / `unexpected` / `skipped` | integer | Per-shard result counts. |
| `shards[].ert_seconds` | number | Per-shard ERT time. |
| `shards[].wall_seconds` | number \| null | Per-shard CI wall time, when recorded. |
| `shards[].passed` | boolean | Derived: no unexpected results in the shard. |

## Schema discipline

The record is only valuable if it stays diffable across runs. Therefore:

- **Add fields freely**, but **never silently rename or repurpose** an existing
  field. A rename breaks every longitudinal query written against the old name.
- **Bump `schema_version`** when the record shape changes, and note the change
  here.
- Treat `null` as "source unavailable for this lane," not "zero."

## Durable sink

The record currently lands as the **`ci-run-record` artifact** (90-day
retention). This is the zero-infrastructure first step: it adds no workflow
permissions and keeps the change self-contained.

A truly permanent, directly queryable sink — appending each run's line to an
orphan `ci-metrics` branch, or shipping to an external store — is intentionally
deferred to a follow-up, since it requires `contents: write` (or external
credentials) and a corresponding security review. Until then, treat artifacts as
the source and download-and-concatenate for analysis.

## Documented follow-ups

These belong to the per-PR-record effort but are out of scope for the first
slice; each is a `schema_version` bump when it lands:

- **Per-shard toolchain versions** (Emacs, Gambit, Racket, Guile, Gauche). Each
  shard must record its host version into its log first.
- **Cross-attempt flake signal** (first-attempt vs. final outcome). `run_attempt`
  is recorded today; deriving "passed only on re-run" needs cross-attempt state.
- **Failure category** (compile vs. assertion vs. timeout vs. infra) and
  which step failed first.
- **Decomposed step and cache timing** (checkout, host build, compile, test;
  cache hit/miss and restored size).
- **Missing-shard detection** — the record reflects shards that produced a log;
  a shard whose job died before emitting one is simply absent.
