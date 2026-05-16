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
| Reader syntax | Comments, case directives, booleans, numbers, characters, strings, symbols, lists, dotted pairs, abbreviations, vectors, bytevectors, datum comments | `pending` | `reader-boolean-literals`, `reader-bytevector-literal`, `reader-character-literal`, `reader-symbol-case-directive`, `reader-dotted-list`, `reader-vector-literal`, `reader-abbreviation-forms`, `reader-comments-and-datum-comments` | First-pass reader datums are implemented and fixture-loaded with Agent Scheme's reader; datum labels remain pending. |
| Primitive expressions | Literal, variable reference, quote, procedure call, `if`, `set!`, `lambda` | `implemented` | `primitive-procedure-call` | Emacs Lisp and portable R7RS evaluator kernels cover explicit lexical environments, closures, mutation, and primitive calls. |
| Definitions and sequencing | `define`, `define-values`, `begin`, internal definitions | `pending` | `primitive-procedure-call` | Internal definitions should be tested with lexical scope cases. |
| Derived syntax | `cond`, `case`, `and`, `or`, `when`, `unless`, `let`, `let*`, `letrec`, `letrec*`, `let-values`, `let*-values`, `do`, `delay`, `quasiquote`, `parameterize` | `pending` | `derived-let-expression` | Initial macro-expanded `and`, `or`, `when`, `unless`, `let`, `let*`, and simple `cond` support is implemented; broader derived syntax remains pending. |
| `syntax-rules` macros | `define-syntax`, `let-syntax`, `letrec-syntax`, literals, ellipses, hygiene | `pending` | `syntax-rules-unless`, `syntax-rules-let-syntax-hygiene` | Initial high-level macro expansion supports top-level `define-syntax`, local `let-syntax` and `letrec-syntax`, one-dimensional ellipses, and hygienic introduced identifiers. Dotted patterns, nested ellipses, and additional literal-binding edge cases still need coverage. |
| Libraries, imports, exports | `define-library`, `import`, `export`, `include`, `include-ci`, `cond-expand`, library body ordering | `pending` | `library-import-export` | Library names use R7RS names such as `(scheme base)`. |
| Proper tail recursion | Tail calls in procedures, conditionals, derived syntax, continuations, and library procedures | `pending` | `proper-tail-recursion-loop` | Procedure, conditional, and named-let loops are fixture-covered; continuations and broader library interactions remain pending. |
| Multiple values | `values`, `call-with-values`, `define-values`, `let-values`, `let*-values` | `pending` | `multiple-values-direct`, `multiple-values-call-with-values` | Fixture expectations can compare either one value or multiple values. |
| Exceptions | `with-exception-handler`, `guard`, `raise`, `raise-continuable`, `error` | `pending` | `exceptions-guard-raise` | Error objects should remain printable as Scheme-readable data where possible. |
| Continuations | `call-with-current-continuation`, `call/cc`, `dynamic-wind` | `pending` | `continuations-escape` | Continuation tests should also cover interaction with dynamic extents later. |
| Core data types | Booleans, numbers, characters, strings, symbols, pairs, lists, vectors, bytevectors, procedures, ports, EOF objects | `pending` | `core-data-vector-ref`, `core-data-eof-object` | Data-type tests should cover predicates, constructors, accessors, mutation, and equality. |
| Numeric tower | Exact and inexact integers, rationals, reals, complex numbers, arithmetic, comparison, conversions | `pending` | `primitive-procedure-call` | Complex support may move with `(scheme complex)`. |
| Equivalence | `eq?`, `eqv?`, `equal?` across standard datums | `pending` | `core-data-vector-ref` | Add exact edge cases as data representation stabilizes. |
| Ports and I/O datums | Textual and binary ports, input/output procedures, reader and writer round trips | `pending` | `standard-library-write-display` | External host access is policy-gated separately. |

## Standard Libraries

| Library | Status | Representative fixtures | Notes |
| --- | --- | --- | --- |
| `(scheme base)` | `pending` | `primitive-procedure-call`, `derived-let-expression`, `multiple-values-call-with-values` | Core syntax and procedures. |
| `(scheme case-lambda)` | `pending` | `standard-library-case-lambda` | Procedure dispatch by arity. |
| `(scheme char)` | `pending` | `standard-library-char-upcase` | Character predicates and case operations. |
| `(scheme complex)` | `pending` | None yet | Add fixtures when numeric representation lands. |
| `(scheme cxr)` | `pending` | `standard-library-cxr-cadr` | Composed pair accessors. |
| `(scheme eval)` | `policy-gated` | None yet | Required semantics should be available only through explicit evaluation policy. |
| `(scheme file)` | `policy-gated` | `standard-library-file-exists-policy` | Host file-system access must be audited and policy-gated. |
| `(scheme inexact)` | `pending` | None yet | Inexact numeric operations. |
| `(scheme lazy)` | `pending` | `standard-library-lazy-force` | Promises, `delay`, and `force`. |
| `(scheme load)` | `policy-gated` | None yet | Loading host files requires policy checks. |
| `(scheme process-context)` | `policy-gated` | None yet | Environment and command-line access require policy checks. |
| `(scheme read)` | `pending` | None yet | Reading from in-memory ports can be pure; host ports need policy. |
| `(scheme repl)` | `policy-gated` | None yet | Interactive host integration belongs behind the REPL/session policy boundary. |
| `(scheme time)` | `policy-gated` | None yet | Time is an observable host effect and should be explicit. |
| `(scheme write)` | `pending` | `standard-library-write-display` | Writer output should be stable enough for fixture comparison. |
| `(scheme r5rs)` | `pending` | None yet | Compatibility library. |

### `(scheme base)` Binding Status

Issue #4 establishes the first `(scheme base)` procedure registry used by the
bootstrap evaluator. This is not a claim of complete base-library conformance:
derived syntax, macros, multiple values, continuations, exceptions, records,
ports, and host-effecting bindings remain separate follow-up work.

Implemented primitive procedure bindings:

- numeric and predicates: `*`, `+`, `-`, `/`, `<`, `<=`, `=`, `>`, `>=`, `abs`,
  `ceiling`, `complex?`, `even?`, `exact-integer?`, `exact?`, `floor`,
  `floor-quotient`, `floor-remainder`, `inexact?`, `integer?`, `max`, `min`,
  `modulo`, `negative?`, `number->string`, `number?`, `odd?`, `positive?`,
  `quotient`, `rational?`, `real?`, `remainder`, `round`, `square`, `truncate`,
  `truncate-quotient`, `truncate-remainder`, `zero?`
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
- higher-order helpers: `apply`, `for-each`, `map`

Implemented macro-expanded and evaluator-supported syntax includes `and`,
simple `cond`, `let`, `let*`, `letrec`, `letrec*`, `let-syntax`,
`letrec-syntax`, `or`, `syntax-rules`, `unless`, and `when`.

Pending pure bindings include remaining derived syntax and macro forms (`case`,
`cond-expand`, `do`, `quasiquote`), records
(`define-record-type`), multiple values (`call-with-values`, `define-values`,
`let-values`, `let*-values`, `values`), continuations (`call/cc`,
`call-with-current-continuation`, `dynamic-wind`), exceptions (`error`, `guard`,
`raise`, `raise-continuable`, `with-exception-handler` and error-object
predicates), remaining numeric operations (`denominator`, `exact`,
`exact-integer-sqrt`, `expt`, `gcd`, `inexact`, `lcm`, `numerator`,
`number->string` radix support, `rationalize`, `string->number` radix support,
`floor/`, `truncate/`), UTF-8 conversion (`string->utf8`, `utf8->string`), and
feature/library forms (`features`, `include`, `include-ci`).

Policy-gated base bindings are the ones that expose or manipulate host-managed
ports or process-facing I/O: `binary-port?`, `call-with-port`, `char-ready?`,
`close-input-port`, `close-output-port`, `close-port`, `current-error-port`,
`current-input-port`, `current-output-port`, `eof-object`, `eof-object?`,
`file-error?`, `flush-output-port`, `get-output-bytevector`,
`get-output-string`, `input-port-open?`, `input-port?`,
`open-input-bytevector`, `open-input-string`, `open-output-bytevector`,
`open-output-string`, `output-port-open?`, `output-port?`, `peek-char`,
`peek-u8`, `port?`, `read-bytevector`, `read-bytevector!`, `read-char`,
`read-error?`, `read-line`, `read-string`, `read-u8`, `textual-port?`,
`u8-ready?`, `write-bytevector`, `write-char`, `write-string`, and `write-u8`.
In-memory ports may become pure later, but they still need the port subsystem
before this matrix marks them implemented.

## Fixture Rules

- Add one fixture for each representative behavior before marking a matrix row
  `implemented`.
- A fixture marked `implemented` must run through `make test` and compare its
  printed value, multiple values, or expected error.
- Fixtures marked `pending`, `policy-gated`, or `unavailable` are still loaded
  and shape-checked so they remain easy to find without failing the suite.
- Keep snippets small. When a behavior needs a larger program, add a named
  fixture file beside the conformance case and reference it from this matrix.
