# Repository Agent Instructions

## Agent Entry Points

`AGENTS.md` is the canonical, repository-owned instruction source for
tool-assisted work in this repository. Tool-specific bootstrap files checked
into the repository must only delegate here; they must not carry independent,
weaker, or conflicting policy. If an agent client does not automatically load
this file or expand a checked-in include, read `AGENTS.md` manually before
touching files, running verification, committing, pushing, or opening a pull
request.

Before starting issue work in this repository, read and follow:

- `docs/contributing.md` for issue lifecycle, branch names, pull requests, and
  commit messages
- `docs/development.md` for setup, expected repository shape, and verification
- `docs/architecture.md` for the Consent Scheme design, host boundary, module map,
  and runtime expectations
- `docs/multi-host-bootstrap.md` for the Emacs-first bootstrap stance and the
  portable Scheme self-hosting path
- `docs/naming.md` for public and private Consent Scheme identifier conventions
- `docs/scheme-style.md` for Scheme source layout, docstrings, and metadata
  formatting
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
- The portable R7RS layer is the default home for host-neutral behavior. Keep
  the dual-core surface to the smallest subset that must be implemented
  separately by each bootstrap or host, such as irreducible reader, evaluator,
  macro, runtime primitive, and host-effect adapter code. Before adding or
  retaining parallel Emacs Lisp and Scheme implementations, ask whether the
  behavior can instead be single-sourced as portable Scheme loaded by both
  bootstraps.
- The portable R7RS implementation is a first-class peer, not a secondary
  mirror of the Emacs Lisp bootstrap -- and the strongest form of parity is a
  single shared implementation, not two kept in step. Any library expressible in
  Consent Scheme over `(scheme base)` must be authored once as a host-neutral
  `.sld` and loaded by both evaluator bootstraps, not implemented twice. The
  established pattern is `scheme/consent/case-lambda.sld` /
  `scheme/consent/lazy.sld` and the source-loaded `(agent ...)` libraries
  registered through
  `register-source-library` / `consent--agent-source-library-files` in
  `lisp/consent-library.el`. Before writing or extending a native Emacs-Lisp
  implementation of a library, ask whether it is expressible over
  `(scheme base)`; if so, write or extend the shared `.sld` and load it from
  both hosts instead of adding a twin. When an existing pure library is still
  dual-implemented, prefer collapsing it to single source over maintaining
  parity by hand.
- Reserve parallel Emacs-Lisp and portable-Scheme implementation for the
  irreducible layer the language cannot express about itself: the reader, the
  evaluator core and its pass boundaries, base primitives, and host FFI
  (process/network/filesystem I/O, buffers, persistence, policy and approval
  effects). A library is mixed when only some of its operations are host effects
  (e.g. `(agent context)`, whose `current-buffer-context` observes live
  buffers): single-source its pure substrate and keep the host operations as
  primitives. When you change the irreducible layer's semantics or public
  runtime behavior, update both host implementations in parallel when practical;
  if one side must lead, document the remaining parity work in the issue,
  commit, or pull request instead of treating the refactor as complete. This
  obligation governs the irreducible layer only -- it is not a license to mirror
  pure library logic that should be single-sourced, and shared conformance
  fixtures and tests are a single corpus exercised on both hosts, not duplicated
  per host.
- Public Consent Scheme identifiers must use `consent-`; private Emacs Lisp
  internals must use `consent--`.
- For Scheme-specific language questions, consult the local R7RS-small report
  reference and canonical Scheme references before relying on memory or
  incidental web search results.
- When editing expanded Scheme docstring metadata, keep a descriptor's
  `(type ...)` on the same line as the parameter or `returns` head when that
  line fits within the soft line limit; keep longer type forms on their own
  line. Prefer plain description strings when they fit, and reserve
  string-list descriptions for wrapping prose.
- Do not put assistant, tool, vendor, or workflow branding in branch names, pull
  request titles, commit messages, issue text, generated artifacts, or ordinary
  documentation. The dedicated project credits page is the exception for
  explicit tool-assisted development credit; keep that credit there instead of
  repeating it in functional history or process metadata.
- For documentation-only work, run the verification commands in
  `docs/development.md` and state when `make test` is unavailable.
- After every commit pushed to a branch with an open pull request,
  background-monitor that PR's CI to completion (for example
  `gh pr checks <pr> --watch`) before reporting the work done. Never declare
  success on a partial or green-so-far signal while checks are still running,
  and re-run the watch after each follow-up push. Then read the PR's timing
  comment against recent merged PRs and flag significant timing regressions, per
  the "Continuous Integration" section of `docs/contributing.md`.
