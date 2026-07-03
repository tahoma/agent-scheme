# Evaluation Budgets

Consent Scheme keeps "always-available eval" sustainable by running every
evaluation under a set of resource ceilings.  A model-proposed or otherwise
untrusted form cannot run away: when a ceiling is reached the evaluation halts
**fail-closed** with a structured condition that an interpreted `guard` cannot
catch.  Budgets are the mechanism that makes pervasive evaluation feel
sustainable instead of scary.

This document describes the comprehensive budget surface: the single inspectable
budget **ledger**, its explicit exhaustion **reason** ("stop receipt"), the
dimensions and their defaults, and the procedures for inspecting and tightening
budgets.

## The single budget ledger

Rather than a pile of independent counters, the runtime presents one inspectable
ledger.  `(current-budget)` returns it: every dimension reports a used count and
a ceiling, and a final `reason` field names the dimension that stopped the run
(or `#f` while the run is still admissible).

```scheme
(import (scheme base) (agent reflect))
(current-budget)
;; =>
(budget
  (steps-used 3)        (max-steps 100000)
  (host-calls 1)        (max-host-calls 10000)
  (events-used 0)       (max-events 1000)
  (max-event-nodes 100000)
  (value-nodes-used 0)  (max-value-nodes 10000000)
  (source-metadata-used 0) (max-source-metadata 1000000)
  (interned-symbols-used 0) (max-interned-symbols 1000000)
  (output-bytes-used 0) (max-output-bytes 10485760)
  (max-wall-time-ms #f)
  (reason #f))
```

`(budget-remaining)` returns the same ledger expressed as remaining headroom
(`limit - used`) for each enforced dimension; an unbounded dimension (a `#f`
wall-time limit) reports `#f` so a caller can tell unbounded apart from
exhausted.

```scheme
(budget-remaining)
;; => (budget-remaining (steps 99997) (host-calls 9999) (events 1000)
;;                       (value-nodes 10000000) (source-metadata 1000000)
;;                       (interned-symbols 1000000)
;;                       (output-bytes 10485760) (reason #f))
```

## Dimensions and defaults

| Dimension | Spec key | Option key | Default | Enforced |
|---|---|---|---|---|
| Evaluator steps | `steps` | `max-steps` | `100000` | yes |
| Host callbacks | `host-callbacks` | `max-host-callbacks` | `10000` | yes |
| Yielded events | `yields` | `max-events` | `1000` | yes |
| Per-event node size | — | `max-event-nodes` | `100000` | yes |
| Allocation (value nodes) | `allocation-nodes` | `max-value-nodes` | `10000000` | yes |
| Source metadata entries | `source-metadata` | `max-source-metadata` | `1000000` | yes |
| Interned symbols | `interned-symbols` | `max-interned-symbols` | `1000000` | yes |
| Printed output bytes | `output-bytes` | `max-output-bytes` | `10485760` | yes |
| Wall time (ms) | `wall-time-ms` | `max-wall-time-ms` | `#f` (unbounded) | opt-in |
| File bytes | `file-bytes` | — | — | reserved |
| Capability calls | `capability-calls` | — | — | reserved |
| Model calls / tokens | `model-calls` | — | — | reserved |

**Steps** are charged once per evaluation step (this also covers macro
expansion, which runs through the same step counter).  **Host callbacks** count
primitive invocations.  **Events** bound the yield/audit channel.  **Allocation**
is charged at construction time and is measured in value-graph *nodes*, a
host-independent unit, rather than host bytes; the spec accepts `allocation-bytes`
as an alias for the same node budget.  **Interned symbols** are charged once per
guest `string->symbol` call, before the name is interned; because each call
interns at most one new symbol, the ceiling bounds how many symbols a run can add
to the process-global intern table, closing a resource-exhaustion vector where
untrusted code such as `(string->symbol (number->string i))` in a loop would
otherwise grow interned-symbol memory without limit.  Reader-created identifiers
are bounded by the reader's own node budgets rather than this dimension.
**Source metadata entries** bound the portable reader's process-global source
side table.  The table is not evicted during ordinary loading, so the loaded
source graph remains introspectable up to the configured ceiling; trusted
callers can retry with a higher `max-source-metadata` grant for unusually large
or intentionally adversarial inputs.  The `1000000` default is calibrated above
the current all-loadable-library source graph, which resolves 95 library names
and retains 133727 source metadata entries.
**Output bytes** are charged at each textual port write, before the bytes land,
so an unbounded printing loop fails closed.

The **reserved** dimensions are part of the ledger schema so the budget record
is comprehensive and forward-compatible, but their enforcement arrives with the
subsystems they describe (file-byte accounting, a distinct capability-call
counter, and model routing).

### Wall time and determinism

Wall time is unbounded by default, so ordinary and parity evaluations never read
a clock and stay deterministic.  A caller opts in by supplying both a ceiling
(`max-wall-time-ms`) and a clock thunk (`wall-clock`, a procedure of no
arguments returning integer milliseconds).  Tests inject a deterministic stub
clock; production callers inject the host monotonic clock.  When no wall-time
limit is set, the clock is never consulted.

## Adjusting budgets

Pass option overrides when evaluating.  In the portable core the options are an
association list; in the Emacs host they are a plist:

```scheme
;; Portable
(consent-eval-source-result source #f '((max-steps . 5000)
                                        (max-output-bytes . 4096)))
```

```elisp
;; Emacs host
(consent-eval-source-result source nil '(:max-steps 5000 :max-output-bytes 4096))
```

### Tightening within a run: `with-budget`

`(with-budget spec body ...)` evaluates `body` under a budget tightened by a
`(budget ...)` specification for that dynamic extent.  `spec` evaluates to a
budget datum, so a literal is quoted:

```scheme
(with-budget '(budget (steps 200) (output-bytes 1024))
  (do-some-bounded-work))
```

For each named counter dimension the effective ceiling is lowered to "at most
this much *more* from here" — `min(outer-ceiling, used + requested)` — so nested
`with-budget` forms compose monotonically (they only ever tighten).  The
inherited ceilings are restored when the body completes normally.  A non-local
exit out of the body (a captured-continuation escape) leaves the tightened
ceilings in place; that is a conservative, fail-closed outcome rather than a
relaxation.  The body is an implicit `begin`; wrap it in `(let () ...)` for
internal definitions.

`with-budget` tightens the counter dimensions (`steps`, `host-callbacks`,
`yields`, `allocation-nodes`, `interned-symbols`, `output-bytes`); wall time is
configured at the run boundary rather than tightened relative to elapsed time.

## The stop receipt

When a budget is exhausted the evaluation halts with a structured condition.  As
a result datum (for example from `consent-eval-source-result`, a job, or
`(recent-errors)`) the condition is typed `budget-exhausted` and carries a
`reason` naming the dimension that stopped the run:

```scheme
(condition
  (type budget-exhausted)
  (message "consent budget error: evaluation step budget exceeded")
  (phase evaluation)
  (reason steps)
  ...)
```

`(budget-exhausted? condition)` reports whether a condition datum or an
evaluation-result error datum is such a stop receipt, so a verifier, job
consumer, or dashboard can classify an outcome portably.

Budget enforcement is **uncatchable** by interpreted code: a budget condition
propagates past any interpreted `guard` to the host boundary, so untrusted code
cannot suppress its own resource limit.

## Observing budgets mid-run

`(budget-yield)` emits the current ledger as a yield event (visible through
`(recent-yields)`) and returns it, so an agent loop can record and react to
remaining budget without halting.

## Jobs

A job's declared budget appears in its `budget` field across every comprehensive
dimension (see [jobs.md](jobs.md)).  A completed job reports the consumed
counters in its result's own `budget` field, so remaining headroom is the
declared ceiling minus the used count per dimension.

## Tail recursion

Proper tail recursion is preserved while budgets still prevent runaway
computation: a tail-recursive loop runs iteratively through the trampoline
without growing the host stack, and each step is still charged, so an unbounded
loop halts on the step (or wall-time) budget rather than overflowing.
