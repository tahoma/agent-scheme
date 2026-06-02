# R7RS Implementation Test Mining

This report records the first issue #94 pass over external R7RS and near-R7RS
test material. The goal is coverage discovery, not vendoring. New Consent Scheme
fixtures from this pass are small rewrites owned by this repository, with
fixture-level provenance notes and no copied third-party test text.

## Review Posture

- Treat external tests as a checklist for coverage gaps, edge classes, and
  implementation disagreements.
- Do not import, vendor, or closely adapt external test text unless a future
  change records the exact license obligations and attribution plan.
- Prefer pure, portable R7RS-small cases that can run through `make test` and
  the oracle runner.
- Mark host effects, unspecified behavior, implementation extensions, and
  reference disagreements explicitly instead of turning them into broad
  conformance claims.

## Reviewed Sources

| Source | Locations reviewed | License posture | Useful coverage | Rejected or deferred areas |
| --- | --- | --- | --- | --- |
| Chibi Scheme | [`tests/r7rs-tests.scm`](https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm), [`tests/lib-tests.scm`](https://github.com/ashinn/chibi-scheme/blob/master/tests/lib-tests.scm), [`tests/syntax-tests.scm`](https://github.com/ashinn/chibi-scheme/blob/master/tests/syntax-tests.scm), [`tests/division-tests.scm`](https://github.com/ashinn/chibi-scheme/blob/master/tests/division-tests.scm) | [`COPYING`](https://github.com/ashinn/chibi-scheme/blob/master/COPYING) is BSD-style. Rewrites only in this pass. | Broad R7RS-small surface, exact arithmetic, `letrec-syntax`, library imports, in-memory ports, exception shape. | Bulk suite import, full Unicode assumptions, host-time/file/process tests, and cases whose expected printer spelling is implementation-specific. |
| Gauche | [`tests/symkey.scm`](https://github.com/shirok/Gauche/blob/master/tests/symkey.scm), [`tests/symcase.scm`](https://github.com/shirok/Gauche/blob/master/tests/symcase.scm), [`tests/number.scm`](https://github.com/shirok/Gauche/blob/master/tests/number.scm), [`tests/io.scm`](https://github.com/shirok/Gauche/blob/master/tests/io.scm), [`tests/continuation.scm`](https://github.com/shirok/Gauche/blob/master/tests/continuation.scm), [`tests/error.scm`](https://github.com/shirok/Gauche/blob/master/tests/error.scm) | [`COPYING`](https://github.com/shirok/Gauche/blob/master/COPYING) says revised BSD for Gauche with additional bundled notices. Rewrites only in this pass. | Reader edge cases, symbol case, ports, numeric behavior, continuations, error handling. | Gauche module/object/thread extensions, performance tests, host filesystem/process tests, and implementation-specific diagnostics. |
| Sagittarius Scheme | [`test/r7rs-tests`](https://github.com/ktakashi/sagittarius-scheme/tree/master/test/r7rs-tests), [`test/tests.scm`](https://github.com/ktakashi/sagittarius-scheme/blob/master/test/tests.scm) | [`COPYING`](https://github.com/ktakashi/sagittarius-scheme/blob/master/COPYING) says the main source is 2-clause BSD with bundled notices. No fixture in this pass directly relies on Sagittarius test text. | Cross-checking R7RS mode expectations and oracle-reference diversity. | R6RS-oriented tests, Sagittarius libraries, FFI, crypto, and implementation-specific runtime behavior. |
| Cyclone Scheme | [`tests/base.scm`](https://github.com/justinethier/cyclone/blob/master/tests/base.scm), [`tests/bytevector-tests.scm`](https://github.com/justinethier/cyclone/blob/master/tests/bytevector-tests.scm), [`tests/macro-hygiene.scm`](https://github.com/justinethier/cyclone/blob/master/tests/macro-hygiene.scm), [`tests/let-syntax-298.scm`](https://github.com/justinethier/cyclone/blob/master/tests/let-syntax-298.scm) | [`LICENSE`](https://github.com/justinethier/cyclone/blob/master/LICENSE) is MIT. Rewrites only in this pass. | Macro hygiene, bytevectors, base-library smoke coverage, regression-style small files. | Compiler/runtime integration tests, non-R7RS libraries, C interop, and Cyclone-specific regressions. |
| Racket R7RS | [`r7rs-test/tests`](https://github.com/lexi-lambda/racket-r7rs/tree/master/r7rs-test/tests), [`r7rs-lib`](https://github.com/lexi-lambda/racket-r7rs/tree/master/r7rs-lib) | GitHub did not report repository license metadata and no top-level license file was found in this pass. Use as orientation only until clarified. | Import semantics, Racket-hosted R7RS package shape, library loading expectations. | Direct fixture adaptation, because license status needs follow-up. |
| Gambit | [`tests/r4rstest.scm`](https://github.com/gambit/gambit/blob/master/tests/r4rstest.scm), [`tests/error.scm`](https://github.com/gambit/gambit/blob/master/tests/error.scm), [`tests/mix.scm`](https://github.com/gambit/gambit/blob/master/tests/mix.scm) | GitHub did not report repository license metadata and no root `LICENSE` or `COPYING` file was found in this pass; reviewed test files include license headers such as GPLv2+ on `r4rstest.scm`. Use as orientation only until clarified. | Older report regression coverage, error behavior, stress-style mixed tests. | Direct fixture adaptation, R4RS/R5RS-only expectations, implementation-specific runtime behavior. |
| Portable standalone R7RS suite | [`r7rs-tests.scm`](https://gitea.scheme.org/Retropikzel/r7rs-tests/src/commit/049937d6bcf87277e61c3f2e2619e3764d4ae281/r7rs-tests.scm) | No license file or header was identified during this pass. Use only as a coverage checklist until clarified. | Broad standard-section ordering and procedure checklist. | Direct adaptation, because license status is unclear. |

## Selected Rewrites

| Fixture | Coverage area | External inspiration |
| --- | --- | --- |
| `reader-escaped-identifier` | Reader syntax for vertical-bar identifiers and hex escapes | Chibi reader coverage and Gauche symbol case tests. |
| `numeric-exact-integer-sqrt-large` | Numeric tower exact integer square root on a large exact value | Chibi exact arithmetic cases. |
| `syntax-rules-letrec-recursive-or` | Recursive `letrec-syntax` expansion and hygiene of introduced temporaries | Chibi macro coverage. |
| `library-import-modifiers-composed` | Composition of `only`, `rename`, and `prefix` import modifiers | Chibi library tests and Racket R7RS import organization. |
| `exceptions-error-object-accessors` | `guard` clauses over `error-object?`, message, and irritants | Gauche error tests and Chibi exception coverage. |
| `continuations-higher-order-escape` | `call/cc` escape from inside a higher-order traversal | Gauche continuation tests and Chibi control coverage. |
| `standard-library-read-write-roundtrip` | In-memory textual port write/read round trip | Chibi R7RS I/O coverage and Gauche I/O tests. |

All selected cases are implemented fixtures with `oracle shared`; the local
oracle runner can classify reference diversity separately from `make test`.

## Follow-Up Candidates

- Add a license-review issue before any direct adaptation from Racket R7RS,
  Gambit, or the standalone portable R7RS suite.
- Expand numeric variation notes around exactness, infinities, NaNs, and
  implementation-dependent printer spelling after reviewing oracle output across
  Chibi, Sagittarius, Gauche, Guile, Racket, and CHICKEN.
- Mine library-loading behavior separately from pure imports, because include,
  load, file, process-context, repl, and time remain Consent Scheme policy-gated.
- Consider adding pending fixtures for unspecified behavior only when the matrix
  explicitly labels them as portability notes rather than conformance facts.
