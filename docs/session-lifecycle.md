# Session Lifecycle and Snapshots

Agent Scheme sessions are explicit runtime records for evaluation state that
survives beyond a single form. The host keeps live environments, syntax
bindings, handles, and buffers private; the public inspection surface is a
Scheme-readable session datum.

## Session Record

A session record has this public shape:

```scheme
(session
  (id project-main)
  (scope project)
  (status idle)
  (project-root "/path/to/project/")
  (imports ((scheme base) (agent io)))
  (definitions (summarize answer))
  (macros (when-agent-ready))
  (memory ((fact "Project sessions inherit project policy.")))
  (handles ((handle buffer h-17)))
  (capability-grants ())
  (skill-activations ())
  (transcript (...))
  (recent-events (...))
  (snapshots (snapshot-1)))
```

The datum is the durable contract. Host structures such as Emacs buffers,
windows, processes, jobs, policy callbacks, and evaluator internals remain
adapter-owned and are represented only through handles or records that can be
validated.

## Scopes

Agent Scheme has three session scopes:

- `fresh`: one-off evaluation. It is created as `collectable`, does not enter
  the durable registry, and should not retain imports, definitions, macros, or
  handles after the evaluation boundary.
- `named`: a long-lived agent REPL session. Users and agents can share the same
  id, inspect its imports, definitions, transcript, recent events, and memory,
  and resume it later.
- `project`: a named session tied to a `project.el` root. It carries project
  policy, project memory, project trust posture, and project helper bindings.

## States

Lifecycle states are public symbols:

- `new`: created but not yet evaluated or resumed.
- `active`: currently resumed or evaluating.
- `idle`: available for reuse after a successful evaluation.
- `suspended`: intentionally paused without releasing durable Scheme state.
- `retired`: closed by the user or agent; handles and temporary resources have
  been released.
- `failed`: the last evaluation failed; the transcript records the error.
- `collectable`: no durable registry entry should retain the session.

Allowed normal transitions:

```text
new -> active -> idle
new -> suspended -> active
idle -> suspended -> active
active -> failed -> active
new|active|idle|suspended|failed -> retired
fresh -> collectable
retired -> collectable
```

Retired sessions cannot be resumed, suspended, or evaluated. A failed session
can be resumed so a user or agent can inspect and repair the environment.

## Procedures

The `(agent session)` library exposes lifecycle procedures:

```scheme
(session-create! scope options)
(session-ref id)
(session-list scope)
(session-suspend! id)
(session-resume! id)
(session-snapshot! id options)
(session-fork! id options)
(session-retire! id)
```

`options` is a Scheme association list. Common fields are:

```scheme
((id project-main)
 (project-root "/path/to/project/")
 (memory ())
 (capability-grants ()))
```

The Emacs bootstrap also exposes matching `agent-scheme-session-*` functions
and `agent-scheme-session-eval-source` for evaluating source inside a durable
session.

## Native Emacs REPL UX

`agent-scheme-start-repl` starts or switches to a project session by default.
It creates the native, non-vterm buffer set for the session:

```text
*Agent: PROJECT*
*Agent Scheme: PROJECT*
*Agent Events: PROJECT*
*Agent Audit: PROJECT*
*Agent Approvals: PROJECT*
```

`*Agent: PROJECT*` shows the current session record and status. `*Agent
Scheme: PROJECT*` shows the persistent REPL transcript as Scheme-readable
`transcript-entry` datums. `*Agent Events: PROJECT*` shows recent `(agent io)`
records, `*Agent Audit: PROJECT*` shows session-scoped audit entries, and
`*Agent Approvals: PROJECT*` shows pending request events such as approval
requests emitted through `(agent-request datum)`.

The `C-c a` dispatch command exposes entries for starting, switching,
inspecting, stopping, evaluating in, and opening the native session buffers.
Buffers include a mode-line status indicator in the form
`Agent[SESSION:STATUS]`.

## Snapshots

`session-snapshot!` returns a Scheme-readable snapshot record:

```scheme
(session-snapshot
  (id snapshot-1)
  (source-session project-main)
  (scope project)
  (status idle)
  (imports ((scheme base) (agent io)))
  (definitions (summarize answer))
  (macros ())
  (memory ())
  (capability-grants ())
  (skill-activations ())
  (handles ((handle buffer h-17)))
  (stale-handles ())
  (transcript (...))
  (recent-events (...))
  (restores (imports definitions macros memory-bindings
                     capability-grant-requests transcripts recent-yields))
  (revalidates (project-root handle-references capability-grants
                             skill-activations))
  (never-restore (stale-emacs-handles active-jobs approval-decisions
                                      provider-secrets host-runtime-internals)))
```

Snapshots preserve Scheme data and references. They do not copy live host
objects. A restore path may rebuild imports, definitions, macro bindings,
memory, transcripts, and recent yields from data. It must revalidate project
roots, handle references, capability grants, and skill activations before use.

Snapshots never blindly restore stale Emacs handles, active jobs or processes,
approval decisions, provider secrets, or host-specific runtime internals.

## Forking

`session-fork!` creates a new session with a fresh id and a `forked-from` field.
The fork receives copied environment cells, syntax bindings, imports, memory,
transcript data, and currently live handle references. Handle references are
revalidated during fork and stale handles are cleaned up before the fork is
registered.

Forks start in `new` state so callers must explicitly resume or evaluate them.

## Cleanup

Retirement releases all handles tracked by the session and clears the public
handle list. Snapshotting also revalidates tracked handles: stale handles are
reported in the snapshot `stale-handles` field and removed from the host handle
registry.

Future job and process ownership should follow the same rule: the session
record may preserve a Scheme-readable job reference or transcript, but the live
process is adapter-owned and must be stopped, detached, or revalidated through
policy before reuse.

## Events and Audit

Lifecycle actions emit `session-lifecycle` audit entries. Session-backed
evaluation records transcript entries and keeps recent `(agent io)` events from
the global audit stream so users and agents can inspect yields, warnings,
progress, and requests that happened during the last evaluation.

Skill activation and trust decisions remain policy events. A session snapshot
records skill activation references as data, but a restored or forked session
must revalidate them against current project trust and policy before use.

## Shared REPL Use

A named session is the shared workspace between a user and an agent:

```elisp
(agent-scheme-session-create! 'named '(:id "repl-main"))
(agent-scheme-session-eval-source
 "repl-main"
 "(define answer 41)
  (+ answer 1)")
(agent-scheme-session-ref "repl-main")
```

The user can inspect the same session datum in an Emacs buffer or through a
future protocol response. The agent can resume the session, add definitions,
read recent event records, snapshot it before risky work, fork it for an
experiment, or retire it to release handles and temporary resources.
