# Shared VCS Capability Contract

Agent Scheme exposes repository state through a host-neutral `(agent vcs)`
library. This is an Agent Scheme capability contract, not an SRFI compatibility target.
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
  (mutating? #f))
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

Adapters may add narrower diagnostic fields around these statuses, but the
portable status symbols remain the common boundary vocabulary.

## SRFI Relationship

This contract is intentionally Agent Scheme-specific. SRFI 170 helps describe
operating-system services, SRFI 193 covers command-line metadata, and SRFI 176
covers version output conventions. None of those SRFIs define VCS records,
Git porcelain parsing, repository mutation policy, or host adapter request
datums.
