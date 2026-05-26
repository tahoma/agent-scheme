# Helper Libraries and Artifacts

Agent Scheme helper libraries are reusable Scheme source snippets and related
datums captured from interactive work. They sit between transient REPL
definitions and packaged Agent Scheme skills: easy to inspect and reload, but
not automatically trusted package contents.

The public Scheme surface is `(agent helper)`:

```scheme
(import (scheme base)
        (agent helper)
        (agent io)
        (agent memory))

(agent-artifact
 'example
 '(example (source "(double 21)") (expect "42")))

(agent-helper-save!
 '(agent helpers math)
 '((define (double x)
     "Return X multiplied by two."
     (+ x x))))

(agent-helper-load '(agent helpers math))
(double 21)
```

Core procedures:

- `(agent-artifact name datum)` saves and yields a structured artifact.
- `(agent-helper-save! library-name forms)` saves helper source forms.
- `(agent-helper-load library-name)` loads helper forms into the current
  evaluation environment.
- `(agent-helper-list scope)` lists helpers in a storage scope.
- `(agent-helper-promote-to-skill library-name options)` returns a skill
  candidate datum.

## Scopes

Helper storage has three scopes:

- `session-local`: helpers live with the active named REPL session and are
  isolated from other sessions.
- `project-private`: helpers are stored in private local state keyed by the
  project root. This is the default outside a named session and does not create
  tracked files in the repository.
- `project-tracked`: helpers are written under `.agent-scheme/helpers/` only
  after the `helper-tracked-write` policy gate approves the write.

Session-local and project-private helpers are suitable for exploratory probes,
short reusable functions, and task-specific workflow snippets. Project-tracked
helpers are for code the user has explicitly chosen to make part of the
repository.

## Datums

Helper records are ordinary Scheme-readable data:

```scheme
(agent-helper-library
  (name (agent helpers math))
  (scope project-private)
  (forms ((define (double x)
            "Return X multiplied by two."
            (+ x x))))
  (source (project-root "/project/"))
  (created-at 1)
  (updated-at 1))
```

Artifacts use the same inspectable style:

```scheme
(agent-artifact
  (name example)
  (scope project-private)
  (value (example (source "(double 21)") (expect "42")))
  (source (project-root "/project/"))
  (created-at 2)
  (updated-at 2))
```

`agent-artifact` yields the artifact through `(agent io)` so a helper script can
return examples, templates, reference datums, probes, or self-test candidates
for review. Saving a helper also records a summary through `(agent memory)` with
`(tags (helper library))`, so later queries can recover why the helper exists
and where it came from.

## Skill Candidates

Mature helpers can be promoted without writing package files:

```scheme
(agent-helper-promote-to-skill
 '(agent helpers math)
 '((name "math-helper")
   (examples ((double-example (source "(double 21)") (expect "42"))))
   (references ((r7rs "docs/r7rs-small-report.md")))
   (tests (((source "(double 21)") (expect "42"))))))
```

The result is an `agent-skill-candidate` datum. It can include examples,
references, tests, resources, and a `SKILL.scm` payload suitable for later
native skill packaging. Writing candidate files is separate and uses the
`helper-skill-candidate-write` policy gate.

## Self-Tests

Helpers and skills can use `(agent test)` for lightweight checks that run in the
same Scheme session as the helper code. Results are Scheme-readable datums with
`pass`, `fail`, `error`, `skipped`, and `budget-exhausted` statuses.

A helper library can load its forms and run tests from the REPL without Emacs
batch test execution:

```scheme
(import (scheme base)
        (agent helper)
        (agent test))

(agent-helper-save!
 '(agent helpers math)
 '((define (double x)
     "Return X multiplied by two."
     (+ x x))))

(agent-helper-load '(agent helpers math))

(test-run
 (test-group '(agent helpers math)
   (test-case 'double-small (double 21) 42)
   (test-error 'double-type-error
               (error "expected number" 'double)
               error-object?)))
```

Native skill manifests and exported skill packages can carry source tests as
datums. `skill-test-run` evaluates those source strings through normal Agent
Scheme evaluation, so the usual sandbox policy and budget limits still apply:

```scheme
(import (scheme base)
        (agent test))

(define skill
  '(agent-skill
    (name "math-helper")
    (tests (((name double-source)
             (source "(import (scheme base)) (+ 21 21)")
             (expect "42")
             (options ((max-steps 200))))))))

(skill-test-run skill)
```

Vendored SRFI 64-style results can be adapted into the same result shape. This
keeps SRFI compatibility at the reporting layer now, while leaving SRFI 252
property testing for a later compatibility layer:

```scheme
(import (scheme base)
        (agent test))

(skill-test
 'vendored-srfi
 '(srfi-64
   (test-name append-empty)
   (result pass)
   (expected (1 2))
   (actual (1 2))))

(skill-test-run 'vendored-srfi)
```

Failed results can be yielded back to the agent:

```scheme
(import (scheme base)
        (agent io)
        (agent test))

(test-yield-failures
 (test-group 'math
   (test-case 'wrong-sum (+ 1 1) 3)))
```

## Boundaries

Helper libraries differ from R7RS standard libraries. R7RS standard libraries
such as `(scheme base)` and `(scheme write)` define the language contract and
must remain portable and stable. Helper libraries are user or agent-authored
source records that can be saved, loaded, replaced, or promoted as project
workflow material.

Helper libraries differ from Emacs capability libraries. Emacs capability
libraries expose host observations or mutations through handles, policy, and
audit records. Helpers may call capability procedures that are already imported
and approved, but helper storage itself does not grant buffer, file, process,
network, or VCS authority.

Helper libraries differ from packaged Agent Scheme skills. Packaged skills are
explicit bundles with `SKILL.md`, optional `SKILL.scm`, references, tests, and
assets. A helper-promoted skill candidate is only a candidate datum until a
separate export or packaging workflow writes files and trust policy accepts the
package.
