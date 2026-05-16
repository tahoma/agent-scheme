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
| Primitive expressions | Literal, variable reference, quote, procedure call, `if`, `set!`, `lambda` | `pending` | `primitive-procedure-call` | Start with `(scheme base)` expression semantics. |
| Definitions and sequencing | `define`, `define-values`, `begin`, internal definitions | `pending` | `primitive-procedure-call` | Internal definitions should be tested with lexical scope cases. |
| Derived syntax | `cond`, `case`, `and`, `or`, `when`, `unless`, `let`, `let*`, `letrec`, `letrec*`, `let-values`, `let*-values`, `do`, `delay`, `quasiquote`, `parameterize` | `pending` | `derived-let-expression` | Derived syntax may be implemented through macro expansion once `syntax-rules` exists. |
| `syntax-rules` macros | `define-syntax`, `let-syntax`, `letrec-syntax`, literals, ellipses, hygiene | `pending` | `syntax-rules-unless` | Macro support is a core requirement, not optional polish. |
| Libraries, imports, exports | `define-library`, `import`, `export`, `include`, `include-ci`, `cond-expand`, library body ordering | `pending` | `library-import-export` | Library names use R7RS names such as `(scheme base)`. |
| Proper tail recursion | Tail calls in procedures, conditionals, derived syntax, continuations, and library procedures | `pending` | `proper-tail-recursion-loop` | Tests should use a bounded loop that would overflow without tail calls. |
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

## Fixture Rules

- Add one fixture for each representative behavior before marking a matrix row
  `implemented`.
- A fixture marked `implemented` must run through `make test` and compare its
  printed value, multiple values, or expected error.
- Fixtures marked `pending`, `policy-gated`, or `unavailable` are still loaded
  and shape-checked so they remain easy to find without failing the suite.
- Keep snippets small. When a behavior needs a larger program, add a named
  fixture file beside the conformance case and reference it from this matrix.
