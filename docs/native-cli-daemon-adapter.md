# Native CLI and Daemon Adapter Contract

The native CLI and daemon adapter is the first planned non-Emacs host for Agent
Scheme. It should make the runtime usable from a terminal, a batch command, and
a long-lived local daemon without changing the Scheme-facing language contract.

This contract refines the host/core boundary described in
[Architecture and threat model](architecture.md),
[Multi-Host Adapter and Bootstrap Strategy](multi-host-bootstrap.md), and
[Capability Environment and Effect Lowering](capability-environment.md). It is
not an implementation plan for a native compiler. The initial adapter may run
the interpreter, while future compiled execution must use the same
Scheme-readable request, decision, result, event, audit, and error records.

## Adapter Declaration

The adapter declaration is Scheme-readable data. A CLI process may print it,
load it as a fixture, or expose it through the daemon control channel.

```scheme
(host-adapter
  (name native-cli-daemon)
  (contract r7rs-small)
  (modes (cli batch daemon))
  (execution
    ((interpreted
       (frontend shared)
       (effect-path shared-capability-request))
     (compiled
       (status future)
       (frontend shared)
       (effect-path shared-capability-request)
       (runtime-abi agent-scheme-compiled-runtime))))
  (provides
    ((library (cli cwd))
     (library (cli file))
     (library (cli environment))
     (library (cli stdio))
     (library (cli terminal))
     (library (cli process))
     (library (cli daemon))
     (library (cli audit))
     (library (agent capability))
     (library (agent approval))
     (library (agent io))
     (library (agent session))))
  (mediates
    ((library (scheme file))
     (library (scheme load))
     (library (scheme process-context))
     (library (scheme read))
     (library (scheme write))))
  (authority
    ((read-only-observation allow-or-confirm)
     (filesystem-read grant-required)
     (filesystem-mutation confirmation-gated)
     (terminal-io confirmation-gated)
     (environment-observation redaction-gated)
     (environment-mutation confirmation-gated)
     (process-observation allow-or-confirm)
     (process-control confirmation-gated)
     (daemon-control confirmation-gated)
     (audit-observation redaction-gated)
     (audit-export confirmation-gated)))
  (validation
    ((portable-contract-suite any-r7rs)
     (mock-adapter-suite emacs-ert)
     (process-boundary-suite native-cli))))
```

`provides` names adapter-specific and shared Agent Scheme libraries that the
host can install. `mediates` names standard R7RS libraries whose bindings lower
to the same capability environment when they observe or mutate host state.
Importing one of these libraries only installs bindings; authority still comes
from policy decisions, grants, and live handle checks.

General guidance for choosing between R7RS `cond-expand`, `(features)`, and
runtime `host-adapter` reflection is documented in
[Feature and Host Reflection](feature-reflection.md).

## Initial Capability Libraries

Adapter-specific libraries use the `(cli ...)` prefix. They describe terminal
and daemon host capabilities, not language semantics. Standard R7RS libraries
keep their standard names and route effectful operations through the same
capability request path.

| Library | Initial surface | Domain | Authority class |
| --- | --- | --- | --- |
| `(cli cwd)` | current working directory, path resolution, optional session cwd change | `file`, `session` | `read-only-observation`, `filesystem-read`, `filesystem-mutation` for cwd changes |
| `(cli file)` | directory handles, file handles, metadata, directory listing, host-backed file ports | `file`, `port` | `filesystem-read`; `filesystem-mutation` for create, write, rename, and delete |
| `(cli environment)` | process arguments, selected environment variables, redacted environment summaries | `process`, `provider` | `environment-observation`, `environment-mutation` |
| `(cli stdio)` | standard input, output, error, pipe handles, transcript-backed ports | `port` | `terminal-io`, `audit-observation` |
| `(cli terminal)` | terminal status, terminal dimensions, interactive approval prompt rendering | `host-ui` | `read-only-observation`, `terminal-io` |
| `(cli process)` | process job handles, spawn requests, status, wait, signal, process-backed ports | `process`, `port` | `process-observation`, `process-control` |
| `(cli daemon)` | daemon status, client handles, session listing, request routing, shutdown | `session`, `process` | `daemon-control`, `process-control` |
| `(cli audit)` | audit sink handles, tailing, rotation, redacted export | `memory`, `port` | `audit-observation`, `audit-export` |

The shared libraries `(agent capability)`, `(agent approval)`, `(agent io)`,
and `(agent session)` keep the same Scheme-level shapes across Emacs, CLI, and
daemon hosts. The CLI adapter only changes how approvals are displayed, how
events are transported, and how live host resources are represented behind
handles.

## Handles and Liveness

The adapter must keep live native objects out of Scheme values. Scheme code
receives opaque handles and printable records:

```scheme
(handle
  (id h-job-42)
  (kind process-job)
  (domain process)
  (adapter native-cli-daemon)
  (session project-main)
  (grant g-run-tests)
  (status live))
```

Initial handle kinds:

| Kind | Backing resource | Stale when |
| --- | --- | --- |
| `cwd` | session current working directory | the path disappears, resolves outside its grant, or project trust changes |
| `directory` | opened or resolved directory | the path no longer exists, leaves the allowed root, or permissions change |
| `file` | file identity or path lease | the file disappears, changes identity when identity was required, or leaves the allowed root |
| `file-port` | host-backed file descriptor or stream | the port is closed, revoked, or no longer matches its file grant |
| `stdio-port` | stdin, stdout, stderr, pipe, or transcript stream | the descriptor closes, the daemon client disconnects, or the terminal contract changes |
| `process-job` | child process or daemon-managed job | the process exits, is reaped, is detached, or belongs to a retired session |
| `process-port` | process stdin, stdout, or stderr stream | the stream closes, the job exits, or the owning grant expires |
| `environment` | captured process environment view | the view is older than the approved snapshot or contains denied secrets |
| `terminal` | controlling terminal or prompt channel | no controlling terminal exists, the TTY changes, or the prompt channel closes |
| `daemon-client` | local daemon connection | the socket disconnects, authentication changes, or the client session retires |
| `audit-sink` | host audit log, session log, or export stream | the sink rotates, closes, is revoked, or no longer accepts the session |
| `session` | daemon-side runtime session | the session retires, fails revalidation, or crosses a policy boundary |

Every host operation revalidates the handle before touching the host resource.
Reusing a stale handle creates a denied capability decision and a Scheme
condition before the adapter performs the operation.

```scheme
(adapter-error
  (kind stale-handle)
  (adapter native-cli-daemon)
  (handle h-job-42)
  (domain process)
  (operation process-status)
  (condition
    (capability-error
      (kind stale-handle)
      (handle h-job-42)
      (domain process))))
```

## Prompt Policy

The adapter has three prompt postures.

Interactive terminal mode uses the controlling terminal for approvals when one
exists. Prompts are rendered on stderr or a dedicated control descriptor, not by
consuming Scheme stdin. The prompt shows a redacted summary of the request,
grant, resource, and expected audit entry. The response creates an
`approval-decision` and a `capability-decision` datum before any effect runs.

Batch mode is noninteractive. Any policy action of `confirm` fails closed unless
the request is covered by an existing grant, an explicit command-line policy
file, or a preloaded approval decision. The denial reason is
`noninteractive-confirmation-unavailable`.

Daemon mode is noninteractive by default but may have a control client that can
receive approval requests. If a session supports asynchronous approval, the
adapter may suspend the evaluation and emit an `approval-request` event. If no
approval channel is registered, or if the evaluation is marked non-suspendable,
the adapter denies the request with
`noninteractive-confirmation-unavailable`.

All modes must write audit records for approvals, denials, timeouts, and stale
approval handles. A terminal prompt is user interaction, not authority by
itself; the resulting decision still passes through the capability environment.

## Boundary Records

Host boundary records are Scheme-readable and may be transported as text,
datums, JSON, or daemon messages. The datum shape remains the contract.

### Request and Decision

Effectful bindings lower to capability requests. The adapter records a decision
before performing an allowed operation.

```scheme
(capability-request
  (id req-run-17)
  (session project-main)
  (adapter native-cli-daemon)
  (library (cli process))
  (binding process-start)
  (domain process)
  (operation spawn)
  (resource (command "make") (arguments ("test")) (cwd h-cwd-1))
  (effect process-control)
  (requires ((policy command-process)
             (grant (domain process)
                    (operation spawn)
                    (resource command cwd)))))

(capability-decision
  (id dec-run-17)
  (request req-run-17)
  (status approved)
  (policy (command-process confirm))
  (grant g-run-tests)
  (reason "approved terminal prompt"))
```

### Result

Results describe adapter-visible evaluation outcome and resource use. A result
may inline small events, but durable logs should be referenced by audit ids.

```scheme
(adapter-result
  (id result-17)
  (adapter native-cli-daemon)
  (mode cli)
  (execution interpreted)
  (session project-main)
  (status ok)
  (value (handle process-job h-job-42))
  (events (event-31 event-32))
  (audit (audit-201 audit-202))
  (resource-usage ((cpu-ms 41) (wall-ms 93) (host-calls 1))))
```

`execution` is `interpreted` for the current evaluator path and `compiled` for a
future native backend. The field is descriptive; it must not change the
capability request, policy, event, audit, or error vocabulary.

### Event

Events carry streaming output and daemon control notifications without becoming
canonical state.

```scheme
(adapter-event
  (id event-31)
  (adapter native-cli-daemon)
  (session project-main)
  (kind stdout)
  (source (handle process-job h-job-42))
  (payload "1..42\n")
  (timestamp "2026-05-21T13:25:00-0700"))
```

Initial event kinds are `stdout`, `stderr`, `stdin-request`, `process-exit`,
`approval-request`, `approval-decision`, `progress`, `warning`,
`daemon-connected`, `daemon-disconnected`, and `audit-rotated`. Events crossing
a provider, export, or persistence boundary must pass redaction first.

### Audit

Audit records remain the durable explanation of what the adapter touched.

```scheme
(adapter-audit
  (id audit-201)
  (adapter native-cli-daemon)
  (session project-main)
  (request req-run-17)
  (decision dec-run-17)
  (result (ok (handle process-job h-job-42)))
  (sink (handle audit-sink h-audit-1))
  (redactions ())
  (timestamp "2026-05-21T13:25:00-0700"))
```

Audit export is a separate capability from audit observation. Exported records
must not contain raw secrets, local-only context, or live host objects.

### Error

Adapter errors are conditions plus boundary metadata. They must be printable
and comparable across interpreter, daemon, and future compiled execution.

```scheme
(adapter-error
  (kind policy-denied)
  (adapter native-cli-daemon)
  (session project-main)
  (request req-run-18)
  (decision dec-run-18)
  (message "process spawn denied by policy")
  (irritants ((command "rm") (arguments ("-rf" "/tmp/example")))))
```

Initial error kinds are `policy-denied`, `approval-timeout`,
`noninteractive-confirmation-unavailable`, `stale-handle`, `invalid-handle`,
`unsupported-effect`, `process-exit`, `stdio-closed`, `terminal-unavailable`,
`daemon-disconnected`, `transport-error`, and `redaction-denied`.

## Interpreted and Compiled Execution

The CLI and daemon adapter must not distinguish authority by execution strategy.
Both paths consume the same shared frontend output and the same effect lowering
contract:

- Interpreted execution runs normalized forms in the current evaluator.
- Future compiled execution runs emitted code through the compiled runtime ABI.
- Pure operations may use backend-specific fast paths.
- Host effects lower to `shared-capability-request` in both paths.
- Compiled code must not call native filesystem, process, environment, network,
  terminal, daemon, provider, or audit APIs directly.
- Unsupported compiled effects remain explicit `unsupported-effect` records or
  signal adapter errors before touching host state.
- Results, events, denied requests, stale-handle behavior, and audit records
  must remain comparable across interpreted and compiled execution.

This keeps the native compiler path from becoming a separate policy surface.

## Test Strategy

The first test layer should run without Emacs and without spawning real
processes:

- parse the adapter declaration and capability manifest as Scheme-readable data,
- validate initial library names, authority classes, handle kinds, and error
  kinds,
- check request, decision, result, event, audit, and error record shapes,
- exercise noninteractive confirmation denial with a mock policy resolver,
- compare interpreted and compiled mock effect records for the same request
  shape,
- verify stale-handle decisions fail before a mock host operation runs.

The second layer may run through the current ERT harness with a mock adapter:

- bridge the Scheme-readable contract into the existing test command,
- compare the mock adapter with the capability environment vocabulary,
- prove approval requests, event records, and audit entries are redacted before
  export.

The real process-boundary suite needs a native CLI or daemon executable:

- spawn, wait for, signal, and reap a child process,
- stream stdin, stdout, and stderr without mixing them with approval prompts,
- verify cwd, file, directory, and environment grants in a child process,
- confirm closed pipes and exited jobs become stale handles,
- exercise daemon client disconnect and session retirement behavior,
- exercise terminal prompts through a real TTY or pseudo-terminal.

## Acceptance and First Executable Slice

This contract satisfies the design issue when:

- the initial `(cli ...)` capability libraries and authority classes are named,
- handle kinds and stale-handle behavior are explicit,
- terminal, batch, and daemon prompt behavior are specified,
- result, event, audit, and error records are Scheme-readable,
- interpreted execution and future compiled execution share the same effect
  path,
- tests are split between portable contract validation, mock adapter behavior,
  and real process-boundary coverage.

The first executable slice should be a checked-in Scheme-readable adapter
declaration and manifest fixture, plus a portable validator that can run under
any available R7RS implementation and through `make test`. That slice should
cover library names, authority classes, handle kinds, noninteractive denial,
record shapes, and stale-handle denial without starting a real daemon or
spawning a child process.
