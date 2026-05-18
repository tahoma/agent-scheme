# R7RS-Small Conformance Matrix

This matrix is the source of truth for Agent Scheme's R7RS-small surface. Use
the local [R7RS-small report reference](r7rs-small-report.md) for the underlying
language text. This matrix tracks the language features, standard libraries, and
representative fixture cases that should move from `pending` to `implemented`
or `policy-gated` as the runtime lands.

Fixture cases live in the shared `agent-scheme-fixture-suite` at
`fixtures/r7rs/conformance-cases.scm`. The ERT harness in
`tests/agent-scheme-conformance-test.el` filters that corpus to
`kind r7rs-conformance`, validates every conformance fixture, and runs cases
marked `implemented`.

`make conformance-oracle` runs a separate reference implementation oracle over
pure shared fixtures. The default adapters target Chibi Scheme through
`AGENT_SCHEME_CHIBI` or `chibi-scheme` on `PATH` and Gauche through
`AGENT_SCHEME_GAUCHE` or `gosh` on `PATH`; missing references are reported as
`unsupported-reference` without affecting `make test`. Guile and Sagittarius
adapters can be selected with `AGENT_SCHEME_ORACLE_REFERENCES` when comparing
candidate default reference sets.

## Status Values

| Status | Meaning |
| --- | --- |
| `pending` | Required R7RS behavior that Agent Scheme has not implemented yet. |
| `implemented` | Behavior implemented by Agent Scheme and exercised by `make test`. |
| `policy-gated` | Required behavior whose host effects must pass Agent Scheme policy before use. The Scheme semantics still need conformance tests. |
| `unavailable` | Intentionally unavailable only where R7RS permits an implementation to omit or reject the behavior. No current row uses this status. |

## Language Features

| Area | R7RS-small coverage | Status | Representative fixtures | Notes |
| --- | --- | --- | --- | --- |
| Reader syntax | Comments, case directives, booleans, numbers, characters, strings, symbols, lists, dotted pairs, abbreviations, vectors, bytevectors, datum comments, datum labels | `implemented` | `reader-boolean-literals`, `reader-bytevector-literal`, `reader-character-literal`, `reader-symbol-case-directive`, `reader-dotted-list`, `reader-vector-literal`, `reader-abbreviation-forms`, `reader-comments-and-datum-comments`, `reader-datum-label-cycle` | First-pass reader datums, including shared and circular datum labels, are implemented and fixture-loaded with Agent Scheme's reader. |
| Primitive expressions | Literal, variable reference, quote, procedure call, `if`, `set!`, `lambda` | `implemented` | `primitive-procedure-call` | Emacs Lisp and portable R7RS evaluator kernels cover explicit lexical environments, closures, mutation, and primitive calls. |
| Definitions and sequencing | `define`, `define-values`, `begin`, internal definitions | `implemented` | `primitive-procedure-call`, `multiple-values-define-values` | Top-level and internal definitions are supported, including `define-values`. |
| Derived syntax | `cond`, `case`, `and`, `or`, `when`, `unless`, `let`, `let*`, `letrec`, `letrec*`, `let-values`, `let*-values`, `do`, `delay`, `quasiquote`, `parameterize` | `implemented` | `derived-let-expression`, `derived-cond-arrow-literal-binding`, `derived-case-expression`, `derived-do-expression`, `derived-quasiquote-expression`, `standard-library-lazy-force` | Macro-expanded derived syntax and evaluator-supported forms cover the R7RS-small initial target, including dynamic parameter rebinding through `parameterize`. |
| `syntax-rules` macros | `define-syntax`, `let-syntax`, `letrec-syntax`, literals, ellipses, hygiene | `implemented` | `syntax-rules-unless`, `syntax-rules-let-syntax-hygiene`, `syntax-rules-dotted-pattern-template`, `syntax-rules-nested-ellipsis`, `syntax-rules-syntax-error` | High-level macro expansion supports top-level `define-syntax`, local `let-syntax` and `letrec-syntax`, hygienic introduced identifiers, literal binding checks, dotted patterns/templates, nested ellipses, an explicit expansion API, and expansion-time `syntax-error` diagnostics that include the originating macro use. |
| Libraries, imports, exports | `define-library`, `import`, `export`, `include`, `include-ci`, `cond-expand`, library body ordering | `policy-gated` | `cond-expand-r7rs-feature`, `library-import-export`, `library-imported-binding-immutable`, `library-duplicate-export-error`, `program-import-after-expression-error` | Library declarations, imports, modifiers, exported macros, `cond-expand`, immutability checks, and duplicate export checks are implemented. File-reading declarations such as `include` and `include-ci` are policy-gated because they touch host files. |
| Proper tail recursion | Tail calls in procedures, conditionals, derived syntax, continuations, and library procedures | `implemented` | `proper-tail-recursion-loop` | Procedure, conditional, named-let, and representative continuation loops are fixture-covered through the evaluator trampoline. |
| Multiple values | `values`, `call-with-values`, `define-values`, `let-values`, `let*-values` | `implemented` | `multiple-values-direct`, `multiple-values-call-with-values`, `multiple-values-let-values`, `multiple-values-define-values` | Multiple-value producers, consumers, definitions, and binding forms are implemented. |
| Exceptions | `with-exception-handler`, `guard`, `raise`, `raise-continuable`, `error` | `implemented` | `exceptions-guard-raise`, `exceptions-raise-continuable` | Error objects remain inspectable through `error-object?`, `error-object-message`, and `error-object-irritants`. |
| Continuations | `call-with-current-continuation`, `call/cc`, `dynamic-wind` | `implemented` | `continuations-escape`, `continuations-dynamic-wind-exit`, `continuations-reenter-after-return`, `continuations-repeated-invocation`, `continuations-dynamic-wind-reentry`, `continuations-multiple-values`, `continuations-let-values-multiple-values`, `continuations-let*-values-multiple-values` | Captured continuations are re-enterable after their original extent returns, can be invoked repeatedly, preserve representative dynamic-wind exit and re-entry ordering, and deliver multiple values to call-with-values and let-values contexts. |
| Core data types | Booleans, numbers, characters, strings, symbols, pairs, lists, vectors, bytevectors, procedures, records, ports, EOF objects | `policy-gated` | `core-data-vector-ref`, `core-data-record-type`, `core-data-eof-object`, `standard-library-bytevector-ports` | Records, EOF objects, parameters, and in-memory string and bytevector ports are fixture-covered. Host-managed ports remain policy-gated. |
| Numeric tower | Exact and inexact integers, rationals, reals, complex numbers, arithmetic, comparison, conversions | `implemented` | `numeric-exact-rational-arithmetic`, `numeric-exactness-conversions`, `numeric-complex-rectangular-arithmetic`, `numeric-inexact-special-values`, `numeric-polar-special-values`, `standard-library-inexact-transcendentals` | Exact rationals reduce to canonical form; rectangular complex arithmetic, polar special-value canonicalization, predicates, and representative real-valued transcendental procedures are fixture-covered. |
| Equivalence | `eq?`, `eqv?`, `equal?` across standard datums | `implemented` | `core-data-vector-ref`, `core-data-circular-equal` | Circular pair and vector comparisons terminate. |
| Ports and I/O datums | Textual and binary ports, input/output procedures, reader and writer round trips | `policy-gated` | `standard-library-write-display`, `standard-library-write-shared`, `standard-library-write-simple`, `standard-library-write-circular`, `standard-library-read-string-port`, `standard-library-bytevector-ports`, `standard-library-current-output-port` | In-memory string and bytevector ports support focused read/write round trips without host access. Current/default ports and host-backed ports are policy-gated. |

## Standard Libraries

| Library | Status | Representative fixtures | Notes |
| --- | --- | --- | --- |
| `(scheme base)` | `policy-gated` | `primitive-procedure-call`, `derived-let-expression`, `multiple-values-call-with-values`, `standard-library-base-features-utf8` | Core syntax and pure procedures are implemented. Current/default ports and host-facing I/O remain policy-gated. |
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
| `(scheme read)` | `policy-gated` | `standard-library-read-string-port` | `read` is implemented for explicit in-memory string input ports and uses the Agent Scheme reader. Default current input and host ports remain policy-gated. |
| `(scheme repl)` | `policy-gated` | `standard-library-repl-policy-denied` | Interactive host integration belongs behind the REPL/session policy boundary. |
| `(scheme time)` | `policy-gated` | `standard-library-time-policy-denied` | Time is an observable host effect and requires policy checks before use. |
| `(scheme write)` | `policy-gated` | `standard-library-write-display`, `standard-library-write-shared`, `standard-library-write-simple`, `standard-library-write-circular`, `standard-library-current-output-port` | In-memory string output with `display`, `write`, `write-shared`, and `write-simple` is implemented; default current output and host-backed ports remain policy-gated. |
| `(scheme r5rs)` | `implemented` | `standard-library-r5rs-aliases` | A practical R5RS compatibility layer imports base bindings and the `exact->inexact`/`inexact->exact` aliases. |

### `(scheme base)` Binding Status

The bootstrap evaluator now treats `(scheme base)` as the initial R7RS-small
base library target. Pure bindings are implemented in the evaluator kernel or
portable Scheme prelude; host/session effects remain explicit policy gates.

Implemented primitive procedure bindings:

- numeric and predicates: `*`, `+`, `-`, `/`, `<`, `<=`, `=`, `>`, `>=`, `abs`,
  `ceiling`, `complex?`, `denominator`, `even?`, `exact`,
  `exact-integer-sqrt`, `exact-integer?`, `exact?`, `expt`, `floor`, `floor/`,
  `floor-quotient`, `floor-remainder`, `gcd`, `inexact`, `inexact?`,
  `integer?`, `lcm`, `max`, `min`, `modulo`, `negative?`, `number->string`,
  `number?`, `numerator`, `odd?`, `positive?`, `quotient`, `rational?`,
  `rationalize`, `real?`, `remainder`, `round`, `square`, `string->number`,
  `truncate`, `truncate/`, `truncate-quotient`, `truncate-remainder`, `zero?`
- pairs and lists: `append`, `assoc`, `assq`, `assv`, `caar`, `cadr`, `car`,
  `cdar`, `cddr`, `cdr`, `cons`, `length`, `list`, `list-copy`, `list-ref`,
  `list-set!`, `list-tail`, `list?`, `make-list`, `member`, `memq`, `memv`,
  `null?`, `pair?`, `reverse`, `set-car!`, `set-cdr!`
- booleans, equivalence, symbols, parameters, and procedures: `boolean=?`,
  `boolean?`, `eq?`, `equal?`, `eqv?`, `features`, `make-parameter`, `not`,
  `procedure?`, `string->symbol`, `symbol->string`, `symbol=?`, `symbol?`
- characters and strings: `char->integer`, `char<=?`, `char<?`, `char=?`,
  `char>=?`, `char>?`, `char?`, `integer->char`, `list->string`,
  `make-string`, `string`, `string->list`, `string->number`, `string->utf8`,
  `string->vector`, `string-append`, `string-copy`, `string-copy!`,
  `string-fill!`,
  `string-for-each`, `string-length`, `string-map`, `string-ref`,
  `string-set!`, `string<=?`, `string<?`, `string=?`, `string>=?`, `string>?`,
  `string?`, `substring`, `utf8->string`, `vector->string`
- vectors and bytevectors: `bytevector`, `bytevector-append`, `bytevector-copy`,
  `bytevector-copy!`, `bytevector-length`, `bytevector-u8-ref`,
  `bytevector-u8-set!`, `bytevector?`, `list->vector`, `make-bytevector`,
  `make-vector`, `vector`, `vector->list`, `vector-append`, `vector-copy`,
  `vector-copy!`, `vector-fill!`, `vector-for-each`, `vector-length`,
  `vector-map`, `vector-ref`, `vector-set!`, `vector?`
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
  `call-with-values`, `call/cc`, `dynamic-wind`, `for-each`, `map`, `values`,
  `with-exception-handler`, `raise`, `raise-continuable`, `error`,
  `error-object?`, `error-object-message`, `error-object-irritants`

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
- A fixture marked `implemented` must run through `make test` and compare its
  printed value, multiple values, or expected error.
- Fixtures marked `pending`, `policy-gated`, or `unavailable` are still loaded
  and shape-checked so they remain easy to find without failing the suite.
- Keep snippets small. When a behavior needs a larger program, add a named
  fixture file beside the conformance case and reference it from this matrix.
