# Development Setup

This guide describes a seed development machine setup for working on Agent
Scheme. The repository is still early, so the required toolchain is intentionally
small and will grow as implementation tickets land.

## Required Tools

- Git
- GitHub CLI, `gh`
- Emacs, preferably a current stable release
- GNU Make
- ripgrep, `rg`, for fast repository searches

Optional but useful:

- Chibi Scheme, `chibi-scheme`, for running portable R7RS bootstrap tests
  and the reference implementation oracle runner
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
git clone git@github.com:tahoma/agent-scheme.git
cd agent-scheme
git switch -c author-name/issue-N/short-name
```

Use a short contributing author name as the branch prefix no matter which tools
you use.

## Read First

Before implementing a ticket, read:

- [Repository agent instructions](../AGENTS.md), for agentic or tool-assisted work
- [Architecture and threat model](architecture.md)
- [Multi-host adapter and bootstrap strategy](multi-host-bootstrap.md)
- [Naming convention](naming.md)
- [Scheme references](references.md)
- [R7RS-small report reference](r7rs-small-report.md)
- [Roadmap note](roadmap.md)
- [Contributing](contributing.md)
- The GitHub issue you are working on

The GitHub roadmap issue is the source of truth for dependency ordering. Start
with dependency-free or explicitly unblocked issues.

## Editing Expectations

- Keep canonical runtime concepts represented as Scheme-readable data.
- Prefer portable R7RS Scheme for core logic where practical.
- Keep Emacs-specific behavior behind host adapter modules.
- Avoid project history or personal machine details in public docs, tests, and
  examples.
- Follow the commit-message rules in [Contributing](contributing.md).

## Scheme Source Comments

Portable Scheme does not have the Emacs Lisp docstring convention, so source
comments carry the API and invariant documentation that future contributors
need while editing `.sld` and `.scm` files.

- Start each portable Scheme file with a `;;;` header that names the library or
  source file responsibility and the host/core boundary it belongs to.
- Put a leading `;;` comment before every top-level Scheme `define`,
  `define-record-type`, and `define-syntax` form.  The comment should describe
  the contract, data shape, invariant, or pass boundary that is not obvious
  from the identifier.  Section comments may supplement these comments, but they
  do not replace the per-binding leading comment.
- For record types, document ownership of the record shape, any mutable fields,
  and whether the record is part of the public Agent Scheme datum surface or an
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

## Test Layout

Project tests live under `tests/` and run through the repository `Makefile`.
Emacs Lisp bootstrap tests use ERT and follow these conventions:

- test files are named `tests/agent-scheme-*-test.el`
- module tests mirror implementation modules, such as
  `tests/agent-scheme-reader-test.el` for `lisp/agent-scheme-reader.el`
- shared ERT helpers should live in `tests/agent-scheme-test-helper.el` and
  provide `agent-scheme-test-helper`
- the batch runner is `tests/agent-scheme-test-runner.el`

The runner starts Emacs with `-Q --batch`, adds project-local `lisp/` and
`tests/` directories to `load-path`, loads test files in deterministic order,
and does not load user Emacs configuration.

Future R7RS conformance fixtures should plug into `make test` through the same
test command instead of adding a second top-level verification path.

Portable R7RS tests live under `tests/scheme/` and are launched by ERT. The
current portable reader harness uses Chibi Scheme when `chibi-scheme` is on
`PATH`, or the command named by `AGENT_SCHEME_CHIBI`. If Chibi is unavailable,
the ERT test is skipped so a minimal Emacs-only checkout can still run the
bootstrap suite.

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
`fixtures/r7rs/conformance-cases.scm` as an `agent-scheme-fixture-suite`.
Fixture records carry `id`, `kind`, `phase`, `category`, `section`, `status`,
`oracle`, `options`, `source`, `expect`, and `description` fields so the Emacs
Lisp harness, portable Scheme harness, and conformance runner select from the
same indexed cases. Fixtures marked `pending`, `policy-gated`, or `unavailable`
are loaded and validated by ERT without being executed. Fixtures marked
`implemented` must run through `make test`.

## Reference Oracle

Pure shared R7RS conformance fixtures can also be compared with external Scheme
implementations through the oracle runner:

```sh
make conformance-oracle
```

The first reference adapter is Chibi Scheme. The runner uses
`AGENT_SCHEME_CHIBI` when set, otherwise it searches for `chibi-scheme` on
`PATH`. The Chibi adapter writes each eligible fixture to a temporary R7RS
program and invokes Chibi with that file as the command-line program argument.
Missing reference implementations are reported as `unsupported-reference` in
Scheme-readable oracle reports and do not affect the default `make test`
command.

Oracle reports identify each fixture by case id and classify the comparison as
`portable-agree`, `implementation-variant`, `agent-mismatch`,
`unsupported-reference`, `policy-gated`, or `not-oracle-eligible`. The runner
intentionally skips Agent Scheme-specific result fixtures, resource-limit
fixtures, and host-effecting R7RS libraries such as `(scheme file)`,
`(scheme load)`, `(scheme process-context)`, `(scheme repl)`, and
`(scheme time)`. The target is report-oriented; inspect `agent-mismatch`
reports as conformance investigation signals.

The oracle normalizes narrow reference writer spelling variation when the same
R7RS value is otherwise clear, such as Chibi's doubled plus sign in complex NaN
outputs. It does not collapse semantic distinctions such as exact versus
inexact numbers.

To focus the report stream, pass a comma-separated status filter:

```sh
AGENT_SCHEME_ORACLE_STATUSES='agent-mismatch,implementation-variant' make conformance-oracle
```

To print a compact status count before the report stream:

```sh
AGENT_SCHEME_ORACLE_SUMMARY=1 make conformance-oracle
```

## Verification

The default local verification command is:

```sh
make test
```

To run a narrower ERT selector:

```sh
AGENT_SCHEME_TEST_SELECTOR='agent-scheme-smoke-test-harness-runs' make test
```

For documentation-only changes, also run:

```sh
git diff --check
rg -n "m[y]/agent-scheme|m[y]/mcp" README.md docs
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
- Run the available verification commands.
- Check public docs for stale personal-config or historical-repo references.
- Use a Conventional Commits message for each commit.
- Reference the issue in commit footers and the PR body.
