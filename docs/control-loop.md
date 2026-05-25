# Task Lifecycle and Control Loop

Agent Scheme's control loop is the runtime layer that turns Scheme-readable
building blocks into an inspectable task-oriented agent. It receives a user
goal or a resumed task, observes context, routes model work, updates plans,
invokes Scheme helpers and host capabilities through policy, records
transcripts and audit entries, pauses when authority is missing, and stops with
a receipt that explains why.

This design builds on [Architecture and threat model](architecture.md),
[Capability Environment and Effect Lowering](capability-environment.md),
[Session Lifecycle and Snapshots](session-lifecycle.md),
[Jobs, Cancellation, and Streaming Yields](jobs.md), and
[Secrets, Local-Only Context, and Redaction](privacy.md). The control loop does
not grant authority by itself. It composes the session, capability,
approval, job, provider, memory, plan, rule, pattern, skill, transcript, and
audit surfaces into one loop.

The contract is Scheme-readable data. A host may keep private handles,
threads, provider clients, UI buffers, or caches, but the task state and every
decision that crosses the control-loop boundary must be printable and
replayable as ordinary Scheme datums.

## Lifecycle States

Task state is a public symbol. The state machine intentionally separates active
work, pause states, and stop states so hosts can distinguish "resume this
later" from "this task is done."

| State | Meaning | Normal exits |
| --- | --- | --- |
| `created` | A task datum exists but no observation has run. | `observing`, `cancelled` |
| `observing` | The loop is collecting context, memory, rules, skills, patterns, host state, or provider diagnostics. | `planning`, `waiting-for-host`, `blocked`, `failed` |
| `planning` | The loop is creating or updating an `(agent plan)` record. | `acting`, `waiting-for-model`, `blocked`, `failed` |
| `acting` | The loop is evaluating Scheme helpers or requesting host capabilities. | `observing`, `waiting-for-approval`, `waiting-for-host`, `waiting-for-model`, `blocked`, `complete`, `failed` |
| `waiting-for-approval` | A policy gate produced an approval request and the task can resume after a host or user decision. | `acting`, `blocked`, `cancelled` |
| `waiting-for-model` | A provider request is in flight or queued by provider policy. | `planning`, `acting`, `blocked`, `failed`, `cancelled` |
| `waiting-for-host` | A host capability, job, process, or adapter callback is pending. | `observing`, `acting`, `blocked`, `failed`, `cancelled` |
| `blocked` | The loop cannot continue without new authority, input, dependency work, or a changed environment. | `observing`, `planning`, `acting`, `cancelled` |
| `cancelled` | The user, host, or budget controller cancelled the task. | terminal |
| `failed` | The loop stopped because an error condition escaped the retry or recovery policy. | terminal unless a host creates a resumed task |
| `complete` | The verifier accepted the result or the goal's stop condition was satisfied. | terminal |

Allowed transitions are intentionally narrow:

```text
created -> observing -> planning -> acting
acting -> observing
acting -> complete
observing|planning|acting -> waiting-for-approval|waiting-for-model|waiting-for-host
waiting-for-approval|waiting-for-model|waiting-for-host -> observing|planning|acting
observing|planning|acting|waiting-for-approval|waiting-for-model|waiting-for-host -> blocked
created|observing|planning|acting|waiting-for-approval|waiting-for-model|waiting-for-host|blocked -> cancelled
observing|planning|acting|waiting-for-model|waiting-for-host -> failed
blocked -> observing|planning|acting
```

Retry policy may move a task from `failed` into a new task whose
`resumed-from` field names the failed task. The original task remains immutable
as a stop receipt.

## Pause and Stop Receipts

Pausing and stopping are first-class because they drive different host
behavior. A pause receipt preserves enough information for a host to display,
resume, or transfer the task. A stop receipt preserves enough information for a
user, debugger, transcript viewer, or future replay runner to understand why no
further work happened.

```scheme
(task-pause
  (task task-17)
  (state waiting-for-approval)
  (observed-state
   (observation-set obs-17
     (summary "edit requires confirmation")))
  (intended-next-action action-17)
  (capability-gate
   (capability-decision
     (id dec-17)
     (status needs-approval)
     (policy (buffer-edit confirm))
     (reason "mutating buffer action requires approval")))
  (model-route
   (model-routing-decision
     (status selected)
     (role approval-explainer)
     (provider local-openai-compatible)
     (model qwen-coder)))
  (approval-status pending)
  (verifier-result not-run)
  (pause-reason approval-required))
```

```scheme
(task-stop
  (task task-17)
  (state complete)
  (observed-state
   (observation-set obs-31
     (summary "tests passed and diff matches plan")))
  (intended-next-action none)
  (capability-gate none)
  (model-route none)
  (approval-status none)
  (verifier-result
   (verifier-result
     (status passed)
     (evidence ((test make-test) (diff reviewed)))))
  (stop-reason completed-goal))
```

Stop reasons include `completed-goal`, `waiting-for-user-input`,
`approval-denied`, `authority-unavailable`, `budget-exhausted`,
`repeated-failed-action`, `model-provider-unavailable`, `host-effect-timeout`,
`cancelled-by-user`, `condition-failed`, and `insufficient-evidence`.

## Control Loop

The outer loop is deterministic around policy and state transitions even when
model output is nondeterministic.

1. Receive a user task, protocol request, or resumed task datum.
2. Create or resume the session and derive the task capability environment.
3. Load applicable context, memory, rules, skills, workflow patterns, current
   plan state, provider diagnostics, and transcript history.
4. Enter `observing` and collect read-only observations through Scheme helpers
   or capability requests.
5. Select model roles through provider routing policy. The runtime chooses the
   route; model output may suggest a role but cannot authorize the route.
6. Enter `planning` and create or update an `(agent plan)` record.
7. Enter `acting` and choose the next action from the plan, model result,
   rules, and verifier state.
8. Invoke pure Scheme helpers directly under budget. Invoke host observations
   and mutations only through `capability-request` and policy.
9. Consume `(agent io)` events: `agent-yield`, `agent-progress`,
   `agent-request`, `agent-warn`, model stream events, host progress, warnings,
   and results.
10. Update the task record, step record, plan, memory, transcript, budget
    ledger, and audit sink with the new Scheme-readable data.
11. If a policy gate requires approval, move to `waiting-for-approval` with a
    pause receipt.
12. If a provider or host operation is pending, move to `waiting-for-model` or
    `waiting-for-host` with a pause receipt.
13. If authority, input, dependencies, or evidence are missing, move to
    `blocked` with a pause receipt.
14. If the verifier passes, move to `complete` with a stop receipt.
15. If cancellation, exhaustion, repeated failure, provider unavailability, or
    an unrecovered condition occurs, move to `cancelled` or `failed` with a
    stop receipt.
16. Otherwise continue from the next observation or action.

Runtime policy decisions, user-facing rules, and model suggestions are separate
inputs. Policy decides whether authority may be used. Rules guide behavior and
collaboration. Model output proposes text, plans, code, summaries, or review
findings. A model suggestion never creates a grant, resolves an approval, marks
a verifier as passed, or bypasses redaction.

## Scheme-Readable Records

These records are stable design shapes for issues that turn the lifecycle into
executable code. They are ordinary datums, not host objects.

```scheme
(agent-task
  (id task-17)
  (state acting)
  (goal "Replace the old helper name and verify tests.")
  (session project-main)
  (scope project)
  (created-at "2026-05-25T12:00:00-0700")
  (resumed-from none)
  (context ((project-root "/repo/") (request-source user)))
  (memory ((memory-ref m-42)))
  (rules ((rule-set project-rules)))
  (skills ((agent-skill refactor-helper)))
  (patterns ((workflow-pattern test-first-change)))
  (plan plan-17)
  (current-step step-2)
  (budget
   (task-budget
     (max-steps 120000)
     (max-host-calls 200)
     (max-provider-tokens 20000)
     (used-steps 3400)
     (used-host-calls 12)
     (used-provider-tokens 820)))
  (provider-routes
   ((planner local-openai-compatible qwen-planner)
    (coder local-openai-compatible qwen-coder)))
  (capability-environment env-task-17)
  (transcript transcript-task-17)
  (audit audit-task-17))
```

```scheme
(agent-step
  (id step-2)
  (task task-17)
  (state acting)
  (goal "Apply the approved edit.")
  (plan-item plan-item-2)
  (attempt 1)
  (observations (obs-10 obs-11))
  (decision decision-2)
  (action action-2)
  (events ())
  (result pending))
```

```scheme
(agent-action
  (id action-2)
  (task task-17)
  (step step-2)
  (kind host-capability)
  (library (emacs buffer edit))
  (binding buffer-replace!)
  (arguments ((handle buffer h-12) 120 140 "agent-scheme-read"))
  (requires ((policy buffer-edit)
             (grant region-edit)
             (approval approval-buffer-grant)))
  (expected-outcome
   (observation-needed (kind diff) (source buffer))))
```

```scheme
(agent-observation
  (id obs-11)
  (task task-17)
  (source (agent io))
  (kind progress)
  (value
   (progress
     (phase test)
     (datum (command "make test") (status passed))))
  (redactions ())
  (audit audit-91))
```

```scheme
(agent-decision
  (id decision-2)
  (task task-17)
  (step step-2)
  (observed-state (obs-10 obs-11))
  (selected-action action-2)
  (reason "Plan item has approval and narrow edit grant.")
  (policy-input
   ((capability-decision dec-2)
    (approval-status approved)))
  (model-input
   ((model-routing-decision
      (role coder)
      (provider local-openai-compatible)
      (model qwen-coder))))
  (rules-input ((rule-set project-rules)))
  (verifier-result not-run))
```

```scheme
(agent-completion
  (task task-17)
  (status complete)
  (value
   (task-result
     (summary "Helper rename applied and verified.")
     (artifacts ((diff diff-17) (test make-test)))))
  (stop
   (task-stop
     (task task-17)
     (state complete)
     (stop-reason completed-goal)))
  (transcript transcript-task-17)
  (audit audit-task-17))
```

Records may carry implementation-specific extension fields, but core fields
must remain readable by older hosts. Unknown fields are ignored by readers that
do not need them.

## Capability Arbitration

The control loop arbitrates actions before any host effect runs.

Read-only observations request the least authority needed to inspect state. A
read-only action may be allowed by project trust, an existing grant, or a host
policy default, but it still produces an audit record. Examples include current
buffer metadata, project diagnostics, provider diagnostics, VCS status, and
memory reads.

Mutating actions require explicit authority. Buffer edits, file writes,
process control, repository mutation, approval resolution, provider disclosure,
skill script execution, and exported artifacts require matching grants,
policy approval, and any domain-specific approval record before they run.

Arbitration result shapes follow the capability environment vocabulary:

```scheme
(capability-decision
  (id dec-2)
  (request req-2)
  (status approved)
  (policy (buffer-edit confirm))
  (grant region-edit)
  (approval approval-buffer-grant)
  (reason "approved narrow edit"))
```

Denied authority moves the task to `blocked`, `failed`, or `cancelled`
depending on the reason. `approval denied` is a stop reason when the planned
work cannot continue without that effect. `authority-unavailable` is a pause
reason when the user or host can provide a new grant. Stale handles fail closed
before adapter calls:

```scheme
(capability-decision
  (id dec-stale)
  (request req-stale)
  (status denied)
  (reason stale-handles)
  (stale-handles ((handle buffer h-12)))
  (task-state blocked))
```

Repeated stale-handle or denial outcomes should advance the task to a stop
receipt instead of retrying indefinitely.

## Model Provider Roles

Provider routing chooses models for roles, not providers hardcoded in the
control loop. Initial roles are:

| Role | Use |
| --- | --- |
| `planner` | Create or revise task plans and next-step options. |
| `coder` | Generate code, Scheme helpers, patches, or executable snippets. |
| `reviewer` | Review diffs, plans, results, and verifier evidence. |
| `summarizer` | Compress observations, transcripts, and long context. |
| `memory-curator` | Suggest memory reads, writes, confidence changes, and cleanup. |
| `approval-explainer` | Produce user-facing explanations for approval prompts. |
| `cheap-background` | Run low-cost classification, extraction, or progress summarization. |

The runtime may add narrower roles later, but all roles use the same routing
surface:

```scheme
(model-routing-decision
  (status selected)
  (role planner)
  (provider local-openai-compatible)
  (model qwen-planner)
  (kind local)
  (transport openai-compatible-http))
```

Provider routing decisions are audit input. They are not authority decisions
for remote disclosure, tool use, host mutation, approval resolution, or memory
writes.

## Provider Request Contract

Provider calls use one shared vocabulary for local and remote routes. The same
task lifecycle records reference provider requests, responses, stream events,
errors, budgets, cancellation, transcript entries, and audit entries.

```scheme
(model-provider-request
  (id model-req-17)
  (task task-17)
  (step step-2)
  (role planner)
  (provider local-openai-compatible)
  (model qwen-planner)
  (kind local)
  (transport openai-compatible-http)
  (prompt
   (messages
    ((system "Plan the next Agent Scheme task step.")
     (user "Use the observations and current plan."))))
  (context
   ((task task-17)
    (plan plan-17)
    (observations (obs-10 obs-11))))
  (disclosure local-only-ok)
  (redactions ())
  (budget
   (provider-budget
     (max-input-tokens 8000)
     (max-output-tokens 1200)
     (max-wall-ms 30000)))
  (cancellation
   (model-provider-cancellation
     (id cancel-model-req-17)
     (status active)))
  (transcript transcript-task-17)
  (audit audit-task-17))
```

```scheme
(model-provider-response
  (id model-res-17)
  (request model-req-17)
  (status ok)
  (content
   (model-message
     (text "Observe the diff, then run the focused test.")))
  (usage
   (provider-usage
     (input-tokens 1420)
     (output-tokens 18)))
  (events
   ((model-provider-stream-event
      (request model-req-17)
      (kind final)
      (index 3))))
  (audit audit-104))
```

```scheme
(model-provider-stream-event
  (request model-req-17)
  (kind delta)
  (index 2)
  (content "run the focused test")
  (received-at "2026-05-25T12:01:00-0700"))
```

```scheme
(model-provider-error
  (request model-req-17)
  (status unavailable)
  (provider local-openai-compatible)
  (reason "endpoint did not respond")
  (retry retry-with-alternate-provider)
  (task-state blocked))
```

```scheme
(model-provider-cancellation
  (id cancel-model-req-17)
  (request model-req-17)
  (status requested)
  (reason task-cancelled))
```

Remote and local providers must share this request shape. Remote providers add
redaction and disclosure checks before transport. Local inference uses the same
role-routing and lifecycle machinery without requiring remote disclosure.

## Remote and Local Provider Examples

The remote example represents a future remote OpenAI-compatible provider. The
exact production provider adapter is a follow-up implementation detail; the
control-loop contract is the request, redaction, policy, transcript, budget,
cancellation, and audit shape.

```scheme
(model-provider
  (id remote-openai)
  (kind remote)
  (transport openai-compatible-http)
  (endpoint "https://api.openai.example/v1")
  (models
   (((id gpt-example)
     (roles (planner coder reviewer summarizer memory-curator
             approval-explainer cheap-background))
     (privacy public)))))
```

```scheme
(model-provider-request
  (id model-req-remote-1)
  (task task-17)
  (step step-1)
  (role planner)
  (provider remote-openai)
  (model gpt-example)
  (kind remote)
  (transport openai-compatible-http)
  (prompt (messages ((user "Plan the task from the redacted context."))))
  (context
   ((summary "public issue context")
    (redaction
     (kind secret)
     (source provider-credentials)
     (replacement "[redacted]")
     (policy local-only))))
  (disclosure remote-redacted)
  (redactions
   ((redaction
      (kind secret)
      (source provider-credentials)
      (replacement "[redacted]"))))
  (policy
   (capability-decision
     (status approved)
     (policy (remote-provider-routing allow))
     (reason "payload is redacted and contains no local-only context")))
  (budget (provider-budget (max-input-tokens 8000) (max-output-tokens 1200)))
  (cancellation (model-provider-cancellation (status active)))
  (transcript transcript-task-17)
  (audit audit-task-17))
```

If the same remote request carries local-only context, redaction is not enough;
the task pauses or blocks before transport:

```scheme
(capability-decision
  (status denied)
  (policy (remote-provider-routing deny))
  (reason "local-only context requires explicit approval")
  (task-state blocked))
```

The local example uses the OpenAI-compatible local inference path from issue
#26. It shares role routing, task lifecycle, provider request, response,
stream/event, error, provider-budget, model-provider-cancellation, transcript,
and audit vocabulary with the remote example.

```scheme
(model-provider
  (id local-openai-compatible)
  (kind local)
  (transport openai-compatible-http)
  (endpoint "http://127.0.0.1:11434/v1")
  (models
   (((id qwen-coder)
     (roles (planner coder reviewer summarizer memory-curator
             approval-explainer cheap-background))
     (privacy local)))))
```

```scheme
(model-provider-request
  (id model-req-local-1)
  (task task-17)
  (step step-1)
  (role planner)
  (provider local-openai-compatible)
  (model qwen-coder)
  (kind local)
  (transport openai-compatible-http)
  (prompt (messages ((user "Plan from local project context."))))
  (context
   ((summary "private project state")
    (local-only #t)))
  (disclosure local-only-ok)
  (redactions ())
  (policy
   (model-routing-decision
     (status selected)
     (role planner)
     (provider local-openai-compatible)
     (model qwen-coder)
     (kind local)))
  (budget (provider-budget (max-input-tokens 8000) (max-output-tokens 1200)))
  (cancellation (model-provider-cancellation (status active)))
  (transcript transcript-task-17)
  (audit audit-task-17))
```

Credentialed or heavyweight provider runs may be skipped in local developer
verification, but skipped paths must still validate these shared datums with
fakes or fixtures. Issue #289 owns the focused remote and local provider proof
fixtures that exercise the same contract through the minimal task runner.

## Minimal Executable Slice

The smallest useful runner should:

1. Accept one user goal and optional resumed task datum.
2. Create an `agent-task` in `created`, then move through `observing`,
   `planning`, and `acting`.
3. Build a task-scoped capability environment from user, project, session, and
   task layers.
4. Load selected context, memory, rules, skills, and workflow patterns as
   Scheme-readable data.
5. Route at least the `planner` role through `(agent models)` provider policy.
6. Produce or update one `(agent plan)` record.
7. Run at least one pure Scheme helper or read-only host observation through
   the policy path.
8. Consume `(agent io)` events and provider events into the task transcript.
9. Update plan, memory, transcript, audit, and budget datums after each step.
10. Stop as `complete` with an `agent-completion` or pause as `blocked` with a
    `task-pause`.

The executable slice does not need production-grade scheduling, multiple
provider adapters, streaming UI polish, or persistence. Those are follow-up
issues. It must prove that task records, role routing, provider requests,
policy decisions, yields, budgets, transcript entries, and stop receipts are in
one inspectable loop.

## Failure and Stop Conditions

The loop stops or pauses through explicit receipts:

| Condition | State | Receipt reason |
| --- | --- | --- |
| Goal verified | `complete` | `completed-goal` |
| User input is needed | `blocked` | `waiting-for-user-input` |
| Approval denied | `cancelled` or `blocked` | `approval-denied` |
| Authority unavailable | `blocked` | `authority-unavailable` |
| Budget exhausted | `failed` or `blocked` | `budget-exhausted` |
| Repeated failed action | `failed` | `repeated-failed-action` |
| Model unavailable | `blocked` or `failed` | `model-provider-unavailable` |
| Host effect timeout | `blocked` or `failed` | `host-effect-timeout` |
| User cancellation | `cancelled` | `cancelled-by-user` |
| Verifier lacks evidence | `blocked` | `insufficient-evidence` |

Retry policy must be bounded by budget and by repeated-failure receipts. A
model may suggest retrying, but the runtime decides whether retry remains
allowed.

## Follow-Up Issues

This design is the umbrella contract for issue #281. Executable work should be
scheduled in focused slices:

- #285: define task lifecycle records and state transitions.
- #286: implement the minimal task runner control loop.
- #287: create shared task control-loop fixtures.
- #288: persist and resume task lifecycle records.
- #289: prove one remote provider API and one local inference API through the
  shared task lifecycle and provider datums.
- #291: define the budget ledger and stop receipts that task, job, provider,
  transcript, and capability records can share.

Existing prerequisite surfaces remain part of the contract: `(agent io)` from
#21, scoped memory from #22, provider routing from #26, approvals and grants
from #30 and #43, jobs and cancellation from #46, redaction from #49, budgets
from #51, rules and patterns from #58 and #59, the capability environment from
#102, and provider capabilities from #223.
