# R7RS-Small Conformance Matrix

This matrix is the source of truth for Agent Scheme's R7RS-small surface. Use
the local [R7RS-small report reference](r7rs-small-report.md) for the underlying
language text. This matrix tracks the language features, standard libraries, and
representative fixture cases that should move from `pending` to `implemented`
or `policy-gated` as the runtime lands.

Fixture cases live in the shared `agent-scheme-fixture-suite` at
`fixtures/r7rs/conformance-cases.scm`. The initial external implementation
mining report lives in [R7RS Implementation Test Mining](r7rs-implementation-mining.md).
The ERT harness in
`tests/agent-scheme-conformance-test.el` filters that corpus to
`kind r7rs-conformance`, validates every conformance fixture, and runs cases
marked `implemented`.

`make conformance-oracle` runs a separate reference implementation oracle over
pure shared fixtures. The default adapters target Chibi Scheme through
`AGENT_SCHEME_CHIBI` or `chibi-scheme` on `PATH` and Sagittarius through
`AGENT_SCHEME_SAGITTARIUS` or `sagittarius` on `PATH`; missing references are
reported as `unsupported-reference` without affecting `make test`. Gauche and
Guile adapters can be selected with `AGENT_SCHEME_ORACLE_REFERENCES` when
comparing candidate reference sets. Racket can also be selected as a developer
comparison adapter when `racket` and the Racket `r7rs` package are installed;
CHICKEN can be selected the same way when `csi` and the `r7rs` egg are
installed. Gambit can be selected when `gsi` is available; the adapter runs
`gsi -:r7rs,search=$REPO/scheme`, and the Gambit-native compile shard preserves
that same R7RS library search behavior. Cyclone can be selected as a tertiary
adapter when `icyc` is available; the adapter runs generated programs with
`icyc -I $REPO/scheme -s` and leaves any `cyclone` compiler target to later
host-compiled executable work.

Oracle `implementation-variant` rows are expected to stay visible when they
reflect genuine reference diversity, such as exactness choices, case-folding
quirks, datum-label support, bytevector port optional-argument behavior, or
library-loading behavior. They are not Agent Scheme failures unless the report
status is `agent-mismatch`.

## Status Values

| Status | Meaning |
| --- | --- |
| `pending` | Required R7RS behavior that Agent Scheme has not implemented yet. |
| `implemented` | Behavior implemented by Agent Scheme and exercised by `make test`. |
| `policy-gated` | Required behavior whose host effects must pass Agent Scheme policy before use. The Scheme semantics still need conformance tests. |
| `unavailable` | Intentionally unavailable only where R7RS permits an implementation to omit or reject the behavior. No current row uses this status. |

## Classification Notes

Some issue #95 classifications are not fixture `status` values:

- `unspecified` is recorded with fixture oracle metadata when an expectation is
  intentionally not portable across R7RS implementations.
- `implementation-variant` is an oracle report status, not an Agent Scheme
  fixture status; it means supported references disagree while Agent Scheme
  still matches at least one reference.
- `agent-specific` is a fixture `kind` for harness behavior, result records,
  and resource-limit checks outside the portable R7RS conformance slice.

## Section Coverage Audit

| R7RS-small section area | Representative shared coverage | Remaining thin areas |
| --- | --- | --- |
| 2.1-2.4 lexical conventions | Identifiers, escaped identifiers, fold and no-fold case directives, line/block/datum comments, boolean alternatives, datum labels | Additional negative lexical grammar cases can still be mined, especially around delimiter-sensitive tokens and unsupported datum-label positions. |
| 3.1-3.5 basic concepts | Lexical scope, binding regions, mutation, datum external representations, circular equality, and proper tail recursion | Disjointness and storage-model checks are covered through representative type operations rather than an exhaustive cross-product. |
| 4.1 primitive expressions | Procedure calls, lambdas, assignment, conditionals, quoted data, and policy-denied include forms | Literal immutability and unspecified results are deliberately thin because portable expectations are implementation-dependent. |
| 4.2 derived expressions | Conditionals, binding forms, `do`, lazy forcing, `parameterize`, exception guards, quasiquote, and `case-lambda` | Existing fixtures are representative; more malformed derived syntax can be added as the expander diagnostics settle. |
| 4.3 macros | Top-level and local `syntax-rules`, hygiene, literals, dotted patterns/templates, nested and custom ellipses, `syntax-error`, malformed ellipsis use | Further literal-shadowing and macro error-shape variants would improve diagnostic coverage without changing semantics. |
| 5.1-5.6 programs and libraries | Program import ordering, import modifiers, exported bindings and macros, `cond-expand`, duplicate exports, `include`, and `include-ci` default denial | Policy-allowed include/include-ci execution is covered by unit tests; conformance fixtures keep host file access classified at the policy boundary. |
| 6.1-6.9 core datums and numbers | Equivalence, booleans, pairs/lists, symbols, characters, strings, vectors, bytevectors, exact/inexact numeric operations, radix I/O, rationalization, infinities, NaNs, complex numbers | Unicode breadth, `eqv?` edge cases, and numeric branch cuts remain intentionally representative rather than exhaustive. |
| 6.10-6.11 control and exceptions | Higher-order calls, multiple values, continuations, repeated continuation invocation, `dynamic-wind`, guards, continuable raises, error objects, exception unwinding | Continuation and exception interaction is now represented, but not exhaustively combined with every multiple-value context. |
| 6.12-6.14 eval, I/O, and system interface | Explicit eval environments, session-gated interaction environments, in-memory textual and binary ports, read/write round trips, EOF objects, default host port policy, file/process/time/repl policy gates | Host-backed ports and system effects remain policy-gated; oracle eligibility marks cases that reference implementations cannot exercise under the same policy model. |
| 7.1-7.3 formal syntax and semantics | Formal grammar sections are mapped back to reader, expression, transformer, program, library, and derived-expression fixtures above | The formal denotational semantics in 7.2 is reference material, not a separate executable fixture target. |

## Language Features

| Area | R7RS-small coverage | Status | Representative fixtures | Notes |
| --- | --- | --- | --- | --- |
| Reader syntax | Comments, case directives, booleans, numbers, characters, strings, symbols, lists, dotted pairs, abbreviations, vectors, bytevectors, datum comments, datum labels | `implemented` | `reader-boolean-literals`, `reader-long-boolean-literal`, `reader-bytevector-literal`, `reader-bytevector-byte-range-error`, `reader-character-literal`, `reader-symbol-case-directive`, `reader-no-fold-case-directive`, `reader-string-line-continuation`, `reader-number-radix-prefix`, `reader-dotted-list`, `reader-vector-literal`, `reader-abbreviation-forms`, `reader-comments-and-datum-comments`, `reader-escaped-identifier`, `reader-datum-label-cycle` | First-pass reader datums, including escaped identifiers, string continuations, radix prefixes, bytevector range errors, and shared and circular datum labels, are implemented and fixture-loaded with Agent Scheme's reader. |
| Primitive expressions | Literal, variable reference, quote, procedure call, `if`, `set!`, `lambda` | `implemented` | `primitive-procedure-call` | Emacs Lisp and portable R7RS evaluator kernels cover explicit lexical environments, closures, mutation, and primitive calls. |
| Definitions and sequencing | `define`, `define-values`, `begin`, internal definitions | `implemented` | `primitive-procedure-call`, `multiple-values-define-values` | Top-level and internal definitions are supported, including `define-values`. |
| Derived syntax | `cond`, `case`, `and`, `or`, `when`, `unless`, `let`, `let*`, `letrec`, `letrec*`, `let-values`, `let*-values`, `do`, `delay`, `quasiquote`, `parameterize` | `implemented` | `derived-let-expression`, `derived-cond-arrow-literal-binding`, `derived-case-expression`, `derived-do-expression`, `derived-quasiquote-expression`, `standard-library-lazy-force` | Macro-expanded derived syntax and evaluator-supported forms cover the R7RS-small initial target, including dynamic parameter rebinding through `parameterize`. |
| `syntax-rules` macros | `define-syntax`, `let-syntax`, `letrec-syntax`, literals, ellipses, hygiene | `implemented` | `syntax-rules-unless`, `syntax-rules-let-syntax-hygiene`, `syntax-rules-letrec-recursive-or`, `syntax-rules-dotted-pattern-template`, `syntax-rules-nested-ellipsis`, `syntax-rules-custom-ellipsis`, `syntax-rules-malformed-template-ellipsis`, `syntax-rules-syntax-error` | High-level macro expansion supports top-level `define-syntax`, local `let-syntax` and `letrec-syntax`, hygienic introduced identifiers, literal binding checks, dotted patterns/templates, nested and custom ellipses, an explicit expansion API, malformed ellipsis diagnostics, and expansion-time `syntax-error` diagnostics that include the originating macro use. |
| Libraries, imports, exports | `define-library`, `import`, `export`, `include`, `include-ci`, `cond-expand`, library body ordering | `policy-gated` | `cond-expand-r7rs-feature`, `library-cond-expand-library-feature`, `library-import-export`, `library-exported-macro-scope`, `library-import-modifiers-composed`, `library-imported-binding-immutable`, `library-duplicate-export-error`, `program-import-after-expression-error`, `library-include-policy-denied`, `library-include-ci-policy-denied` | Library declarations, imports, modifiers, exported macros, `cond-expand`, immutability checks, duplicate export checks, include default-denial, and include-ci default-denial are implemented. File-reading declarations such as `include` and `include-ci` are policy-gated because they touch host files; the late-import program-shape error remains a conformance fixture but is not oracle-eligible because reference commands can read files as REPL input. |
| Proper tail recursion | Tail calls in procedures, conditionals, derived syntax, continuations, and library procedures | `implemented` | `proper-tail-recursion-loop` | Procedure, conditional, named-let, and representative continuation loops are fixture-covered through the evaluator trampoline. |
| Multiple values | `values`, `call-with-values`, `define-values`, `let-values`, `let*-values` | `implemented` | `multiple-values-direct`, `multiple-values-call-with-values`, `multiple-values-let-values`, `multiple-values-define-values` | Multiple-value producers, consumers, definitions, and binding forms are implemented. |
| Exceptions | `with-exception-handler`, `guard`, `raise`, `raise-continuable`, `error` | `implemented` | `exceptions-guard-raise`, `exceptions-error-object-accessors`, `exceptions-raise-continuable`, `exceptions-dynamic-wind-unwind` | Error objects remain inspectable through `error-object?`, `error-object-message`, and `error-object-irritants`; dynamic-wind cleanup is exercised while exceptions unwind. |
| Continuations | `call-with-current-continuation`, `call/cc`, `dynamic-wind` | `implemented` | `continuations-escape`, `continuations-higher-order-escape`, `continuations-dynamic-wind-exit`, `continuations-reenter-after-return`, `continuations-repeated-invocation`, `continuations-dynamic-wind-reentry`, `continuations-multiple-values`, `continuations-let-values-multiple-values`, `continuations-let*-values-multiple-values` | Captured continuations are re-enterable after their original extent returns, can be invoked repeatedly, escape from higher-order calls, preserve representative dynamic-wind exit and re-entry ordering, and deliver multiple values to call-with-values and let-values contexts. |
| Core data types | Booleans, numbers, characters, strings, symbols, pairs, lists, vectors, bytevectors, procedures, records, ports, EOF objects | `policy-gated` | `core-data-vector-ref`, `core-data-record-type`, `core-data-eof-object`, `standard-library-bytevector-ports` | Records, EOF objects, parameters, and in-memory string and bytevector ports are fixture-covered. Host-managed ports remain policy-gated. |
| Numeric tower | Exact and inexact integers, rationals, reals, complex numbers, arithmetic, comparison, conversions | `implemented` | `numeric-exact-rational-arithmetic`, `numeric-exactness-conversions`, `numeric-radix-string-conversions`, `numeric-rationalize-tolerance`, `numeric-exact-integer-sqrt-large`, `numeric-complex-rectangular-arithmetic`, `numeric-inexact-special-values`, `numeric-polar-special-values`, `standard-library-inexact-transcendentals` | Exact rationals reduce to canonical form; radix I/O, rationalization, large exact integer square roots, rectangular complex arithmetic, polar special-value canonicalization, predicates, and representative real-valued transcendental procedures are fixture-covered. |
| Equivalence | `eq?`, `eqv?`, `equal?` across standard datums | `implemented` | `core-data-vector-ref`, `core-data-circular-equal` | Circular pair and vector comparisons terminate. |
| Ports and I/O datums | Textual and binary ports, input/output procedures, reader and writer round trips | `policy-gated` | `standard-library-write-display`, `standard-library-write-shared`, `standard-library-write-simple`, `standard-library-write-circular`, `standard-library-write-string-range-newline`, `standard-library-read-string-port`, `standard-library-read-write-roundtrip`, `standard-library-bytevector-ports`, `standard-library-read-bytevector-partial`, `standard-library-current-output-port` | In-memory string and bytevector ports support focused read/write round trips, partial binary reads, range writes, and newline output without host access. Current/default ports and host-backed ports are policy-gated. |

## Standard Libraries

| Library | Status | Representative fixtures | Notes |
| --- | --- | --- | --- |
| `(scheme base)` | `policy-gated` | `primitive-procedure-call`, `derived-let-expression`, `multiple-values-call-with-values`, `numeric-radix-string-conversions`, `numeric-rationalize-tolerance`, `standard-library-read-bytevector-partial`, `standard-library-write-string-range-newline`, `standard-library-base-features-utf8` | Core syntax, pure procedures, radix numeric conversion, rationalization, and in-memory textual/binary port helpers are implemented. Current/default ports and host-facing I/O remain policy-gated. |
| `(scheme case-lambda)` | `implemented` | `standard-library-case-lambda`, `standard-library-case-lambda-rest` | Fixed, variadic, and dotted `case-lambda` clauses are implemented. |
| `(scheme char)` | `implemented` | `standard-library-char-upcase`, `standard-library-char-foldcase` | Character predicates, case operations, digit values, case-insensitive character comparisons, and case-insensitive string helpers are implemented for the runtime's supported character set. |
| `(scheme complex)` | `implemented` | `numeric-complex-rectangular-arithmetic`, `numeric-polar-special-values` | `make-rectangular`, `make-polar`, `real-part`, `imag-part`, `magnitude`, and `angle` are available. Polar and special-value results are normalized back into Agent Scheme numeric records instead of exposing host NaN/infinity spellings. |
| `(scheme cxr)` | `implemented` | `standard-library-cxr-cadr`, `standard-library-cxr-cadddr` | Three- and four-level composed accessors are implemented. |
| `(scheme eval)` | `implemented` | `standard-library-eval-environment` | `environment` imports explicit library sets into immutable environment specifiers; `eval` evaluates Scheme expressions through the Agent Scheme evaluator rather than host eval. Unit tests cover rejecting definitions into immutable environments. |
| `(scheme file)` | `policy-gated` | `standard-library-file-exists-policy` | Host file-system access must be audited and policy-gated. |
| `(scheme inexact)` | `implemented` | `numeric-inexact-special-values`, `standard-library-inexact-transcendentals` | Predicates and representative real-valued transcendental procedures are implemented through host math with Agent Scheme canonical inexact records. |
| `(scheme lazy)` | `implemented` | `standard-library-lazy-force` | Promise imports with memoizing `delay`, `delay-force`, `force`, `make-promise`, and `promise?` are implemented. |
| `(scheme load)` | `policy-gated` | `standard-library-load-policy-denied` | Loading host files requires file policy. Fixture coverage exercises default denial; unit tests cover allowed-root loading. |
| `(scheme process-context)` | `policy-gated` | `standard-library-process-context-policy-denied` | Environment, command-line, and process-exit access import successfully but require policy checks before use. |
| `(scheme read)` | `policy-gated` | `standard-library-read-string-port`, `standard-library-read-write-roundtrip` | `read` is implemented for explicit in-memory string input ports and uses the Agent Scheme reader. Default current input and host ports remain policy-gated. |
| `(scheme repl)` | `policy-gated` | `standard-library-repl-policy-denied`, `standard-library-repl-interaction-environment` | `interaction-environment` denies outside a current session context and returns a mutable environment specifier for the active session when policy allows it. |
| `(scheme time)` | `policy-gated` | `standard-library-time-policy-denied`, `standard-library-time-clock-grant` | Time is an observable host effect. Calls fail closed without clock authority and return R7RS-shaped clock values through the shared capability path when a clock grant authorizes the observation. |
| `(scheme write)` | `policy-gated` | `standard-library-write-display`, `standard-library-write-shared`, `standard-library-write-simple`, `standard-library-write-circular`, `standard-library-write-string-range-newline`, `standard-library-read-write-roundtrip`, `standard-library-current-output-port` | In-memory string output with `display`, `write`, `write-shared`, `write-simple`, range writes, and newline output is implemented; default current output and host-backed ports remain policy-gated. |
| `(scheme r5rs)` | `implemented` | `standard-library-r5rs-aliases` | A practical R5RS compatibility layer imports base bindings and the `exact->inexact`/`inexact->exact` aliases. |

### `(scheme base)` Binding Status

The bootstrap evaluator now treats `(scheme base)` as the initial R7RS-small
base library target. Pure bindings are implemented in the evaluator kernel or
portable Scheme prelude; host/session effects remain explicit policy gates.

Implemented kernel primitive procedure bindings include:

- numeric and predicates: `*`, `+`, `-`, `/`, `<`, `<=`, `=`, `>`, `>=`,
  `ceiling`, `complex?`, `denominator`, `exact`,
  `exact-integer-sqrt`, `exact-integer?`, `exact?`, `expt`, `floor`, `floor/`,
  `floor-quotient`, `floor-remainder`, `gcd`, `inexact`, `inexact?`,
  `integer?`, `lcm`, `modulo`, `number->string`, `number?`, `numerator`,
  `quotient`, `rational?`, `rationalize`, `real?`, `remainder`, `round`,
  `string->number`, `truncate`, `truncate/`, `truncate-quotient`,
  `truncate-remainder`
- pairs and lists: `car`, `cdr`, `cons`, `list?`, `null?`, `pair?`,
  `set-car!`, `set-cdr!`
- booleans, equivalence, symbols, parameters, and procedures: `boolean=?`,
  `boolean?`, `eq?`, `equal?`, `eqv?`, `features`, `make-parameter`,
  `procedure?`, `string->symbol`, `symbol->string`, `symbol=?`, `symbol?`
- characters and strings: `char->integer`, `char<=?`, `char<?`, `char=?`,
  `char>=?`, `char>?`, `char?`, `integer->char`, `list->string`,
  `make-string`, `string`, `string->list`, `string->number`, `string->utf8`,
  `string->vector`, `string-append`, `string-copy`, `string-copy!`,
  `string-fill!`, `string-length`, `string-ref`, `string-set!`, `string<=?`,
  `string<?`, `string=?`, `string>=?`, `string>?`, `string?`, `substring`,
  `utf8->string`, `vector->string`
- vectors and bytevectors: `bytevector`, `bytevector-append`, `bytevector-copy`,
  `bytevector-copy!`, `bytevector-length`, `bytevector-u8-ref`,
  `bytevector-u8-set!`, `bytevector?`, `list->vector`, `make-bytevector`,
  `make-vector`, `vector`, `vector->list`, `vector-append`, `vector-copy`,
  `vector-copy!`, `vector-fill!`, `vector-length`, `vector-ref`,
  `vector-set!`, `vector?`
- EOF and in-memory ports: `binary-port?`, `call-with-port`, `char-ready?`,
  `close-input-port`, `close-output-port`, `close-port`, `eof-object`,
  `eof-object?`, `get-output-bytevector`, `get-output-string`,
  `input-port-open?`, `input-port?`, `open-input-bytevector`,
  `open-input-string`, `open-output-bytevector`, `open-output-string`,
  `output-port-open?`, `output-port?`, `peek-char`, `peek-u8`, `port?`,
  `read-bytevector`, `read-bytevector!`, `read-char`, `read-error?`,
  `read-line`,
  `read-string`, `read-u8`, `textual-port?`, `u8-ready?`,
  `flush-output-port`, `file-error?`, `write-bytevector`, `write-char`,
  `write-string`, `write-u8`
- higher-order helpers: `apply`, `call-with-current-continuation`,
  `call-with-values`, `call/cc`, `dynamic-wind`, `values`,
  `with-exception-handler`, `raise`, `raise-continuable`, `error`,
  `error-object?`, `error-object-message`, `error-object-irritants`

Implemented portable prelude procedure bindings include:

- pairs and lists: `append`, `assoc`, `assq`, `assv`, `caar`, `cadr`,
  `cdar`, `cddr`, `length`, `list`, `list-copy`, `list-ref`, `list-set!`,
  `list-tail`, `make-list`, `member`, `memq`, `memv`, `reverse`
- booleans and numeric conveniences: `abs`, `even?`, `max`, `min`,
  `negative?`, `not`, `odd?`, `positive?`, `square`, `zero?`
- higher-order traversal helpers: `for-each`, `map`, `string-for-each`,
  `string-map`, `vector-for-each`, `vector-map`

Implemented macro-expanded and evaluator-supported syntax includes `and`,
`case`, `cond`, `cond-expand`, `define-record-type`, `define-values`, `do`,
`guard`, `let`, `let*`, `let-values`, `let*-values`, `letrec`, `letrec*`,
`let-syntax`, `letrec-syntax`, `or`, `parameterize`, `quasiquote`,
`syntax-rules`, `unless`, and `when`.

The evaluator exposes a macro expansion phase through `agent-scheme-expand` and
`agent-scheme-expand-source` in both the Emacs Lisp and portable Scheme
kernels.

Policy-gated base bindings are limited to host-managed ports,
process-facing I/O, current/default port integration, and source inclusion:
`current-error-port`, `current-input-port`, `current-output-port`,
`include`, and `include-ci`. The pure in-memory string and bytevector port
operations above do not grant host authority.

## Fixture Rules

- Add one fixture for each representative behavior before marking a matrix row
  `implemented`.
- Use stable fixture ids and the shared fixture fields: `kind`, `phase`,
  `oracle`, `options`, `source`, and `expect` in addition to the conformance
  metadata fields.
- When a fixture is inspired by an external test suite, include a `provenance`
  field with source location, license location, and a review note stating
  whether the fixture is an Agent Scheme-owned rewrite or copied material.
- A fixture marked `implemented` must run through `make test` and compare its
  printed value, multiple values, or expected error.
- Fixtures marked `pending`, `policy-gated`, or `unavailable` are still loaded
  and shape-checked so they remain easy to find without failing the suite.
- Keep snippets small. When a behavior needs a larger program, add a named
  fixture file beside the conformance case and reference it from this matrix.
