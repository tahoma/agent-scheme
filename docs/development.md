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

The local R7RS-small report reference lives in
[`docs/r7rs-small-report.md`](r7rs-small-report.md). The active R7RS-small
conformance matrix lives in [`docs/r7rs-conformance.md`](r7rs-conformance.md),
with representative fixtures in `fixtures/r7rs/conformance-cases.scm`. Fixtures
marked `pending`, `policy-gated`, or `unavailable` are loaded and validated by
ERT without being executed. Fixtures marked `implemented` must run through
`make test`.

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
