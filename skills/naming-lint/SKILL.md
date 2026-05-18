---
name: agent-scheme-naming-lint
description: Use when adding or reviewing public names, private internals, module names, test names, Scheme library names, or documentation examples.
---

# Naming Lint

Use this skill when changing Emacs Lisp identifiers, Scheme library names,
module/test files, public documentation examples, or issue and pull request
text that names project APIs.

## Canonical References

- `docs/naming.md`
- `docs/contributing.md`
- `docs/development.md`
- `AGENTS.md`

## Rules

- Public Emacs Lisp commands, functions, variables, groups, faces, modes, and
  module entry points use `agent-scheme-`.
- Private Emacs Lisp helpers, macros, structs, variables, and implementation
  details use `agent-scheme--`.
- The top-level customization group is `agent-scheme`; nested groups extend the
  package name, such as `agent-scheme-mcp`.
- Scheme libraries use Scheme names such as `(scheme base)`, `(emacs buffer)`,
  `(agent io)`, or portable implementation names under `(agent-scheme ...)`.
- `lisp/agent-scheme-foo.el` provides `agent-scheme-foo`.
- `tests/agent-scheme-foo-test.el` mirrors the implementation module.
- `scheme/agent-scheme/foo.sld` defines `(agent-scheme foo)`.
- Do not use private names in README examples, user docs, issue plans, or tests
  that describe public behavior.
- Keep assistant, tool, vendor, and workflow branding out of branch names,
  commit messages, pull request titles, issue text, docs, tests, and generated
  artifacts.

## Deterministic Checks

Run the repository documentation private-history scan:

```sh
rg -n "m[y]/agent-scheme|m[y]/mcp" README.md docs
```

When skill files changed, scan them too:

```sh
rg -n "m[y]/agent-scheme|m[y]/mcp" skills
```

Check for private Emacs Lisp names leaking into public docs. The command
excludes the canonical rule documents and the skills that explain the rule.

```sh
rg -n "\\bagent-scheme--" README.md docs skills -g '!docs/naming.md' -g '!docs/architecture.md' -g '!skills/host-boundary-review/SKILL.md' -g '!skills/naming-lint/SKILL.md'
```

List Emacs Lisp definitions for manual namespace review:

```sh
rg -n "\\((defun|defmacro|defcustom|defvar|defconst|defgroup|defface|cl-defstruct|define-minor-mode|define-derived-mode)\\s+" lisp tests
```

List Scheme library definitions and test file names for mirror checks:

```sh
rg -n "\\(define-library \\(" scheme tests/scheme
rg --files lisp tests scheme/agent-scheme
```

## Review Workflow

1. Run the deterministic checks that apply to the changed files.
2. Compare new names against `docs/naming.md`.
3. Treat public examples as API promises. Prefer public `agent-scheme-` names
   there and keep private `agent-scheme--` names in implementation tests only.
4. For any intentional exception, document the reason in the change or pull
   request rather than leaving the naming rule ambiguous.
