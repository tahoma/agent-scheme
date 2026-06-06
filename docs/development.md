# Development Setup

This guide describes a seed development machine setup for working on Consent
Scheme. The repository is still early, so the required toolchain is intentionally
small and will grow as implementation tickets land.

## Required Tools

- Git
- GitHub CLI, `gh`
- Emacs, preferably a current stable release
- GNU Make
- ripgrep, `rg`, for fast repository searches

Optional but useful:

- Chibi Scheme, `chibi-scheme`, for optional portable R7RS Chibi checks and
  the reference implementation oracle runner
- Gauche, `gosh`, for additional reference implementation oracle coverage
- Guile, `guile`, and Sagittarius, `sagittarius`, for broader optional oracle
  comparison coverage
- Racket, `racket`, plus its `r7rs` package for developer oracle comparisons;
  install the package with `raco pkg install --auto r7rs`
- CHICKEN Scheme, `csi`, plus its `r7rs` egg for developer oracle comparisons;
  install the egg with `chicken-install r7rs`
- Gambit Scheme, `gsi` and `gsc`, for developer oracle comparisons and future
  compile-path checks; Homebrew packages it as `gambit-scheme`
- ShellCheck or other local lint tools for future scripts

## GitHub Access

Authenticate the GitHub CLI before working with issues or pull requests:

```sh
gh auth status
```

If authentication is missing:

```sh
gh auth login
```

Confirm the repository remote:

```sh
git remote -v
```

## Clone and Branch

Clone the repository and create a topic branch for each issue:

```sh
git clone git@github.com:tahoma/consent.git
cd consent
git switch -c author-name/issue-N/short-name
```

Use a short contributing author name as the branch prefix no matter which tools
you use.

## Read First

Before implementing a ticket, read:

- [Repository agent instructions](../AGENTS.md), for agentic or tool-assisted work
- [Architecture and threat model](architecture.md)
- [Multi-host adapter and bootstrap strategy](multi-host-bootstrap.md)
- [Secrets, local-only context, and redaction](privacy.md)
- [Naming convention](naming.md)
- [Scheme references](references.md)
- [R7RS-small report reference](r7rs-small-report.md)
- [Roadmap note](roadmap.md)
- [Contributing](contributing.md)
- [Project skill bundle](../skills/README.md), for task-specific workflow
  reminders
- The GitHub issue you are working on

The GitHub roadmap issue is the source of truth for dependency ordering. Start
with dependency-free or explicitly unblocked issues.

## Editing Expectations

- Keep canonical runtime concepts represented as Scheme-readable data.
- Treat the portable R7RS implementation as a first-class peer of the Emacs
  Lisp bootstrap, and as the long-term path toward self-hosted or native
  reader, evaluator, emitter, and REPL work.
- Prefer portable R7RS Scheme for core logic where practical.
- Preserve architectural parity between Emacs Lisp and portable Scheme modules
  for semantic behavior, evaluator pass boundaries, standard libraries,
  fixtures, and tests. If a slice lands on only one side, record the remaining
  parity work before calling the issue complete.
- Keep Emacs-specific behavior behind host adapter modules.
- Avoid project history or personal machine details in public docs, tests, and
  examples.
- Follow the commit-message rules in [Contributing](contributing.md).

## Scheme Source Comments

Portable Scheme comments carry the API and invariant documentation that future
contributors need while editing `.sld` and `.scm` files. Runtime-visible
documentation belongs to the body literal convention in
[Docstring Metadata Convention](docstring-metadata.md) when a binding needs
metadata that standard readers, reflection, reference tools, or compiled
runtimes can preserve. Comments remain source-only and are not visible through
ordinary R7RS reading.

- Start each portable Scheme file with a `;;;` header that names the library or
  source file responsibility and the host/core boundary it belongs to.
- Put a leading `;;` comment before top-level Scheme `define-record-type`,
  `define-syntax`, and plain data `define` forms.  For procedure definitions, a
  simple string docstring supersedes a leading summary comment.  Add a separate
  source comment only when it describes an invariant, policy, pass boundary, or
  portability concern that does not belong in the runtime docstring.  Section
  comments may supplement per-binding comments, but they do not replace needed
  per-binding documentation.
- For record types, document ownership of the record shape, any mutable fields,
  and whether the record is part of the public Consent Scheme datum surface or an
  internal implementation record.
- For macros, document hygiene assumptions, literal identifiers, private marker
  syntax, and the target form or pass that receives the expansion.
- Comment primitive/kernel boundaries, policy or capability assumptions,
  compiler/backend assumptions, include/load paths, and other places where a
  small local change would affect runtime authority or portability.
- Keep comments concise for tiny R7RS helpers whose names and surrounding
  source fully state most of the contract.  Do not add line-by-line narration
  for simple selectors, wrappers, or local loops.
- Keep Scheme comments public-repo safe: avoid project history, personal
  machine paths, secrets, transcripts, and non-project branding.

Runtime-visible documentation for public procedures belongs in a simple string
docstring in the procedure body, using the convention in
[Docstring Metadata Convention](docstring-metadata.md). Add docstrings to new
exported public procedures in checked-in Scheme libraries when the procedure
body form supports them. Do not keep a leading `;;` comment that only restates
the docstring. Simple string docstrings do not document macros, record fields,
library forms, renamed exports, or plain data bindings; those surfaces need
future metadata records rather than a placeholder procedure docstring.
Primitive bindings do not have reader-visible bodies, so public primitive
documentation belongs in their manifest metadata. New public primitive
manifest entries should include concise user-facing documentation and rely on
implementation procedure docstrings only as fallback for internal or generated
hooks; fallback reflection marks the origin as `(implementation-procedure
string)`.

## Test Layout

Project tests live under `tests/` and run through the repository `Makefile`.
Emacs Lisp bootstrap tests use ERT and follow these conventions:

- test files are named `tests/consent-*-test.el`
- module tests mirror implementation modules, such as
  `tests/consent-reader-test.el` for `lisp/consent-reader.el`
- shared ERT helpers should live in `tests/consent-test-helper.el` and
  provide `consent-test-helper`
- the batch runner is `tests/consent-test-runner.el`

The runner starts Emacs with `-Q --batch`, adds project-local `lisp/` and
`tests/` directories to `load-path`, loads test files in deterministic order,
and does not load user Emacs configuration.

Future R7RS conformance fixtures should plug into `make test` through the same
test command instead of adding a second top-level verification path.

Portable R7RS tests live under `tests/scheme/` and are launched by ERT. The
default portable shards run the full suite under Gambit, Racket with its `r7rs`
package, Guile, and Gauche. Chibi remains available as an optional host through
`make test-portable-chibi`, `make test-portable-eval`, and `make
test-portable-rest`; those targets use `chibi-scheme` on `PATH`, or the command
named by `CONSENT_CHIBI`, and skip when Chibi is unavailable.

Core runtime, reader, evaluator, macro, library, and standard-library changes
should normally add or update portable tests alongside the Emacs Lisp tests.
Those tests are parity checks for the product path, not optional examples of
the bootstrap implementation.

The multi-host bootstrap strategy in
[`docs/multi-host-bootstrap.md`](multi-host-bootstrap.md) defines what belongs
in portable Scheme modules versus host adapter modules. New host-neutral runtime
or library behavior should gain portable fixtures where practical before a host
adapter exposes it through editor, process, filesystem, model, or persistence
capabilities.

The local R7RS-small report reference lives in
[`docs/r7rs-small-report.md`](r7rs-small-report.md). The active R7RS-small
conformance matrix lives in [`docs/r7rs-conformance.md`](r7rs-conformance.md).
The canonical shared fixture corpus lives in
`fixtures/r7rs/conformance-cases.scm` as an `consent-fixture-suite`.
Fixture records carry `id`, `kind`, `phase`, `category`, `section`, `status`,
`oracle`, `options`, `source`, `expect`, and `description` fields so the Emacs
Lisp harness, portable Scheme harness, and conformance runner select from the
same indexed cases. Fixtures marked `pending`, `policy-gated`, or `unavailable`
are loaded and validated by ERT without being executed. Fixtures marked
`implemented` must run through `make test`.

Fixtures may also carry optional `oracle-eligibility` and `oracle-reason`
fields when a reference implementation should not run the case. The current
eligibility values are `policy-gated` and `not-oracle-eligible`. Reasons include
`host-policy`, `agent-specific`, `resource-limit`, `agent-result-record`,
`implementation-dependent`, and `unspecified`.

## Reference Oracle

Pure shared R7RS conformance fixtures can also be compared with external Scheme
implementations through the oracle runner:

```sh
make conformance-oracle
```

The default reference adapters are Chibi Scheme and Sagittarius. Gauche, Guile,
Racket, CHICKEN, and Gambit remain opt-in comparison adapters so contributors
can inspect a wider implementation matrix before changing defaults. The runner
uses `CONSENT_CHIBI`, `CONSENT_GAUCHE`, `CONSENT_GUILE`,
`CONSENT_SAGITTARIUS`, `CONSENT_RACKET`, `CONSENT_CHICKEN`,
and `CONSENT_GAMBIT` when set, otherwise it searches for `chibi-scheme`,
`gosh`, `guile`, `sagittarius`, `racket`, `csi`, and `gsi` on `PATH`. The
Racket adapter requires Racket's separate `r7rs` package and wraps generated
fixture programs with `#lang r7rs`. The CHICKEN adapter requires the `r7rs`
egg and invokes `csi` with `-q -R r7rs -s`. The Gambit adapter invokes `gsi`
with `-:r7rs,search=$REPO/scheme`, where `$REPO/scheme` is the repository's
portable R7RS library directory. Each adapter writes eligible fixtures to a
temporary R7RS program and invokes the reference implementation with that file
as the command-line program argument. Missing reference implementations are
reported as `unsupported-reference` in Scheme-readable oracle reports and do
not affect the default `make test` command.

| Adapter | Role | Environment override | Discovered command | Notes |
| --- | --- | --- | --- | --- |
| Chibi Scheme | default | `CONSENT_CHIBI` | `chibi-scheme` | Also used by optional portable Chibi checks when available. |
| Sagittarius | default | `CONSENT_SAGITTARIUS` | `sagittarius` | Runs with `-r 7` for R7RS mode. |
| Gauche | opt-in comparison | `CONSENT_GAUCHE` | `gosh` | Useful for library and writer behavior comparisons. |
| Guile | opt-in comparison | `CONSENT_GUILE` | `guile` | Runs with `--no-auto-compile --r7rs`. |
| Racket | developer-only comparison | `CONSENT_RACKET` | `racket` | Requires the Racket `r7rs` package; generated programs are wrapped with `#lang r7rs`. |
| CHICKEN Scheme | developer-only comparison | `CONSENT_CHICKEN` | `csi` | Requires the `r7rs` egg; runs with `-q -R r7rs -s`. |
| Gambit Scheme | developer-only comparison | `CONSENT_GAMBIT` | `gsi` | Homebrew formula `gambit-scheme`; runs with `-:r7rs,search=$REPO/scheme`. |

The Gambit compile path uses the same R7RS mode and library search stance as
the interpreter shard. Set `CONSENT_GAMBIT_COMPILER` to choose a specific
`gsc` executable; otherwise compile checks discover `gsc` on `PATH`. The
oracle runner does not invoke `gsc`, but documenting both tools keeps
interpreter and compiler setup aligned.

Oracle reports identify each fixture by case id and classify the comparison as
`portable-agree`, `implementation-variant`, `agent-mismatch`,
`unsupported-reference`, `policy-gated`, or `not-oracle-eligible`. The runner
intentionally skips Consent Scheme-specific result fixtures, resource-limit
fixtures, and host-effecting R7RS libraries such as `(scheme file)`,
`(scheme load)`, `(scheme process-context)`, `(scheme repl)`, and
`(scheme time)`. It also skips fixtures whose result depends on whether a
reference command reads a file as a strict R7RS program or as REPL input from a
file, since R7RS permits the latter mode to accept import declarations outside
the program prefix. The target is report-oriented; inspect `agent-mismatch`
reports as conformance investigation signals.

The oracle normalizes narrow reference writer spelling variation when the same
R7RS value is otherwise clear, such as Chibi's doubled plus sign in complex NaN
outputs. It does not collapse semantic distinctions such as exact versus
inexact numbers.

`implementation-variant` reports are intentionally visible. Treat them as
portability notes rather than failures when Consent Scheme agrees with at least
one supported reference and the remaining references differ among themselves.
Current expected sources include exact versus inexact numeric results, special
NaN and infinity spellings, optional reader support for datum labels in program
source, bytevector port optional-argument behavior, reference-specific library
loading behavior, and case-folding quirks in developer-only references. Add
output normalization only for narrow writer aliases that preserve the same R7RS
datum. Add `oracle-eligibility` metadata only when the reference command cannot
exercise the same language mode as the fixture, not merely because
implementations disagree.

To focus the report stream, pass a comma-separated status filter:

```sh
CONSENT_ORACLE_STATUSES='agent-mismatch,implementation-variant' make conformance-oracle
```

To compare a chosen reference implementation set, pass a comma-separated
reference filter:

```sh
CONSENT_ORACLE_REFERENCES='chibi,gauche,guile,sagittarius,racket,chicken,gambit' make conformance-oracle
```

To print a compact status count before the report stream:

```sh
CONSENT_ORACLE_SUMMARY=1 make conformance-oracle
```

## Host-Compiled Portable Executables

`make compile` builds executable artifacts from the portable R7RS runtime by
using external Scheme host compiler toolchains. This path packages the current
portable implementation through mature host compilers; it is not the future
Consent Scheme LLIR/native compiler backend tracked by #115 through #121.

The default compile host is Racket CS:

```sh
make compile
```

Select a host explicitly with `CONSENT_COMPILE_HOST`:

```sh
CONSENT_COMPILE_HOST=racket make compile
CONSENT_COMPILE_HOST=gambit make compile
```

The Racket path requires both `racket` and `raco`; override discovery with:

```sh
CONSENT_RACKET=/path/to/racket CONSENT_RACO=/path/to/raco make compile
```

The Gambit path requires both `gsi` and `gsc`; override discovery with:

```sh
CONSENT_GAMBIT=gsi CONSENT_GAMBIT_COMPILER=gsc CONSENT_COMPILE_HOST=gambit make compile
```

Generated outputs stay under `build/compile/<host>/` by default:

- `bin/consent`: the host-compiled executable artifact
- `src/`: generated host wrapper sources and, for Gambit, the mirrored
  portable `.sld` sources plus generated C files used for linking
- `collections/`: generated host dependency wrappers when a host needs them,
  currently the Racket path
- `manifest.scm`: Scheme-readable artifact manifest
- `logs/`: compiler, compile-timing, and smoke-test logs

Use `CONSENT_COMPILE_BUILD_DIR` to place those generated files elsewhere:

```sh
CONSENT_COMPILE_BUILD_DIR=/tmp/consent-compile make compile
```

The build runs smoke commands against the executable before reporting success:

```sh
build/compile/<host>/bin/consent --version
build/compile/<host>/bin/consent --eval '(+ 1 2)'
build/compile/<host>/bin/consent --script tests/scheme/consent-reader-test.scm
```

The smoke also runs a script by bare path (`consent FILE`, equivalent to
`consent --script FILE`) and as an executable `/bin/sh` polyglot, exercising the
shebang-handling boundary end to end. See
[executable-scripts.md](executable-scripts.md) for how to write and run an
executable Consent Scheme script.

Remove generated compile artifacts with:

```sh
make clean-compile
```

## Verification

The default local verification command is:

```sh
make test
```

`make test` runs a trimmed default shard set for a fast local loop: one
representative portable host (`test-portable-racket`,
`CONSENT_DEFAULT_PORTABLE_TEST_SHARD_TARGETS`) plus all four Emacs-hosted shards
(`test-emacs-core`, `test-emacs-library`, `test-emacs-capabilities`,
`test-emacs-tools`). The portable reader/writer/docstring machinery that the
source-metadata and docstring-retention modes exercise is host-independent, so
one portable host is enough for the default loop.

Run the exhaustive set — every portable host shard plus every Emacs shard —
with the opt-in escape hatch:

```sh
make test-full
```

`make test-full` runs `CONSENT_FULL_TEST_SHARD_TARGETS`. You can also override
the default set directly, for example to add one more host without running the
whole matrix:

```sh
CONSENT_TEST_SHARD_TARGETS='test-portable-guile test-emacs-core' make test
```

Run `make test-full` (or the matching scheduled CI lane) before landing
axis-sensitive changes to the reader, writer, or docstring machinery, since
those are the paths the trimmed default no longer fans out across every host.

Set `CONSENT_TEST_TARGET_ROOT` to keep the current checkout's Makefile and
ERT harness while pointing portable Scheme host commands at another checkout or
archive's `scheme/` directory. This is useful for historical timing sweeps that
replay a newer harness against an older reader/evaluator implementation:

```sh
CONSENT_TEST_TARGET_ROOT=/tmp/consent-old make test-portable-eval
```

CI mirrors this trimmed default on the per-push lane (`pull_request` and `push`)
and keeps the exhaustive run on a separate opt-in lane. Each push runs the full
`source_metadata` × `docstring_retention` (2 × 3) cross-product on one canonical
portable host (Gambit, the `test-portable-gambit` job) and one canonical Emacs
shard (the core language/runtime shard, the `test-emacs-core` job), and runs
only the canonical `on` / `full` combo on every other host and shard. Every host
and every Emacs shard is still represented at least once, so cross-host parity
coverage is preserved; only the redundant metadata/docstring fan-out collapses.
The exhaustive matrix — every host and shard across all six combos — runs nightly
on the `schedule` lane and on demand through `workflow_dispatch`. The trimmed
jobs (`test-portable-extra-hosts` and `test-emacs-hosted`) drive their
`source_metadata` and `docstring_retention` matrix axes from a `github.event_name`
expression, so those two events expand them back to the full axis.

CI runs the aggregate suite as host/runtime-oriented shards so timing and
failures stay visible by architectural path:

```sh
CONSENT_GAMBIT=gsi make test-portable-gambit
CONSENT_GAMBIT=gsi CONSENT_GAMBIT_COMPILER=gsc make test-portable-gambit-native
CONSENT_RACKET=racket make test-portable-racket
make test-portable-compiled
CONSENT_GUILE=guile make test-portable-guile
CONSENT_GAUCHE=gosh make test-portable-gauche
make test-emacs-core
make test-emacs-library
make test-emacs-capabilities
make test-emacs-tools
```

`make test` runs those shard targets in parallel by default. `make
test-portable` remains available as the local aggregate for the default
portable R7RS host shards. CI runs full portable-suite host shards under
Gambit, the Gambit-native compiled Consent Scheme runner, Racket with its `r7rs`
package, the Racket-built compiled Consent Scheme runner, Guile, and Gauche.
Optional Chibi shard targets remain available for manual timing and
compatibility checks:

```sh
CONSENT_CHIBI=chibi-scheme make test-portable-chibi
```

The full-suite host shards run the same portable Scheme test files so their
timing rows compare host behavior rather than different test scopes. The Racket
bridge generates
temporary `#lang r7rs` collection wrappers for checked-in `.sld` libraries
because Racket's R7RS package resolves imports as Racket collection modules.
The Racket compiled host shard runs `make compile` first, then executes that
same full-suite file list through
`build/compile/racket/bin/consent --script`. The Gambit-native shard runs
`CONSENT_COMPILE_HOST=gambit make compile`, emits the build tree's
`logs/compile.log` and `logs/smoke.log` timing datums, and executes the same
file list through `build/compile/gambit/bin/consent --script`.
CI builds and caches Gambit 4.9.7 because Ubuntu 24.04's `gambc` package is
4.9.3 and does not accept the `-:r7rs` runtime option needed for the portable
library search path. The extra R7RS host matrix runs inside an Ubuntu 26.04
container because Ubuntu 24.04 does not ship the Gauche package used by that
shard. That container base image is pulled from the rate-limit-free AWS ECR
Public Ubuntu mirror (`public.ecr.aws/ubuntu/ubuntu:26.04`) instead of Docker
Hub, whose anonymous per-IP pull limit previously timed this job out at
container provisioning. These shards contribute required host timing data. The
Emacs-hosted shards split the non-portable ERT suite into core
language/runtime, library/conformance, capability/policy, and
tools/docs/integration groups. `make test-emacs-hosted` remains available as
the local aggregate for all non-portable ERT tests with
`(not "consent-scheme-.*")`.

When `CONSENT_TEST_SELECTOR` is set, `make test` uses a single ERT runner
with that selector instead of the local shard fan-out:

```sh
CONSENT_TEST_SELECTOR='consent-smoke-test-harness-runs' make test
```

Each shard uploads a `test-log-*` artifact and writes a job summary. On pull
requests, the combined timing job also updates one PR comment with a compact
shard timing table and a collapsible detail section so reviewers can see timing
at a glance from the PR conversation. Portable Scheme runners may also emit
fine-grained `CONSENT_CI_CHECK_SECONDS` diagnostics for slow checks; the
combined summary keeps those details below the fold and treats shard wall time
as the primary signal.

Live local model tests require an OpenAI-compatible local model endpoint. Run
the CI smoke selector with:

```sh
make test-live-model-ci
```

Run all opt-in live local model tests, including the documented local model
matrix, with:

```sh
make test-live-model
```

Both live targets set `CONSENT_LIVE_MODEL_TEST=1`. The all-live target also
sets `CONSENT_LIVE_MODEL_MATRIX=1`. Use
`CONSENT_LIVE_MODEL_ENDPOINT` and `CONSENT_LIVE_MODEL_ID` to override
the default local endpoint and smoke model id.

For documentation-only changes, also run:

```sh
git diff --check
rg -n "m[y]/consent|m[y]/mcp" README.md docs
```

The `rg` command should normally return no matches. Also search for any
project-history or private-machine references relevant to the change. The
pattern uses a character class so this guide does not carry the deprecated
spelling as plain text. If a match is intentional, explain why in the pull
request.

## Expected Repository Shape

The implementation module map is defined in the architecture document. Early
work is expected to introduce directories such as:

```text
lisp/
scheme/
tests/
fixtures/
```

Do not create broad placeholder trees without an issue that needs them. Let the
first implementation tickets establish only the files they actually use.

## Local State

Keep generated state, downloaded model weights, caches, transcripts, private
memory, and machine-specific configuration out of git. Future tickets will define
the exact ignored local-state paths.

Until those paths exist, avoid committing:

- secrets or provider tokens
- absolute paths from a developer machine
- generated logs or transcripts
- downloaded third-party assets
- local Emacs state

## Pull Request Checklist

Before opening a PR:

- Confirm the branch only contains the intended issue work.
- Confirm `scheme/consent/version.sld` matches the issue's
  roadmap-derived version from #53.
- Run the available verification commands.
- Check public docs for stale personal-config or historical-repo references.
- Use a Conventional Commits message for each commit.
- Reference the issue in commit footers and the PR body.
