# Stdlib-Plus Libraries

Consent Scheme treats SRFI and R7RS-large libraries as optional `stdlib-plus`
support above the R7RS-small conformance contract. The R7RS-small status remains
tracked in [R7RS-Small Conformance Matrix](r7rs-conformance.md); this page
tracks optional library support that is useful to programs and later runtime
features without making it part of that baseline. Source-backed stdlib-plus
libraries live under `scheme/stdlib-plus/`; SRFI names are public import aliases
and provenance metadata, not a separate source-tree layer.

## Implemented Libraries

| Library | Status | Source | Imports | Notes |
| --- | --- | --- | --- | --- |
| `(srfi 180)` | implemented | Local portable implementation, recorded in `(srfi manifest)` | `(srfi 180)`, `(srfi srfi-180)`, `(consent json)` | JSON boundary codec used by tool-calling and protocol edges. |
| `(scheme comparator)` | implemented | Vendored adapted SRFI 128 sample implementation, recorded in `(srfi manifest)` | `(scheme comparator)`, `(srfi 128)`, `(srfi srfi-128)` | Canonical spelling follows R7RS-large; SRFI spellings are secondary compatibility aliases. |

The Scheme-readable `(srfi manifest)` library records source URLs, upstream
revisions, licenses, local patches, import aliases, dependencies, and test
status for stdlib-plus libraries. Vendored source keeps its upstream license and
local adaptations are listed in the manifest entry.
