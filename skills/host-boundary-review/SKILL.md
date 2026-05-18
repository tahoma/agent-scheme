---
name: agent-scheme-host-boundary-review
description: Use when implementing or reviewing portable core code, Emacs adapter code, host capabilities, policy-gated effects, opaque handles, or Scheme-readable records.
---

# Host-Boundary Review

Use this skill when work touches runtime semantics, portable Scheme modules,
Emacs adapter behavior, capability libraries, policy gates, handles, result
records, persistence, or backend boundaries.

## Canonical References

- `docs/architecture.md`
- `docs/multi-host-bootstrap.md`
- `docs/development.md`
- `docs/naming.md`
- `docs/r7rs-conformance.md`

## Placement Rules

- Portable R7RS semantics, data models, fixtures, and host-neutral helper
  libraries belong under `scheme/`, `fixtures/`, and portable tests.
- Emacs UI, buffers, commands, process integration, policy prompts,
  persistence plumbing, and live-object tables belong under `lisp/`.
- Tests should mirror the implementation surface: Emacs adapter tests in
  `tests/agent-scheme-*-test.el`, portable Scheme tests in `tests/scheme/`
  with an ERT bridge when practical.

## Review Workflow

1. Classify each changed file as portable core, host adapter, test/fixture, or
   documentation. If a file mixes core semantics and host effects, split or
   document the boundary before expanding it.
2. For portable code, check that it does not assume Emacs, a current buffer,
   host files, processes, network, user prompts, or raw host objects.
3. Represent host effects as Scheme-readable requests, policy decisions,
   result records, audit data, or opaque handles before an adapter performs the
   effect.
4. For Emacs adapter code, check that effects are exposed through explicit
   capability libraries and project policy, not through unrestricted host eval
   or raw object leakage.
5. Keep Scheme-visible values printable and inspectable. Raw Emacs objects may
   live in private adapter side tables only behind opaque handles.
6. Keep caches and indexes rebuildable from canonical Scheme-readable data.
7. For semantic changes, update the Emacs Lisp and portable Scheme
   implementations in parallel when practical. If parity cannot land in the
   same change, record the remaining work.

## Verification Questions

- Would the same Scheme program mean the same thing outside Emacs?
- Does every host observation or mutation cross a policy-visible boundary?
- Can a result, memory record, plan, approval, event, or audit entry be printed
  as Scheme-readable data?
- Are public Emacs Lisp names `agent-scheme-` and private internals
  `agent-scheme--`?
- Does `make test` cover the changed boundary, with portable fixtures where
  practical?
