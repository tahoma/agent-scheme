# Capability Environment and Effect Lowering

Consent Scheme evaluates pure R7RS-small code under resource budgets, but every
operation that can observe or mutate host state goes through a session
capability environment. The environment is Scheme-readable data that connects
user defaults, project trust, session state, task-specific grants, policy
decisions, handles, revocation, audit entries, and backend lowering.

This document refines the policy, grant, session, redaction, and pass-boundary
model described in [Architecture and threat model](architecture.md),
[Session Lifecycle and Snapshots](session-lifecycle.md),
[Secrets, Local-Only Context, and Redaction](privacy.md), and
[Multi-Host Adapter and Bootstrap Strategy](multi-host-bootstrap.md).

## Capability Environment Datum

A capability environment is the effective authority view for one evaluation
task. It is derived from durable user policy, repository or project policy, the
active session, and any dynamic grant installed for the current task.

```scheme
(capability-environment
  (id env-project-main-eval-42)
  (session project-main)
  (scope project)
  (project-root "/repo/")
  (layers (defaults user project session task))
  (policy
    ((pure-r7rs allow)
     (standard-host-effect confirm)
     (command-process confirm)
     (remote-provider-routing allow)))
  (grants
    ((capability-grant
       (id g-read-fixtures)
       (domain file)
       (operations (read metadata include load))
       (scope (project-root "/repo/")
              (paths ("fixtures/r7rs"))
              (remote denied))
       (expires session)
       (status active))))
  (handles
    ((handle
       (id h-file-17)
       (kind file-port)
       (domain port)
       (backing file)
       (grant g-read-fixtures)
       (status live))))
  (revocations ())
  (audit-sink (session project-main))
  (redaction-policy local-only-default))
```

The datum is the public contract. Host adapters may keep private tables for
live objects, callbacks, caches, provider clients, or open descriptors, but
those host objects are not Scheme values. Scheme code receives opaque handles
and printable records only.

The environment contains these durable concepts:

- `policy`: category actions such as `allow`, `deny`, or `confirm`.
- `grants`: attenuated authority records for domains, operations, resources,
  lifetimes, and identities.
- `handles`: references to live host resources that must be revalidated before
  each use.
- `revocations`: closed grants or handles that continue to explain why later
  requests fail.
- `audit-sink`: the session or host log that receives request, decision, and
  outcome datums.
- `redaction-policy`: the disclosure posture applied before audit export,
  memory writes, transcript persistence, skill disclosure, or provider routing.

## Requests, Decisions, and Audit

Portable Scheme code requests effects as data. A request describes the desired
operation, not permission to perform it.

```scheme
(capability-request
  (id req-102)
  (session project-main)
  (source (form (file-exists? "fixtures/r7rs/conformance-cases.scm")))
  (library (scheme file))
  (binding file-exists?)
  (domain file)
  (operation metadata)
  (resource (path "fixtures/r7rs/conformance-cases.scm"))
  (effect read-only-observation)
  (requires ((policy standard-host-effect)
             (grant (domain file)
                    (operation metadata)
                    (resource path)))))
```

The host adapter resolves the request against the capability environment,
records a decision, and only then performs the host operation if the decision is
allowed.

```scheme
(capability-decision
  (id dec-102)
  (request req-102)
  (status approved)
  (policy (standard-host-effect allow))
  (grant g-read-fixtures)
  (attenuation ((root "/repo/") (path "fixtures/r7rs/conformance-cases.scm")))
  (reason "path is inside approved project fixture root"))
```

Every decision and outcome is auditable as Scheme data. Audit records never
need to expose raw host objects or unredacted secrets.

```scheme
(capability-audit
  (id audit-102)
  (session project-main)
  (request req-102)
  (decision dec-102)
  (result (ok #t))
  (redactions ())
  (timestamp "2026-05-20T02:36:16-0700"))
```

Denied requests are audit records too. A denial returns or signals an Agent
Scheme condition before the host effect runs.

```scheme
(capability-decision
  (id dec-103)
  (request req-103)
  (status denied)
  (policy (standard-host-effect confirm))
  (grant none)
  (reason "no active file grant covers path"))
```

## Grant Resolution

Capability resolution checks layers from highest precedence to lowest:

```text
task > session > project > user > defaults
```

Resolution follows these rules:

1. Defaults define the conservative baseline for pure evaluation and standard
   host-effect categories.
2. User policy may narrow or relax defaults for the local instance.
3. Project policy may narrow user authority for a repository or project trust
   scope, but it cannot silently broaden a user-level denial.
4. Session grants add durable authority for a named or project session, subject
   to current policy and handle revalidation.
5. Task grants add the narrowest dynamic authority for one evaluation,
   approval, skill action, or backend job.

More specific layers can attenuate earlier layers by operation, resource,
range, root, provider, use count, lifetime, skill identity, or session id. A
specific layer must not convert a broader denial into authority unless an
explicit user policy or approval created a new grant at that layer. Policy says
whether authority may exist; grants say how little of that authority a request
may use.

For one request, the resolver:

1. normalizes the requested domain, operation, and resource,
2. rejects revoked, expired, stale, or mismatched grants,
3. applies deny rules before allow rules,
4. selects the narrowest active grant that covers the normalized request,
5. asks policy for `allow`, `deny`, or `confirm`,
6. creates an approval request when confirmation is required,
7. records the decision and only then calls the adapter.

Importing a library never grants authority by itself. For example, importing
`(scheme file)` installs bindings that can construct file requests; those
bindings still need a policy decision and a matching file grant before touching
the filesystem.

## Capability Domains

Capability domains are explicit so host effects do not become evaluator special
cases.

| Domain | Examples | Required authority |
| --- | --- | --- |
| `pure` | ordinary `(scheme base)` computation, macros, string and bytevector ports | resource budgets |
| `file` | `(scheme file)`, `(scheme load)`, `include`, `include-ci`, project-local library loading | path-scoped file grants plus policy |
| `port` | host file ports, process ports, transcript ports, provider streams, virtual ports | backing-resource grant and port operation grant |
| `process` | whitelisted commands, compile jobs, process environment, process-backed ports | command/process policy, command whitelists, and future command-scoped grants |
| `network` | HTTP, remote files, external APIs, remote resources | network policy, destination grants, redaction |
| `provider` | model providers, model streams, embedding or completion calls | provider routing policy, secret redaction, disclosure checks |
| `memory` | instance, project, and session memory reads or writes | memory-scope policy and redaction |
| `host-ui` | buffers, windows, frames, commands, approval buffers | adapter capability grants and host policy |
| `skill` | skill activation, resource reads, bundled scripts, exports | skill trust and skill operation policy |

Each primitive or library binding with effects identifies its domain,
operation, policy category, required grant shape, interpreter hook, and future
compiler lowering hint in the primitive manifest. Backends consume that
metadata; they do not infer authority from implementation shortcuts.

## File Sandboxing

File access is a `file` capability domain, not a special evaluator branch. The
same model covers `(scheme file)`, `(scheme load)`, `include`, `include-ci`, and
future project-local library loading.

A file grant is path-scoped and operation-scoped:

```scheme
(capability-grant
  (id g-project-read)
  (domain file)
  (operations (read metadata include include-ci load))
  (scope (project-root "/repo/")
         (paths ("fixtures/r7rs" "scheme/standard-library"))
         (remote denied)
         (symlinks resolve-within-root))
  (expires session)
  (reason "Allow checked-in project source and fixture reads."))
```

File sandboxing rules:

- Normalize relative paths against the active project root or the explicit
  source file directory for `include` and `include-ci`.
- Resolve `.` and `..` segments before grant matching.
- Resolve symlinks before allowing host access, and deny if the resolved target
  escapes the approved root.
- Treat remote files, TRAMP-style paths, URLs, and mounted provider resources
  as separate `network` or `provider` requests unless a file grant explicitly
  names that authority.
- Separate metadata, read, write, create, delete, include, load, and library
  source operations.
- Treat `include` and `include-ci` as frontend library-resolution file reads
  that emit file requests; the frontend must not read arbitrary host files
  directly.
- Treat `(scheme load)` as both a file read and a code-loading request that
  extends an evaluation environment under the current session and budget.
- Treat future project-local library loading as a file read plus a library
  resolver request so a compiler backend sees the same authority boundary as
  the interpreter.

An allowed file request can produce a file handle or a port handle. The handle
inherits the grant id and must be checked again before each host operation.

## Port Sandboxing

Ports are a `port` capability domain with explicit backing resources. In-memory
string and bytevector ports are host-neutral values governed by resource
budgets. Host-backed ports are handles derived from other domains.

```scheme
(port-capability
  (id p-file-17)
  (kind textual-input)
  (backing file)
  (handle h-file-17)
  (operations (read close))
  (grant g-project-read)
  (limits ((characters 65536) (reads 1024)))
  (status open))
```

Port sandboxing rules:

- String ports and bytevector ports need only ordinary resource budgets unless
  their contents are disclosed to audit, memory, transcript, skill, or provider
  boundaries.
- Host file ports require an approved file request when opened and a live port
  handle for every read, write, seek, or close operation.
- Process ports require a process grant for the job and a port grant for the
  stream direction.
- Transcript ports are session resources. Reading or writing them requires
  session or memory authority and must pass redaction before persistence.
- Model streams are provider resources. They require provider-routing policy,
  disclosure checks, and redaction before bytes leave the local runtime.
- Virtual ports must declare their backing domain and operation set. They are
  not an escape hatch around file, process, network, provider, or memory
  policy.
- Default current ports are policy-gated when they resolve to host resources.
  Explicit in-memory ports stay portable.

Closing a port invalidates the port handle. Later use of the same handle fails
closed as stale, even if the original grant remains active.

## Dynamic Grants and Attenuation

Dynamic grants are introduced by approval decisions, session setup, skill
activation, or host adapter callbacks. They can only narrow existing authority.

```scheme
(capability-grant
  (id g-task-replace)
  (parent g-session-buffer-edit)
  (domain host-ui)
  (library (emacs buffer edit))
  (operations (buffer-replace!))
  (scope (buffer (handle buffer h-12))
         (range 120 140))
  (subject (session project-main)
           (task eval-42)
           (skill none))
  (expires after-eval)
  (uses remaining 1)
  (status active)
  (reason "Apply approved region edit."))
```

Attenuation may narrow by:

- domain or operation,
- path, project root, buffer, range, command, destination, provider, or memory
  scope,
- session id, task id, skill identity, or requesting library,
- use count, time, evaluation boundary, session retirement, or explicit
  revocation.

An attenuated grant carries its parent id so audit can show the authority chain.
Revoking a parent makes children unusable unless the child was explicitly
reissued by policy as independent authority.

## Revocation and Stale Handles

Revocation is represented as data and remains inspectable after authority is
removed.

```scheme
(capability-revocation
  (id rev-17)
  (target (grant g-task-replace))
  (status revoked)
  (reason session-retired)
  (revoked-by host-adapter)
  (timestamp "2026-05-20T02:40:00-0700"))
```

Stale handles are failed capability checks, not host exceptions leaked into
Scheme. A stale file, buffer, process, provider stream, port, or session handle
must fail closed before the adapter performs the operation.

```scheme
(capability-decision
  (id dec-stale-17)
  (request req-write-17)
  (status denied)
  (grant g-task-replace)
  (reason stale-handle)
  (condition
    (capability-error
      (kind stale-handle)
      (handle h-12)
      (domain host-ui))))
```

Revocation and stale-handle rules:

- Session retirement revokes after-session grants and releases session-owned
  handles.
- Snapshot and fork preserve handle references as data, then revalidate them
  before registering the new session.
- Grant expiration removes authority but keeps audit history and revocation
  records visible.
- Revalidation occurs before each host operation, not only when the handle is
  created.
- Reusing a stale handle, expired grant, revoked grant, or mismatched scope
  signals an Consent Scheme capability condition and writes a denied audit entry.

## Effect Lowering

Effect lowering is backend-facing. It makes the same capability request visible
to the interpreter, future LLIR paths, native compiler backends, and Emacs Lisp
or byte-code backends.

The frontend keeps pure R7RS syntax independent from host effects. When library
resolution, macro expansion, or normalization reaches an effectful primitive or
host-capability binding, the normalized representation carries an explicit
effect node:

```scheme
(effect-call
  (domain file)
  (operation metadata)
  (library (scheme file))
  (binding file-exists?)
  (arguments ("fixtures/r7rs/conformance-cases.scm"))
  (request-shape
    (capability-request
      (domain file)
      (operation metadata)
      (resource (path "fixtures/r7rs/conformance-cases.scm")))))
```

Interpreter lowering:

- Pure forms are evaluated directly under budgets.
- Effect calls are converted to `capability-request` datums.
- The runtime resolver checks policy, grants, revocation, redaction, and handle
  liveness.
- The host adapter performs the effect only after an allowed decision.
- The interpreter returns the value, result record, event list, or condition
  while preserving audit records as Scheme data.

Compiler lowering:

- The compiler consumes the same normalized effect node or LLIR equivalent.
- Pure calls may be inlined or emitted as ordinary runtime calls when their
  representation is known.
- Effects lower to runtime ABI calls that construct capability requests and
  enter the same resolver used by the interpreter.
- A compiler must not emit direct host filesystem, process, network, provider,
  buffer, or UI calls.
- Unsupported compiled effects remain explicit unsupported-effect nodes until
  the compiled runtime ABI can route them through the shared policy path.
- Compiled results, denied requests, and audit records must remain comparable
  with interpreter result datums.

This boundary lets interpreter and compiler backends differ in execution
strategy without drifting around policy or grant semantics.

## Backend Effect Contract

Primitive manifest records name the backend path that each binding may use.
Pure bindings use `backend-effect-path` value `direct-runtime`; runtime-only
effects such as Scheme mutation, control, parameters, and in-memory ports use
their matching runtime paths. Host-effecting bindings use
`shared-capability-request`, which means no backend may bypass policy by
dispatching directly to a host file, process, network, provider, UI, memory, or
adapter API.

For `shared-capability-request` bindings, interpreter dispatch and compiler
emission both construct the same capability request shape, consult the same
policy category, validate grants and handles, and write comparable audit
records. Compiler emitter hints remain optimization hints only; they do not
authorize effects. If a compiled backend cannot route an effect through this
shared path, it must leave the operation as an explicit unsupported-effect
node or signal a backend capability condition before touching host state.

Backend parity tests should compare interpreter and compiled-backend behavior
for allowed, denied, revoked, and stale capability cases. The shared expectation
is that the value, condition, event list, and audit datums remain comparable
even when the execution strategy differs.

## Session Lifecycle Integration

Fresh, named, and project sessions carry different capability lifetimes:

- Fresh evaluations receive only defaults plus task grants and are collectable
  after the evaluation boundary.
- Named sessions may keep imports, definitions, memory, handles, transcript
  references, and session grants until explicit suspension, snapshot, fork, or
  retirement.
- Project sessions add project roots, project trust, project memory, and
  project policy. Project grants must be revalidated if the project root,
  branch, trust posture, or ignored local state changes.

Session snapshots record grant datums and handle references. They do not copy
live host objects, active jobs, provider streams, approval decisions, or secrets.
Restores and forks rebuild Scheme data first, then revalidate handles, grants,
skill activations, project roots, and provider routing before any effect runs.

## Secrets, Providers, and Disclosure

Provider calls and network effects consume the same environment. Redaction is
not a separate afterthought; it is part of the request and decision path.

```scheme
(capability-request
  (id req-provider-8)
  (domain provider)
  (operation route)
  (provider example-provider)
  (resource (model "example-model"))
  (payload-class remote)
  (requires ((policy remote-provider-routing)
             (redaction safe-for-provider))))
```

Before a provider or network request leaves the host, the adapter must redact
secret-bearing data and deny local-only context unless policy explicitly grants
that disclosure. Audit records store redaction records and provider-safe
summaries, not raw secrets.

## Follow-Up Implementation Issues

This design should be split into smaller implementation issues that can land
independently:

- file capabilities: add first-class file grants, normalized path matching,
  include/load/library-source request datums, symlink escape checks, file audit
  records, and fixture coverage.
- port capabilities: represent host-backed file, process, transcript, provider,
  and virtual ports as capability-derived handles with operation limits and
  stale-handle behavior.
- process capabilities: define command allow-lists, process job handles,
  process-backed ports, environment redaction, confirmation flows, and audit
  outcomes.
- provider capabilities: route model providers and streams through provider
  grants, redaction, local-only disclosure checks, provider audit records, and
  backend-visible effect nodes.

Each follow-up should preserve the same request, decision, revocation, handle,
and audit vocabulary so runtime behavior remains comparable across the Emacs
bootstrap, portable Scheme tests, and future compiler backends.
