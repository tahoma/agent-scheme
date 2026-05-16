# Repository Agent Instructions

Before starting issue work in this repository, read and follow:

- `docs/contributing.md` for issue lifecycle, branch names, pull requests, and
  commit messages
- `docs/development.md` for setup, expected repository shape, and verification
- `docs/architecture.md` for the Agent Scheme design, host boundary, module map,
  and runtime expectations
- `docs/naming.md` for public and private Agent Scheme identifier conventions
- `docs/references.md` for canonical external Scheme references
- `docs/r7rs-small-report.md` for the local R7RS-small language reference
- the GitHub issue being worked

Repository conventions override generic workflow defaults. In particular:

- Branches must follow `author-name/issue-N/short-name`.
- Pull requests must target `main`, reference the issue, describe verification,
  and avoid unrelated work.
- Commits must use the Conventional Commits form documented in
  `docs/contributing.md`.
- Public Agent Scheme identifiers must use `agent-scheme-`; private Emacs Lisp
  internals must use `agent-scheme--`.
- For Scheme-specific language questions, consult the local R7RS-small report
  reference and canonical Scheme references before relying on memory or
  incidental web search results.
- Do not put assistant, tool, vendor, or workflow branding in branch names, pull
  request titles, commit messages, issue text, documentation, or generated
  artifacts.
- For documentation-only work, run the verification commands in
  `docs/development.md` and state when `make test` is unavailable.
