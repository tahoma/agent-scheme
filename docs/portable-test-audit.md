# Portable Test Coverage Audit

Issue #659 establishes `tests/scheme/` as the canonical test home for
host-neutral behavior. This audit records why ERT coverage remains where it
does; retaining an ERT test does not make it the semantic source of truth.

## Migrated semantic suites

- Reader, evaluator, macro, runtime, standard-library, agent-record, REPL
  contract, and conformance semantics have canonical files in `tests/scheme/`.
- The pure `(agent context)`, `(agent plan)`, `(agent redaction)`, `(agent
  task)`, and `(agent vcs)` datum/parser suites run under SRFI 64 across the
  direct portable host matrix. Their ERT counterparts remain only to preserve
  Emacs-bootstrap import, primitive-adapter, audit, session, buffer, process,
  and policy coverage.
- SRFI 180 valid JSONTestSuite fixtures, including
  `y_foundationdb_status.json`, JSON Lines, and JSON Text Sequences are
  canonical in `tests/scheme/stdlib-json-reference-test.scm`.
- Shared R7RS and REPL corpora are exercised by both portable and Emacs hosts.

## Justified ERT coverage

- `consent-library-test-srfi-180-reference-*` remains as Emacs-bootstrap
  compatibility, capability-budget, fixture-inventory, invalid-input, and
  `json.el` oracle coverage. Portable Scheme owns valid and streaming semantics;
  ERT owns the Emacs evaluator's capability-backed file-port path and oracle.
- Buffer, window, overlay, interactive command, prompt, and Emacs incremental
  REPL tests exercise host-adapter behavior that R7RS Scheme cannot observe.
- Process launch, executable discovery, compilation, installation, CI YAML,
  repository lint, and packaging tests exercise the build/host boundary.
- Emacs capability adapters retain ERT checks for live buffers, filesystem and
  process callbacks, persistence, approval UI, and native Emacs object
  translation. Portable tests own their Scheme-readable records and pure logic.
- ERT bridge tests for portable hosts remain responsible for tool discovery,
  invoking each `tests/scheme/` file, and attaching host/file names to failures.

The audit groups the remaining ERT files by the boundary they exercise:

| ERT surface | Canonical portable coverage or reason retained |
| --- | --- |
| `consent-base`, `consent-budget`, `consent-eval`, `consent-macro`, `consent-reader`, `consent-result`, and `consent-runtime` | `consent-reader-test.scm`, `consent-eval-test.scm`, shared fixtures, and parity tests own language semantics; ERT retains the Emacs evaluator and bootstrap realization. |
| `consent-agent-*`, `consent-context`, `consent-memory`, `consent-models`, `consent-plan`, `consent-redaction`, `consent-session`, `consent-task`, `consent-transcript`, and `consent-vcs` | Source-backed datum and pure-library behavior is covered by the corresponding portable agent suites, including the five suites migrated in this issue; ERT retains primitive adapters, audit effects, persistence, live buffers, processes, and policy gates. |
| `consent-capability`, `consent-network`, `consent-approval`, `consent-job`, `consent-repl-comint`, and `consent-repl-stream` | These tests exercise Emacs buffers, processes, callbacks, prompts, transport fakes, grants, or interactive session state and therefore remain host-adapter tests. |
| `consent-library`, `consent-compile-*`, `consent-ci`, `consent-smoke`, and module/ownership tests | These validate manifest discovery from the Emacs bootstrap, compilation, packaging, repository layout, CI configuration, and executable discovery rather than host-neutral library semantics. |
| `*-doc-test`, Scheme documentation lint, and branding/style tests | These inspect checked-in documentation and source conventions using repository tooling; they are build-policy tests, not Scheme runtime semantics. |

Portable files predating this issue may still contain local failure counters.
That is a Scheme-harness consistency concern rather than missing portable
semantic coverage. New and migrated semantic suites use SRFI 64 and
`(development testing harness)`; #883 tracks mechanical conversion of those
older portable files without moving their assertions back through ERT.

New host-neutral ERT-only tests must state the blocking host boundary in their
commentary or link a focused issue that moves the semantics into portable
Scheme.

## ERT capability comparison

The portable stack is feature-compatible with ERT for semantic assertions,
but it is not yet feature-compatible as a complete developer-facing runner.
The distinction keeps test semantics portable without overstating the current
command-line experience.

| Capability | Portable facility | Status versus ERT |
| --- | --- | --- |
| truth, equality, approximate, and error assertions | SRFI 64 `(stdlib testing)` | parity |
| named groups and cleanup | SRFI 64 `test-group` and `test-group-with-cleanup` | parity |
| skip and expected failure | SRFI 64 runner directives | parity |
| generated/property assertions | SRFI 252 plus SRFI 158/194 generators | exceeds ERT core |
| table/comprehension assertions | SRFI 78 plus SRFI 42 | exceeds ERT core |
| actual/expected values and arbitrary result properties | SRFI 64 result alists | parity, though source locations are not automatically captured |
| deterministic batch failure and summary receipts | `(development testing harness)` over SRFI 64 | parity for CI; Scheme-readable receipts exceed ERT's text-only batch contract |
| test discovery, selectors, tags, and selective reruns | files are selected by the host bridge | partial; there is no Scheme-native test registry yet |
| automatic source locations, backtraces, and per-test timing | host diagnostics only | gap |
| interactive failed-test inspection and rerun | ERT remains the Emacs UI | intentional host-UI gap |

`(development testing harness)` is a test-only orchestration extension, not another
assertion framework. `consent-test-run` supplies the repeated SRFI 64 lifecycle,
machine-readable summary datum, and nonzero host exit on unexpected failure or
success. `consent-test-check` adapts silent SRFI 78 checks into one named SRFI
64 result. Test bodies continue to use the SRFI forms directly. The library
lives in the manifested `scheme/development/testing/` namespace so it is
available to downstream users. The executable suites and cases under
`tests/scheme/` remain outside runtime manifests. Further libraries in the
development testing namespace must be named for the missing test facility they
provide; `(stdlib ...)` remains reserved for the portable standards shelf.

The next useful runner extension is a Scheme-native registry carrying test
name, tags, source metadata, and a thunk. That would close selector and rerun
parity while preserving SRFI 64 as the result engine. Backtraces and interactive
inspection should remain host adapters because R7RS does not standardize either
facility.
