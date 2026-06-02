# Shared VCS Capability Contract

Consent Scheme exposes repository state through a host-neutral `(agent vcs)`
library. This is an Consent Scheme capability contract, not an SRFI compatibility target.
SRFI 170, SRFI 193, and SRFI 176 cover useful operating-system,
command-line, and version-output ground, but they do not define Git or VCS
records.

## Datum Vocabulary

The shared vocabulary is made of Scheme-readable records:

- `vcs-repository`: VCS system, repository root, and stable identity.
- `vcs-branch`: current branch or detached-head state, current commit,
  upstream, and ahead/behind counts.
- `vcs-remote`: safe remote metadata. Adapters must not expose credentialed raw
  remote URLs as Scheme-visible values.
- `vcs-commit-summary`: commit id, parent ids, subject, author metadata, and a
  host-supplied timestamp datum.
- `vcs-status-entry`: index and worktree status for one path, including
  untracked, ignored, renamed, copied, submodule, and conflicted states.
- `vcs-operation-state`: merge, rebase, cherry-pick, and bisect state as data
  rather than host-native process or editor objects.
- `vcs-conflict-state`: conflict type and affected paths.
- `vcs-diff-summary`: file-level VCS diff summary that can compose with
  `(agent diff)` hunks and line ranges when an adapter has patch detail.
- `vcs-capability-request` and `vcs-capability-result`: the request/result
  envelope that host adapters satisfy through local tools, editor APIs, or
  future native services.
- `vcs-capability-grant`: scoped mutation authority for a repository, remote,
  and operation set.
- `vcs-approval-decision`: an explicit approval or denial for one requested VCS
  mutation.
- `vcs-capability-decision`: the fail-closed authorization decision computed
  from a request, grants, and approvals.
- `vcs-capability-audit`: the stable event record connecting a request,
  decision, result, and outcome.
- `vcs-outcome`: explicit success or failure status.

Raw host objects, process handles, Magit records, editor VC objects, and
implementation-specific Git library objects stay behind the adapter boundary.

## Git Parser Fixtures

The portable library includes pure parsers for stable Git machine formats:

- `git status --porcelain=v2 -z` for branch headers and index/worktree state.
- `git diff --raw -z` for file-level diff summaries.

The parser tests cover clean branch headers, dirty paths, renamed paths,
untracked paths, ignored paths, submodule flags, detached HEAD, ahead/behind
counts, and conflicted entries. These fixtures are data-only; they do not spawn
Git or observe the host filesystem.

## Capability Requests

Host adapters use `vcs-capability-request` datums when satisfying observations:

```scheme
(vcs-capability-request
  (id req-1)
  (operation status)
  (authority read-only-observation)
  (arguments ((path ".")))
  (required-authority read-only-observation)
  (remote? #f)
  (mutating? #f))
```

Mutating requests use the same envelope, but their required authority is
separate from read-only observation:

```scheme
(vcs-capability-request
  (id req-2)
  (operation push)
  (authority remote-mutation)
  (arguments ((repository "/repo") (remote "origin") (branch "main")))
  (required-authority remote-mutation)
  (remote? #t)
  (mutating? #t))
```

Results return a matching `vcs-capability-result` with a Scheme-readable value
or a `vcs-outcome`:

```scheme
(vcs-capability-result
  (id req-1)
  (status ok)
  (value (vcs-outcome (status no-vcs) (message "No repository found."))))
```

## Read-Only Versus Mutation

Read-only operations include status, refs, branches, commit summaries, diff
summaries, remotes, and operation-state observations. Mutating operations such
as stage, commit, branch creation/deletion, checkout, fetch, pull, push, merge,
rebase, cherry-pick, revert, and reset require a separate policy-gated
capability family. The shared contract may describe their request and result
shapes, but importing `(agent vcs)` does not grant repository mutation.

## Emacs Adapter

`(emacs vcs)` is the first host adapter over this shared contract. It observes
the current Emacs project and maps Git state into the shared datums without
exposing Emacs project records, VC objects, Magit state, process objects, or
temporary buffers to Scheme code.

The adapter exports read-only procedures:

- `vcs-root`
- `vcs-branch`
- `vcs-status`
- `vcs-diff`
- `vcs-recent-commits`
- `vcs-yield`

`vcs-status` consumes `git status --porcelain=v2 -z --branch` output and returns
a `vcs-status` datum. `vcs-diff` consumes `git diff --raw -z` output and returns
a `vcs-diff-summary` datum. `vcs-recent-commits` returns
`vcs-commit-summary` records. `vcs-yield` sends any VCS datum through the
`(agent io)` event channel.

No repository mutation is exported by `(emacs vcs)`. Stage, unstage, commit,
branch creation/deletion, checkout, switch, fetch, pull, push, merge, rebase,
cherry-pick, revert, and reset remain outside this read-only adapter surface.

## Emacs Mutation Adapter

`(emacs vcs mutation)` is the separate Emacs adapter library for policy-gated
repository mutation and remote intent. It currently exports:

- `vcs-stage!`
- `vcs-unstage!`
- `vcs-commit!`
- `vcs-branch-create!`
- `vcs-switch!`
- `vcs-fetch!`
- `vcs-pull!`
- `vcs-push!`

Importing `(emacs vcs)` does not import these bindings. Calls to the mutation
library first pass the host `vcs-mutation` policy category, then construct a
shared `vcs-capability-request` and compute a `vcs-capability-decision` from
the supplied VCS grant or approval records. Missing VCS grant or approval data
returns a denied `vcs-capability-result` before Git changes the index or a
remote is contacted.

`vcs-stage!` and `vcs-unstage!` accept repository-relative `paths` and only pass
validated local paths to Git. `vcs-commit!` accepts a non-empty `message`.
`vcs-branch-create!` accepts a `name`, and `vcs-switch!` accepts a `branch`;
both reject unsafe branch/ref-looking input before passing it to Git.
`vcs-fetch!`, `vcs-pull!`, and `vcs-push!` represent remote mutation intents;
without explicit `live-remote?` authority they return `remote-unavailable`
instead of contacting the configured remote. Credentialed remote-looking input
is denied as `permission-denied` and appears in adapter-owned VCS audit records
only as redacted request data.

## Mutation Authority

`(agent vcs)` classifies local repository mutations as `repository-mutation`
and remote communication or remote-ref updates as `remote-mutation`. Stage,
unstage, commit, branch create/delete, checkout/switch, merge, rebase,
cherry-pick, revert, and reset are local repository mutations. Fetch, pull, and
push are remote mutations because they communicate with configured remotes and
may update local or remote refs.

Adapters must authorize mutating requests before changing repository state or
contacting a remote. Authorization is data-only: a
`vcs-authorize-capability-request` decision is computed from the request, a
list of `vcs-capability-grant` records, and a list of
`vcs-approval-decision` records. Missing authority denies the request with a
stable `vcs-capability-decision`; successful and denied attempts can both be
recorded with `vcs-capability-audit`.

Example scoped local grant:

```scheme
(vcs-capability-grant
  (id grant-local)
  (authority repository-mutation)
  (operations (stage commit))
  (repository "/repo")
  (remote #f))
```

Example remote approval:

```scheme
(vcs-approval-decision
  (id approve-push)
  (request-id req-2)
  (status approved)
  (reason "User approved push."))
```

These records are not host process handles, Git objects, VC objects, Magit
records, or credential containers. Emacs, native CLI, daemon, and future host
adapters may implement the actual operations differently, but they should keep
the same Scheme-visible request, decision, result, audit, and outcome datums.

## Outcomes

VCS failures are represented explicitly instead of collapsed into generic
errors:

- `no-vcs`
- `unsupported-vcs`
- `git-not-found`
- `dirty-index`
- `conflict`
- `timeout`
- `permission-denied`
- `remote-authentication-failed`
- `remote-unavailable`
- `denied`
- `cancelled`

Adapters may add narrower diagnostic fields around these statuses, but the
portable status symbols remain the common boundary vocabulary.

## SRFI Relationship

This contract is intentionally Consent Scheme-specific. SRFI 170 helps describe
operating-system services, SRFI 193 covers command-line metadata, and SRFI 176
covers version output conventions. None of those SRFIs define VCS records,
Git porcelain parsing, repository mutation policy, or host adapter request
datums.
