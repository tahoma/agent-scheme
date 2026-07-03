# Stdlib Libraries

Consent Scheme treats SRFI and R7RS-large libraries as optional `stdlib`
support above the R7RS-small conformance contract. The R7RS-small status remains
tracked in [R7RS-Small Conformance Matrix](r7rs-conformance.md); this page
tracks optional library support that is useful to programs and later runtime
features without making it part of that baseline. Source-backed stdlib
libraries live under `scheme/stdlib/`; SRFI, R7RS-large, and historical Consent
names are public import aliases and provenance metadata, not separate
source-tree layers.

## Implemented Libraries

| Library | Status | Source | Imports | Notes |
| --- | --- | --- | --- | --- |
| `(stdlib json)` | implemented | Local portable implementation, recorded in `(stdlib manifest)` | `(stdlib json)`, `(consent json)`, `(srfi 180)`, `(srfi srfi-180)` | JSON boundary codec used by tool-calling and protocol edges; historical Consent and SRFI spellings are compatibility aliases. |
| `(srfi 16)` | shimmed | Built-in shim over R7RS `(scheme case-lambda)`, recorded in `(stdlib manifest)` | `(srfi 16)`, `(srfi srfi-16)` | Optional SRFI compatibility for `case-lambda`; the implementation remains the R7RS-small library and is not vendored stdlib source. |
| `(stdlib and-let-star)` | implemented | Vendored adapted SRFI 2 sample macro, recorded in `(stdlib manifest)` | `(stdlib and-let-star)`, `(srfi 2)`, `(srfi srfi-2)` | Optional SRFI 2 `and-let*` syntax for guarded sequential bindings; not part of the R7RS-small baseline. |
| `(stdlib list)` | implemented | Vendored adapted SRFI 1 reference implementation, recorded in `(stdlib manifest)` | `(stdlib list)`, `(scheme list)`, `(srfi 1)`, `(srfi srfi-1)` | Primary stdlib spelling owns the source; R7RS-large and SRFI spellings are compatibility aliases. |
| `(stdlib generator)` | implemented | Vendored adapted SRFI 158 sample implementation, recorded in `(stdlib manifest)` | `(stdlib generator)`, `(scheme generator)`, `(srfi 158)`, `(srfi srfi-158)` | Primary stdlib spelling owns generators and accumulators; R7RS-large and SRFI spellings are compatibility aliases. |
| `(stdlib receive)` | shimmed | Built-in portable shim over R7RS multiple values, recorded in `(stdlib manifest)` | `(stdlib receive)`, `(srfi 8)`, `(srfi srfi-8)` | Optional SRFI 8 `receive` syntax for binding multiple values; not part of the R7RS-small baseline. |
| `(stdlib assume)` | shimmed | Built-in portable SRFI 145 shim, recorded in `(stdlib manifest)` | `(stdlib assume)`, `(srfi 145)`, `(srfi srfi-145)` | Optional SRFI 145 `assume` syntax for invalid code paths; not part of the R7RS-small baseline. |
| `(stdlib comparator)` | implemented | Vendored adapted SRFI 128 sample implementation, recorded in `(stdlib manifest)` | `(stdlib comparator)`, `(scheme comparator)`, `(srfi 128)`, `(srfi srfi-128)` | Primary stdlib spelling owns the source; R7RS-large and SRFI spellings are compatibility aliases. |

The Scheme-readable `(stdlib manifest)` library records source URLs, upstream
revisions, licenses, local patches, import aliases, dependencies, and test
status for stdlib libraries. The historical `(srfi manifest)` name remains an
alias. Vendored source keeps its upstream license and local adaptations are
listed in the manifest entry.
