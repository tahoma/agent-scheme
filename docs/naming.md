# Naming Convention

Agent Scheme uses a project namespace for durable Emacs Lisp identifiers. The
goal is to make public APIs recognizable as part of Agent Scheme while keeping
personal configuration glue outside the project surface.

## Public Names

Use `agent-scheme-` for public Emacs Lisp commands, functions, variables,
customization options, faces, modes, hooks, and module-level entry points.

Use `agent-scheme` for the top-level customization group. Nested groups should
extend the package name, such as `agent-scheme-mcp` or `agent-scheme-repl`.

Planned user-facing command names include:

- `agent-scheme-read`
- `agent-scheme-eval`
- `agent-scheme-describe-environment`
- `agent-scheme-start-repl`
- `agent-scheme-mcp-start`
- `agent-scheme-mcp-stop`
- `agent-scheme-mcp-register-tools`
- `agent-scheme-mcp-unregister-tools`

Scheme libraries keep Scheme library names instead of Emacs Lisp package names,
for example `(scheme base)`, `(emacs buffer)`, and `(agent io)`.
Portable implementation libraries under `scheme/agent-scheme/` use
`(agent-scheme ...)` names, such as `(agent-scheme reader)`, when they expose
core Agent Scheme facilities for bootstrapping.

## Private Names

Use `agent-scheme--` for private Emacs Lisp internals, including helper
functions, helper macros, internal variables, private structs, and implementation
details that are not supported as public API.

Do not use private names in README examples, user documentation, issue plans, or
tests that describe public behavior.

## Modules

Implementation files under `lisp/` should follow the package namespace:

- `lisp/agent-scheme-reader.el` provides `agent-scheme-reader`
- `lisp/agent-scheme-runtime.el` provides `agent-scheme-runtime`
- `lisp/agent-scheme-result.el` provides `agent-scheme-result`
- `lisp/agent-scheme-base.el` provides `agent-scheme-base`
- `lisp/agent-scheme-library.el` provides `agent-scheme-library`
- `lisp/agent-scheme-macro.el` provides `agent-scheme-macro`
- `lisp/agent-scheme-interpreter.el` provides `agent-scheme-interpreter`
- `lisp/agent-scheme-eval.el` provides `agent-scheme-eval`
- `lisp/agent-scheme-approval.el` provides `agent-scheme-approval`
- `lisp/agent-scheme-diff.el` provides `agent-scheme-diff`
- `lisp/agent-scheme-redaction.el` provides `agent-scheme-redaction`
- `lisp/agent-scheme-mcp.el` provides `agent-scheme-mcp`

Tests should mirror the module names, such as
`tests/agent-scheme-reader-test.el`.

Portable R7RS implementation files under `scheme/agent-scheme/` should mirror
their library names:

- `scheme/agent-scheme/reader.sld` defines `(agent-scheme reader)`
- `scheme/agent-scheme/runtime.sld` defines `(agent-scheme runtime)`
- `scheme/agent-scheme/base.sld` defines `(agent-scheme base)`
- `scheme/agent-scheme/library.sld` defines `(agent-scheme library)`
- `scheme/agent-scheme/macro.sld` defines `(agent-scheme macro)`
- `scheme/agent-scheme/interpreter.sld` defines `(agent-scheme interpreter)`
- `scheme/agent-scheme/eval.sld` defines `(agent-scheme eval)`
- `scheme/agent-scheme/approval.sld` defines `(agent-scheme approval)`
- `scheme/agent-scheme/redaction.sld` defines `(agent-scheme redaction)`

Here "mirror" means naming and pass-ownership parity, not subordination. Core
semantic changes should update the corresponding Emacs Lisp and portable R7RS
modules and test bridges in the same slice when practical.

Use `.sld` for portable R7RS `define-library` modules. Use `.scm` for Scheme
programs, tests, fixtures, and ordinary source snippets that are loaded or run
as code rather than imported as libraries.

Public Agent Scheme libraries that are not implementation-pass modules may live
under their public namespace, such as `scheme/agent/diff.sld` for `(agent
diff)`.

Scheme-side tests live under `tests/scheme/`; their ERT bridge files still use
the normal `tests/agent-scheme-*-test.el` naming pattern.

If future bootstrap work touches files named `lisp/config-agent*.el`, treat
those files as host-configuration integration. Any durable Agent Scheme API
defined there must still use `agent-scheme-` for public names and
`agent-scheme--` for private internals. Personal configuration helpers outside
the Agent Scheme subsystem may keep their local naming style, but they should
call Agent Scheme APIs rather than re-exporting them.

## Compatibility

This seed repository does not currently provide compatibility aliases. When a
future migration renames a shipped user-facing command or variable, add an
explicit temporary alias in the same change, mark it obsolete with the normal
Emacs Lisp alias mechanism where possible, and document the planned removal
target.

Do not add compatibility aliases for planned names that never shipped. New docs,
tests, examples, and issue plans should use the project namespace.
