# Development Setup

This guide describes a seed development machine setup for working on Agent
Scheme. The repository is still early, so the required toolchain is intentionally
small and will grow as implementation tickets land.

## Required Tools

- Git
- GitHub CLI, `gh`
- Emacs, preferably a current stable release
- GNU Make, once the test harness lands
- ripgrep, `rg`, for fast repository searches

Optional but useful:

- An R7RS Scheme implementation for comparing behavior against reference
  Scheme programs and conformance fixtures
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

## Verification

Today, the repository is mostly documentation. For documentation-only changes,
run:

```sh
git diff --check
rg -n "m[y]/agent-scheme|m[y]/mcp" README.md docs
```

The `rg` command should normally return no matches. Also search for any
project-history or private-machine references relevant to the change. The
pattern uses a character class so this guide does not carry the deprecated
spelling as plain text. If a match is intentional, explain why in the pull
request.

Once the implementation and test harness land, the default verification command
should be:

```sh
make test
```

Until then, note explicitly when `make test` is unavailable.

## Expected Repository Shape

The implementation module map is defined in the architecture document. Early
work is expected to introduce directories such as:

```text
lisp/
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
