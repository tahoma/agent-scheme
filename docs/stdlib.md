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
| `(srfi 0)` | shimmed | Built-in shim over R7RS `(scheme base)` `cond-expand`, recorded in `(stdlib manifest)` | `(srfi 0)`, `(srfi srfi-0)` | Optional SRFI 0 conditional-expansion compatibility; the shim exports only `cond-expand`, advertises the `srfi-0` feature identifier, and does not vendor SRFI source. |
| `(srfi 16)` | shimmed | Built-in shim over R7RS `(scheme case-lambda)`, recorded in `(stdlib manifest)` | `(srfi 16)`, `(srfi srfi-16)`, `(srfi :16)`, `(srfi :16 case-lambda)` | Optional SRFI compatibility for `case-lambda`; the implementation remains the R7RS-small library and is not vendored stdlib source. |
| `(stdlib srfi-reference)` | shimmed | Zero-export SRFI 261 reference-name shim, recorded in `(stdlib manifest)` | `(stdlib srfi-reference)`, `(srfi 261)`, `(srfi srfi-261)` | Optional SRFI 261 portable SRFI library-reference support; imports resolve for feature checks without adding bindings or vendored code. |
| `(stdlib srfi-libraries)` | shimmed | Zero-export SRFI 97 SRFI Libraries naming shim, recorded in `(stdlib manifest)` | `(stdlib srfi-libraries)`, `(srfi 97)`, `(srfi srfi-97)`, `(srfi :97)`, `(srfi :97 srfi-libraries)` | Optional SRFI 97 import-name support; imports resolve for feature checks without adding bindings or vendored code. |
| `(stdlib and-let-star)` | implemented | Vendored adapted SRFI 2 sample macro, recorded in `(stdlib manifest)` | `(stdlib and-let-star)`, `(srfi 2)`, `(srfi srfi-2)`, `(srfi :2)`, `(srfi :2 and-let*)` | Optional SRFI 2 `and-let*` syntax for guarded sequential bindings; not part of the R7RS-small baseline. |
| `(stdlib list)` | implemented | Vendored adapted SRFI 1 reference implementation, recorded in `(stdlib manifest)` | `(stdlib list)`, `(scheme list)`, `(srfi 1)`, `(srfi srfi-1)`, `(srfi :1)`, `(srfi :1 lists)` | Primary stdlib spelling owns the source; R7RS-large and SRFI spellings are compatibility aliases. |
| `(stdlib generator)` | implemented | Vendored adapted SRFI 158 sample implementation, recorded in `(stdlib manifest)` | `(stdlib generator)`, `(scheme generator)`, `(srfi 158)`, `(srfi srfi-158)` | Primary stdlib spelling owns generators and accumulators; R7RS-large and SRFI spellings are compatibility aliases. |
| `(stdlib testing)` | implemented | Vendored adapted SRFI 64 reference implementation, recorded in `(stdlib manifest)` | `(stdlib testing)`, `(srfi 64)`, `(srfi srfi-64)`, `(srfi :64)`, `(srfi :64 testing)` | Optional SRFI 64 test-suite API for stdlib and user tests; log-file output is disabled by default so file effects remain policy-gated. |
| `(stdlib random-bits)` | implemented | Vendored adapted SRFI 27 MRG32k3a reference implementation, recorded in `(stdlib manifest)` | `(stdlib random-bits)`, `(srfi 27)`, `(srfi srfi-27)`, `(srfi :27)`, `(srfi :27 random-bits)` | Optional SRFI 27 random-source API; deterministic PRNG state is portable, and entropy randomization uses policy-gated `(scheme time)`. |
| `(stdlib random-distributions)` | implemented | Portable SRFI 27 recommended usage examples, recorded in `(stdlib manifest)` | `(stdlib random-distributions)` | Permutation, exponential, and normal-deviate helpers built on SRFI 27 random sources; intentionally not exported by the `(srfi 27)` compatibility aliases. |
| `(stdlib random-data-generators)` | implemented | Vendored adapted SRFI 194 sample implementation, recorded in `(stdlib manifest)` | `(stdlib random-data-generators)`, `(srfi 194)`, `(srfi srfi-194)` | Optional SRFI 194 random data generator API built on SRFI 27 random sources and SRFI 158 generators; primary stdlib spelling owns the source and SRFI spellings are compatibility aliases. |
| `(stdlib receive)` | shimmed | Built-in portable shim over R7RS multiple values, recorded in `(stdlib manifest)` | `(stdlib receive)`, `(srfi 8)`, `(srfi srfi-8)`, `(srfi :8)`, `(srfi :8 receive)` | Optional SRFI 8 `receive` syntax for binding multiple values; not part of the R7RS-small baseline. |
| `(stdlib assume)` | shimmed | Built-in portable SRFI 145 shim, recorded in `(stdlib manifest)` | `(stdlib assume)`, `(srfi 145)`, `(srfi srfi-145)` | Optional SRFI 145 `assume` syntax for invalid code paths; not part of the R7RS-small baseline. |
| `(stdlib comparator)` | implemented | Vendored adapted SRFI 128 sample implementation, recorded in `(stdlib manifest)` | `(stdlib comparator)`, `(scheme comparator)`, `(srfi 128)`, `(srfi srfi-128)` | Primary stdlib spelling owns the source; R7RS-large and SRFI spellings are compatibility aliases. |
| `(stdlib mapping)` | implemented | Vendored adapted SRFI 146 ordered mapping implementation, recorded in `(stdlib manifest)` | `(stdlib mapping)`, `(scheme mapping)`, `(srfi 146)`, `(srfi srfi-146)` | Ordered finite mappings over SRFI 128 comparators; primary stdlib spelling owns the source and R7RS-large/SRFI spellings are compatibility aliases. Hash mappings are separate future work. |

## Internal Helpers

| Library | Status | Source | Imports | Notes |
| --- | --- | --- | --- | --- |
| `(stdlib rbtree)` | implemented helper | Vendored adapted SRFI 146 `nieper/rbtree` helper, recorded in `(stdlib manifest)` | `(stdlib rbtree)` | Internal stdlib substrate for ordered SRFI 146 mappings; no R7RS-large or SRFI aliases are exposed for direct user-facing imports. |

The Scheme-readable `(stdlib manifest)` library records source URLs, upstream
revisions, licenses, local patches, import aliases, dependencies, and test
status for stdlib libraries using the shared manifest vocabulary documented in
[Library Surface and Manifests](library-surface.md). Vendored source keeps its
upstream license and local adaptations are listed in the manifest entry,
alongside canonical source, API/source version, provenance, and alias metadata.
`(agent reflect)` exposes the SRFI-facing intake view through
`(vendored-srfi-manifest number)`, which returns a `vendored-srfi` record with
the implementation library, import names, source URL, upstream revision or tag,
license and local-license fields, local patches, dependencies, status, and test
status. Shim records, such as `(srfi 16)`, point at their target library instead
of claiming vendored source; missing SRFIs return a missing record. Child SRFI
implementations remain tracked in their own issues, so this manifest contract
does not imply that the full SRFI-backed stdlib backlog has shipped.
SRFI 261 is represented as a zero-export shim because the SRFI specifies
portable SRFI library-reference names rather than implementation bindings.

Vendored code and adapted upstream test material keep their recorded upstream
license in `scheme/stdlib/manifest.sld`; repository license files and REUSE
annotations preserve the corresponding notices for the proving slice.

`(scheme mapping)` and the SRFI 146 aliases expose only the ordered mapping
interface. `(scheme mapping hash)`, `(srfi 146 hash)`, and
`(srfi srfi-146 hash)` are not registered; the hash mapping variant is tracked
separately after the HAMT substrate lands.
