# Portable Test Coverage Audit

Issue #659 establishes `tests/scheme/` as the canonical test home for
host-neutral behavior. This audit records why ERT coverage remains where it
does; retaining an ERT test does not make it the semantic source of truth.

## Portable-first coverage

- Reader, evaluator, macro, runtime, standard-library, agent-record, REPL
  contract, and conformance semantics have portable files in `tests/scheme/`.
- SRFI 180 valid JSONTestSuite fixtures, including
  `y_foundationdb_status.json`, JSON Lines, and JSON Text Sequences are
  canonical in `tests/scheme/stdlib-json-reference-test.scm`.
- Shared R7RS and REPL corpora are exercised by both portable and Emacs hosts.

## Justified ERT coverage

- `consent-library-test-srfi-180-reference-*` remains as Emacs-bootstrap
  compatibility, capability-budget, fixture-inventory, invalid-input, and
  `json.el` oracle coverage. The valid and streaming semantics are intentionally
  duplicated only as a compatibility bridge; their portable test is canonical.
- Buffer, window, overlay, interactive command, prompt, and Emacs incremental
  REPL tests exercise host-adapter behavior that R7RS Scheme cannot observe.
- Process launch, executable discovery, compilation, installation, CI YAML,
  repository lint, and packaging tests exercise the build/host boundary.
- Emacs capability adapters retain ERT checks for live buffers, filesystem and
  process callbacks, persistence, approval UI, and native Emacs object
  translation. Portable tests own their Scheme-readable records and pure logic.
- ERT bridge tests for portable hosts remain responsible for tool discovery,
  invoking each `tests/scheme/` file, and attaching host/file names to failures.

New host-neutral ERT-only tests must state the blocking host boundary in their
commentary or link a focused issue that moves the semantics into portable
Scheme.
