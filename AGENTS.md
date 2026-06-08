# Repository Agent Instructions

Before starting issue work in this repository, read and follow:

- `docs/contributing.md` for issue lifecycle, branch names, pull requests, and
  commit messages
- `docs/development.md` for setup, expected repository shape, and verification
- `docs/architecture.md` for the Consent Scheme design, host boundary, module map,
  and runtime expectations
- `docs/multi-host-bootstrap.md` for the Emacs-first bootstrap stance and the
  portable Scheme self-hosting path
- `docs/naming.md` for public and private Consent Scheme identifier conventions
- `docs/references.md` for canonical external Scheme references
- `docs/r7rs-small-report.md` for the local R7RS-small language reference
- `docs/licensing.md` for the project's Apache-2.0 + SPDX licensing policy
- the GitHub issue being worked

Repository conventions override generic workflow defaults. In particular:

- Branches must follow `author-name/issue-N/short-name`.
- Pull requests must target `main`, reference the issue, describe verification,
  and avoid unrelated work.
- GitHub issues that depend on other issues must record those dependencies in
  the issue description and in GitHub Issues' relationship metadata.
- Commits must use the Conventional Commits form documented in
  `docs/contributing.md`.
- Every issue branch must update the canonical runtime version in
  `scheme/consent/version.sld` to match the roadmap-derived version for
  the issue being advanced. Use #53's flat chunk map as the source: each chunk
  is numbered `Chunk <major>.<minor>` (for example `Chunk 0.15`), and the
  runtime version is `<major>.<minor>.<ordinal>` where `<major>.<minor>` is the
  chunk's dotted number and `<ordinal>` is the issue's one-based position inside
  that chunk. The major component is no longer hardcoded to `0`; a future
  `Chunk 1.0`, `Chunk 1.1`, ... line sculpts the `1.x` major release series.
  If the issue is not placed in #53, update or clarify the roadmap placement
  before calling the issue work complete.
- Retire fully shipped chunks from #53 as a standing invariant, not a one-time
  edge action. On every issue you advance, check whether an earlier chunk now
  has all of its issues shipped while still listed in #53's chunk map; if so,
  migrate that chunk to `docs/release-notes.md` (recording each shipped issue's
  final `<major>.<minor>.<ordinal>` version) and remove its section from #53 in
  the same change. Do this as a drive-by integrated with the issue at hand so a
  missed chunk edge is caught on the next issue instead of deferred. Do not
  split a chunk mid-flight: a chunk with any still-open issue keeps all of its
  issues in #53.
- The portable R7RS implementation is a first-class peer, not a secondary
  mirror of the Emacs Lisp bootstrap. For semantic changes, evaluator pass
  boundaries, public runtime behavior, standard libraries, fixtures, or tests,
  update the Emacs Lisp and portable Scheme implementations in parallel when
  practical. If one side must lead, document the remaining parity work in the
  issue, commit, or pull request instead of treating the refactor as complete.
- Public Consent Scheme identifiers must use `consent-`; private Emacs Lisp
  internals must use `consent--`.
- For Scheme-specific language questions, consult the local R7RS-small report
  reference and canonical Scheme references before relying on memory or
  incidental web search results.
- Do not put assistant, tool, vendor, or workflow branding in branch names, pull
  request titles, commit messages, issue text, documentation, or generated
  artifacts.
- For documentation-only work, run the verification commands in
  `docs/development.md` and state when `make test` is unavailable.
- After every commit pushed to a branch with an open pull request,
  background-monitor that PR's CI to completion (for example
  `gh pr checks <pr> --watch`) before reporting the work done. Never declare
  success on a partial or green-so-far signal while checks are still running,
  and re-run the watch after each follow-up push. Then read the PR's timing
  comment against recent merged PRs and flag significant timing regressions, per
  the "Continuous Integration" section of `docs/contributing.md`.
