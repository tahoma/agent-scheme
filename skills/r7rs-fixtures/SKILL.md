---
name: consent-r7rs-fixtures
description: Use when adding, reviewing, or triaging R7RS fixture cases, conformance matrix rows, oracle metadata, or local Scheme reference lookups.
---

# R7RS Fixtures

Use this skill when adding or changing shared fixture cases, marking R7RS
coverage, comparing oracle results, or answering Scheme-specific behavior
questions for Consent Scheme.

## Canonical References

- `docs/r7rs-small-report.md`
- `docs/r7rs-conformance.md`
- `docs/development.md`
- `docs/references.md`
- `fixtures/r7rs/conformance-cases.scm`
- `lisp/consent-oracle.el`
- `tests/consent-test-helper.el`
- `tests/consent-conformance-test.el`

## Workflow

1. Start with the local R7RS-small report and the conformance matrix before
   relying on memory or external search.
2. Add or update one representative fixture for each behavior before marking a
   matrix row `implemented`.
3. Keep fixture ids stable, lowercase, and descriptive. Use the shared
   `consent-fixture-suite` in `fixtures/r7rs/conformance-cases.scm`.
4. Include the shared fields:

   ```scheme
   (id stable-case-id)
   (kind r7rs-conformance)
   (phase read-or-read-all-or-expand-or-eval-or-eval-result-or-error)
   (category matrix-category)
   (section "R7RS section")
   (status pending-or-implemented-or-policy-gated-or-unavailable)
   (oracle shared-or-emacs-only-or-portable-only)
   (options ())
   (description "Short behavior description.")
   (source "Scheme source")
   (expect (value "printed result"))
   ```

5. Use `expect (error)` for expected errors and the existing fixture shapes for
   multiple values or larger programs.
6. Add `provenance` metadata when a fixture is inspired by an external test
   suite. Include source location, license location, and a review note saying
   whether the case is an Consent Scheme-owned rewrite or copied material.
7. Add `oracle-eligibility` and `oracle-reason` only when a reference command
   cannot exercise the same language mode or policy model as Consent Scheme.
   Do not use oracle metadata merely to hide implementation disagreement.
8. Update `docs/r7rs-conformance.md` in the same change when a fixture changes
   matrix coverage, status, representative ids, or portability notes.

## Verification

- Run `make test` when a fixture is marked `implemented` or any harness-visible
  fixture shape changes.
- Run `make conformance-oracle` for pure shared cases where reference
  comparison can clarify expected behavior.
- Treat fixtures marked `pending`, `policy-gated`, or `unavailable` as
  shape-checked data that should still stay easy to find and review.
