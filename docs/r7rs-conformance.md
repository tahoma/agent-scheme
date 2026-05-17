# R7RS-Small Conformance Matrix

This matrix is the source of truth for Agent Scheme's R7RS-small surface. Use
the local [R7RS-small report reference](r7rs-small-report.md) for the underlying
language text. This matrix tracks the language features, standard libraries, and
representative fixture cases that should move from `pending` to `implemented`
as the runtime lands.

Fixture cases live in `fixtures/r7rs/conformance-cases.scm`. The ERT harness in
`tests/agent-scheme-conformance-test.el` validates every fixture and runs cases
marked `implemented`.

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
| Reader syntax | Comments, case directives, booleans, numbers, characters, strings, symbols, lists, dotted pairs, abbreviations, vectors, bytevectors, datum comments, datum labels | `pending` | `reader-boolean-literals`, `reader-bytevector-literal`, `reader-character-literal`, `reader-symbol-case-directive`, `reader-dotted-list`, `reader-vector-literal`, `reader-abbreviation-forms`, `reader-comments-and-datum-comments`, `reader-datum-label-cycle` | First-pass reader datums, including shared and circular datum labels, are implemented and fixture-loaded with Agent Scheme's reader. |
| Primitive expressions | Literal, variable reference, quote, procedure call, `if`, `set!`, `lambda` | `implemented` | `primitive-procedure-call` | Emacs Lisp and portable R7RS evaluator kernels cover explicit lexical environments, closures, mutation, and primitive calls. |
| Definitions and sequencing | `define`, `define-values`, `begin`, internal definitions | `pending` | `primitive-procedure-call` | Internal definitions should be tested with lexical scope cases. |
| Derived syntax | `cond`, `case`, `and`, `or`, `when`, `unless`, `let`, `let*`, `letrec`, `letrec*`, `let-values`, `let*-values`, `do`, `delay`, `quasiquote`, `parameterize` | `pending` | `derived-let-expression`, `derived-cond-arrow-literal-binding`, `derived-case-expression`, `derived-do-expression`, `derived-quasiquote-expression` | Macro-expanded `and`, `case`, `cond`, `do`, `or`, `when`, `unless`, `let`, and `let*` support is implemented. `letrec`, `letrec*`, `let-values`, `let*-values`, `begin`, and `quasiquote` are evaluator-supported where primitive handling is required. |
| `syntax-rules` macros | `define-syntax`, `let-syntax`, `letrec-syntax`, literals, ellipses, hygiene | `implemented` | `syntax-rules-unless`, `syntax-rules-let-syntax-hygiene`, `syntax-rules-dotted-pattern-template`, `syntax-rules-nested-ellipsis`, `syntax-rules-syntax-error` | High-level macro expansion supports top-level `define-syntax`, local `let-syntax` and `letrec-syntax`, hygienic introduced identifiers, literal binding checks, dotted patterns/templates, nested ellipses, an explicit expansion API, and expansion-time `syntax-error` diagnostics that include the originating macro use. |
| Libraries, imports, exports | `define-library`, `import`, `export`, `include`, `include-ci`, `cond-expand`, library body ordering | `pending` | `cond-expand-r7rs-feature`, `library-import-export`, `library-imported-binding-immutable`, `library-duplicate-export-error`, `program-import-after-expression-error` | Basic `define-library`, program imports, import modifiers, exported macros, library-level `cond-expand`, import immutability checks, duplicate export checks, and policy-gated include declarations are implemented. Positive include fixtures need fixture-level policy options before this row can move to `implemented`. |
| Proper tail recursion | Tail calls in procedures, conditionals, derived syntax, continuations, and library procedures | `pending` | `proper-tail-recursion-loop` | Procedure, conditional, named-let, and representative continuation loops are fixture-covered; broader library interactions remain pending. |
| Multiple values | `values`, `call-with-values`, `define-values`, `let-values`, `let*-values` | `pending` | `multiple-values-direct`, `multiple-values-call-with-values`, `multiple-values-let-values` | `values`, `call-with-values`, `let-values`, and `let*-values` are implemented; `define-values` remains pending. |
| Exceptions | `with-exception-handler`, `guard`, `raise`, `raise-continuable`, `error` | `implemented` | `exceptions-guard-raise`, `exceptions-raise-continuable` | Error objects remain inspectable through `error-object?`, `error-object-message`, and `error-object-irritants`. |
| Continuations | `call-with-current-continuation`, `call/cc`, `dynamic-wind` | `implemented` | `continuations-escape`, `continuations-dynamic-wind-exit`, `continuations-reenter-after-return`, `continuations-repeated-invocation`, `continuations-dynamic-wind-reentry`, `continuations-multiple-values`, `continuations-let-values-multiple-values`, `continuations-let*-values-multiple-values` | Captured continuations are re-enterable after their original extent returns, can be invoked repeatedly, preserve representative dynamic-wind exit and re-entry ordering, and deliver multiple values to call-with-values and let-values contexts. |
| Core data types | Booleans, numbers, characters, strings, symbols, pairs, lists, vectors, bytevectors, procedures, records, ports, EOF objects | `pending` | `core-data-vector-ref`, `core-data-record-type`, `core-data-eof-object`, `standard-library-bytevector-ports` | Records are covered through `define-record-type`; EOF objects and in-memory string and bytevector ports are fixture-covered. Host-managed ports remain pending or policy-gated. |
| Numeric tower | Exact and inexact integers, rationals, reals, complex numbers, arithmetic, comparison, conversions | `implemented` | `numeric-exact-rational-arithmetic`, `numeric-exactness-conversions`, `numeric-complex-rectangular-arithmetic`, `numeric-inexact-special-values`, `numeric-polar-special-values` | Exact rationals reduce to canonical form; rectangular complex arithmetic, polar special-value canonicalization, and focused `(scheme inexact)` predicates are fixture-covered. Remaining transcendental routines may still use host math only behind Agent Scheme result canonicalization. |
| Equivalence | `eq?`, `eqv?`, `equal?` across standard datums | `pending` | `core-data-vector-ref`, `core-data-circular-equal` | Circular pair and vector comparisons terminate; add exact edge cases as data representation stabilizes. |
| Ports and I/O datums | Textual and binary ports, input/output procedures, reader and writer round trips | `pending` | `standard-library-write-display`, `standard-library-write-shared`, `standard-library-write-simple`, `standard-library-write-circular`, `standard-library-read-string-port`, `standard-library-bytevector-ports`, `standard-library-current-output-port` | In-memory string and bytevector ports support focused read/write round trips without host access. Current/default ports, read/write error predicates, flushing, and host-backed ports remain pending or policy-gated. |

## Standard Libraries

| Library | Status | Representative fixtures | Notes |
| --- | --- | --- | --- |
| `(scheme base)` | `pending` | `primitive-procedure-call`, `derived-let-expression`, `multiple-values-call-with-values` | Core syntax and procedures. |
| `(scheme case-lambda)` | `pending` | `standard-library-case-lambda` | Focused fixed-arity `case-lambda` import is implemented; broader clause forms remain pending. |
| `(scheme char)` | `pending` | `standard-library-char-upcase` | Focused `char-upcase` import is implemented; full character library coverage remains pending. |
| `(scheme complex)` | `implemented` | `numeric-complex-rectangular-arithmetic`, `numeric-polar-special-values` | `make-rectangular`, `make-polar`, `real-part`, `imag-part`, `magnitude`, and `angle` are available. Polar and special-value results are normalized back into Agent Scheme numeric records instead of exposing host NaN/infinity spellings. |
| `(scheme cxr)` | `pending` | `standard-library-cxr-cadr` | Focused composed accessor imports are implemented; full three- and four-level accessor coverage remains pending. |
| `(scheme eval)` | `implemented` | `standard-library-eval-environment` | `environment` imports explicit library sets into immutable environment specifiers; `eval` evaluates Scheme expressions through the Agent Scheme evaluator rather than host eval. Unit tests cover rejecting definitions into immutable environments. |
| `(scheme file)` | `policy-gated` | `standard-library-file-exists-policy` | Host file-system access must be audited and policy-gated. |
| `(scheme inexact)` | `pending` | `numeric-inexact-special-values` | Focused `finite?`, `infinite?`, and `nan?` imports are implemented; public transcendental procedure imports remain pending. Host math accelerators used by existing complex helpers must return through Agent Scheme canonical inexact records. |
| `(scheme lazy)` | `pending` | `standard-library-lazy-force` | Focused promise imports with memoizing `delay` and `force` are implemented; broader lazy edge cases remain pending. |
| `(scheme load)` | `policy-gated` | `standard-library-load-policy-denied` | Loading host files requires file policy. Fixture coverage exercises default denial; unit tests cover allowed-root loading. |
| `(scheme process-context)` | `policy-gated` | None yet | Environment and command-line access require policy checks. |
| `(scheme read)` | `pending` | `standard-library-read-string-port` | `read` is implemented for explicit in-memory string input ports and uses the Agent Scheme reader. Default current input and host ports remain pending or policy-gated. |
| `(scheme repl)` | `policy-gated` | None yet | Interactive host integration belongs behind the REPL/session policy boundary. |
| `(scheme time)` | `policy-gated` | None yet | Time is an observable host effect and should be explicit. |
| `(scheme write)` | `pending` | `standard-library-write-display`, `standard-library-write-shared`, `standard-library-write-simple`, `standard-library-write-circular`, `standard-library-current-output-port` | Focused in-memory string output with `display`, `write`, `write-shared`, and `write-simple` is implemented; default current output and host-backed ports remain pending or policy-gated. |
| `(scheme r5rs)` | `pending` | None yet | Compatibility library. |

### `(scheme base)` Binding Status

Issue #4 establishes the first `(scheme base)` procedure registry used by the
bootstrap evaluator. This is not a claim of complete base-library conformance:
derived syntax, macros, multiple values, continuations, exceptions, ports, and
host-effecting bindings remain separate follow-up work.

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
- booleans, equivalence, symbols, and procedures: `boolean=?`, `boolean?`,
  `eq?`, `equal?`, `eqv?`, `not`, `procedure?`, `string->symbol`,
  `symbol->string`, `symbol=?`, `symbol?`
- characters and strings: `char->integer`, `char<=?`, `char<?`, `char=?`,
  `char>=?`, `char>?`, `char?`, `integer->char`, `list->string`,
  `make-string`, `string`, `string->list`, `string->number`, `string->vector`,
  `string-append`, `string-copy`, `string-copy!`, `string-fill!`,
  `string-for-each`, `string-length`, `string-map`, `string-ref`,
  `string-set!`, `string<=?`, `string<?`, `string=?`, `string>=?`, `string>?`,
  `string?`, `substring`, `vector->string`
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
  `read-bytevector`, `read-bytevector!`, `read-char`, `read-line`,
  `read-string`, `read-u8`, `textual-port?`, `u8-ready?`,
  `write-bytevector`, `write-char`, `write-string`, `write-u8`
- higher-order helpers: `apply`, `call-with-current-continuation`,
  `call-with-values`, `call/cc`, `dynamic-wind`, `for-each`, `map`, `values`,
  `with-exception-handler`, `raise`, `raise-continuable`, `error`,
  `error-object?`, `error-object-message`, `error-object-irritants`

Implemented macro-expanded and evaluator-supported syntax includes `and`,
`case`, `cond`, `cond-expand`, `define-record-type`, `do`, `guard`, `let`,
`let*`, `let-values`, `let*-values`, `letrec`, `letrec*`, `let-syntax`,
`letrec-syntax`, `or`, `quasiquote`, `syntax-rules`, `unless`, and `when`.

The evaluator exposes a macro expansion phase through `agent-scheme-expand` and
`agent-scheme-expand-source` in both the Emacs Lisp and portable Scheme
kernels.

Pending pure bindings include `define-values`, dynamic parameters
(`parameterize`), remaining inexact transcendental operations (`exp`, `log`,
`sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `sqrt`), UTF-8 conversion
(`string->utf8`, `utf8->string`), and feature/library forms (`features`,
`include`, `include-ci`).

Policy-gated or pending base bindings are now limited to host-managed ports,
process-facing I/O, and current/default port integration:
`current-error-port`, `current-input-port`, `current-output-port`,
`file-error?`, `flush-output-port`, and `read-error?`. The pure in-memory
string and bytevector port operations above do not grant host authority.

## Fixture Rules

- Add one fixture for each representative behavior before marking a matrix row
  `implemented`.
- A fixture marked `implemented` must run through `make test` and compare its
  printed value, multiple values, or expected error.
- Fixtures marked `pending`, `policy-gated`, or `unavailable` are still loaded
  and shape-checked so they remain easy to find without failing the suite.
- Keep snippets small. When a behavior needs a larger program, add a named
  fixture file beside the conformance case and reference it from this matrix.
