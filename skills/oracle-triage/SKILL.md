---
name: consent-oracle-triage
description: Use when running or interpreting make conformance-oracle, selecting reference Scheme implementations, or deciding whether oracle output is a conformance signal.
---

# Oracle Triage

Use this skill when `make conformance-oracle` output changes, a fixture needs
reference comparison, or a report must be classified as a conformance problem
or a portability note.

## Canonical References

- `docs/development.md`
- `docs/r7rs-conformance.md`
- `docs/r7rs-small-report.md`
- `lisp/consent-oracle.el`
- `tests/consent-oracle-test.el`

## Commands

Run the default oracle:

```sh
make conformance-oracle
```

Focus on selected report statuses:

```sh
CONSENT_ORACLE_STATUSES='agent-mismatch,implementation-variant' make conformance-oracle
```

Select reference implementations:

```sh
CONSENT_ORACLE_REFERENCES='chibi,gauche,guile,sagittarius,racket,chicken' make conformance-oracle
```

Print a compact count before the report stream:

```sh
CONSENT_ORACLE_SUMMARY=1 make conformance-oracle
```

## Status Triage

- `portable-agree`: Consent Scheme and the selected references agree. No action
  unless the fixture itself is wrong.
- `implementation-variant`: supported references differ and Consent Scheme
  matches at least one. Treat this as a visible portability note unless the
  local R7RS report or conformance matrix says the behavior is fixed.
- `agent-mismatch`: Consent Scheme disagrees with all selected references for an
  eligible case. Treat this as a conformance signal and inspect the fixture,
  expected result, local R7RS text, and implementation.
- `unsupported-reference`: a selected reference command is unavailable or
  cannot run. Treat this as local environment information, not a product
  failure.
- `policy-gated`: the case crosses Consent Scheme host policy, such as file,
  process, time, load, REPL, or host-backed port access. Keep the policy reason
  visible.
- `not-oracle-eligible`: the reference command cannot exercise the same mode or
  the case is Consent Scheme-specific. Check that the fixture explains why.

## Workflow

1. Confirm the fixture `oracle`, `oracle-eligibility`, and `oracle-reason`
   fields before changing expected output.
2. Compare against the local R7RS-small report first. Use external references
   from `docs/references.md` only when the local report or matrix is
   insufficient.
3. If a mismatch is real, add or adjust the smallest fixture and implementation
   change that captures the behavior.
4. If the result is an implementation variant, document the portability note in
   `docs/r7rs-conformance.md` instead of normalizing away semantic differences.
5. Keep missing optional reference implementations out of `make test` failures.
