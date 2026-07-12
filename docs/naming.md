# Naming Convention

Consent Scheme uses a project namespace for durable Emacs Lisp identifiers. The
goal is to make public APIs recognizable as part of Consent Scheme while keeping
personal configuration glue outside the project surface.

## Brand versus identifier

The brand is the two-word **Consent Scheme** (long form "Consent Scheme (CS)",
short form "Consent"); use it in prose, titles, and documentation. Code
identifiers collapse to the single short word `consent` — **not**
`consent-scheme-`. So the Emacs Lisp prefixes are `consent-` / `consent--`, the
Scheme core libraries are `(consent ...)`, the build and environment variables
are `CONSENT_*`, and the binary is `consent`. The distinctive first word carries
the meaning, so the descriptor word "Scheme" never appears in an identifier.

## Public Names

Use `consent-` for public Emacs Lisp commands, functions, variables,
customization options, faces, modes, hooks, and module-level entry points.

Use `consent` for the top-level customization group. Nested groups should
extend the package name, such as `consent-mcp` or `consent-repl`.

Planned user-facing command names include:

- `consent-read`
- `consent-eval`
- `consent-describe-environment`
- `consent-start-repl`
- `consent-mcp-start`
- `consent-mcp-stop`
- `consent-mcp-register-tools`
- `consent-mcp-unregister-tools`

Scheme libraries keep Scheme library names instead of Emacs Lisp package names,
for example `(scheme base)`, `(emacs buffer)`, and `(agent io)`.
Portable implementation libraries under `scheme/consent/` use
`(consent ...)` names, such as `(consent reader)`, when they expose
core Consent Scheme facilities for bootstrapping.

## Private Names

Use `consent--` for private Emacs Lisp internals, including helper
functions, helper macros, internal variables, private structs, and implementation
details that are not supported as public API.

Do not use private names in README examples, user documentation, issue plans, or
tests that describe public behavior.

## Modules

Implementation files under `lisp/` should follow the package namespace:

- `lisp/consent-reader.el` provides `consent-reader`
- `lisp/consent-runtime.el` provides `consent-runtime`
- `lisp/consent-result.el` provides `consent-result`
- `lisp/consent-base.el` provides `consent-base`
- `lisp/consent-library.el` provides `consent-library`
- `lisp/consent-macro.el` provides `consent-macro`
- `lisp/consent-interpreter.el` provides `consent-interpreter`
- `lisp/consent-eval.el` provides `consent-eval`
- `lisp/consent-approval.el` provides `consent-approval`
- `lisp/consent-job.el` provides `consent-job`
- `lisp/consent-task.el` provides `consent-task`
- `lisp/consent-diagnostics.el` provides `consent-diagnostics`
- `lisp/consent-diff.el` provides `consent-diff`
- `lisp/consent-context.el` provides `consent-context`
- `lisp/consent-redaction.el` provides `consent-redaction`
- `lisp/consent-transcript.el` provides `consent-transcript`
- `lisp/consent-mcp.el` provides `consent-mcp`

Tests should mirror the module names, such as
`tests/consent-reader-test.el`.

Portable R7RS implementation files under `scheme/consent/` should mirror
their library names:

- `scheme/consent/reader.sld` defines `(consent reader)`
- `scheme/consent/runtime.sld` defines `(consent runtime)`
- `scheme/consent/base.sld` defines `(consent base)`
- `scheme/consent/library.sld` defines `(consent library)`
- `scheme/consent/macro.sld` defines `(consent macro)`
- `scheme/consent/interpreter.sld` defines `(consent interpreter)`
- `scheme/consent/eval.sld` defines `(consent eval)`
- `scheme/agent/approval.sld` defines `(agent approval)`
- `scheme/agent/job.sld` defines `(agent job)`
- `scheme/agent/context.sld` defines `(agent context)`
- `scheme/agent/redaction.sld` defines `(agent redaction)`
- `scheme/development/testing/harness.sld` defines
  `(development testing harness)`

Here "mirror" means naming and pass-ownership parity, not subordination. Core
semantic changes should update the corresponding Emacs Lisp and portable R7RS
modules and test bridges in the same slice when practical.

Use `.sld` for portable R7RS `define-library` modules. Use `.scm` for Scheme
programs, tests, fixtures, and ordinary source snippets that are loaded or run
as code rather than imported as libraries.

Public Consent Scheme libraries that are not implementation-pass modules may live
under their public namespace, such as `scheme/agent/diff.sld` for `(agent
diff)`, `scheme/agent/diagnostics.sld` for `(agent diagnostics)`, and
`scheme/agent/task.sld` for `(agent task)`, and
`scheme/agent/transcript.sld` for `(agent transcript)`.

Scheme-side tests live under `tests/scheme/`; their ERT bridge files still use
the normal `tests/consent-*-test.el` naming pattern.

If future bootstrap work touches files named `lisp/config-agent*.el`, treat
those files as host-configuration integration. Any durable Consent Scheme API
defined there must still use `consent-` for public names and
`consent--` for private internals. Personal configuration helpers outside
the Consent Scheme subsystem may keep their local naming style, but they should
call Consent Scheme APIs rather than re-exporting them.

## Compatibility

This seed repository does not currently provide compatibility aliases. When a
future migration renames a shipped user-facing command or variable, add an
explicit temporary alias in the same change, mark it obsolete with the normal
Emacs Lisp alias mechanism where possible, and document the planned removal
target.

Do not add compatibility aliases for planned names that never shipped. New docs,
tests, examples, and issue plans should use the project namespace.
