# GitHub Issue Taxonomy

Consent Scheme uses GitHub labels to describe where an issue can be worked and
how much coordination it needs. Labels are intentionally generic so they remain
appropriate for a public repository and can apply to open and closed issues.

## Labels, Not Project Fields

Use labels as the source of truth for now. A GitHub Project single-select field
would enforce exclusive choices, but it adds another maintenance surface and is
less visible from ordinary issue lists, searches, and pull requests.

The `surface:*` axis is exclusive by convention: each issue should have exactly
one surface label. Roadmap timing is tracked by the chunk map in
[tahoma/agent-scheme#53](https://github.com/tahoma/agent-scheme/issues/53),
not by the old `phase:*` labels. If the project later needs stronger
enforcement, mirror these labels or chunk placements into GitHub Project
single-select fields instead of inventing a second vocabulary.

## Required Labels

### Surface

The surface label answers where a contributor can work on the issue.

| Label | Use for |
| --- | --- |
| `surface:r7rs-portable` | Portable Scheme, data, fixtures, references, or libraries that can be developed without a specialized host adapter. |
| `surface:portable-core+adapter` | Consent Scheme core runtime work that may need both portable Scheme and bootstrap or host-adapter changes. |
| `surface:specialized-host` | Emacs, MCP, model/provider, CI, sidecar, or other host-specific integration work. |
| `surface:design` | Architecture, policy, naming, roadmap, taxonomy, or process decisions. |

## Roadmap Chunk Placement

The chunk map in
[tahoma/agent-scheme#53](https://github.com/tahoma/agent-scheme/issues/53)
mirrors the roadmap's current implementation order. Each roadmap issue should
appear in one current chunk unless it is deliberately outside the roadmap.

Do not add new `phase:*` labels. Existing `phase:*` labels are legacy metadata
from the old roadmap model and should be retired through
[tahoma/agent-scheme#295](https://github.com/tahoma/agent-scheme/issues/295)
rather than extended.

## Optional Labels

Use optional labels when they clarify issue selection or review needs.

| Label | Use for |
| --- | --- |
| `risk:low` | Narrow, reversible work with little semantic or integration risk. |
| `risk:medium` | Ordinary implementation or design work with some cross-module coupling. |
| `risk:high` | Work that changes core semantics, security posture, persistence, provider behavior, or large compatibility surfaces. |
| `host:any-r7rs` | Work can be done in portable R7RS Scheme or Scheme-readable data without live host dependencies. |
| `host:agent-runtime` | Work depends on the Consent Scheme runtime, bootstrap evaluator, or shared adapter boundary. |
| `host:emacs` | Work requires Emacs APIs, buffers, windows, commands, or Emacs Lisp UX. |
| `host:external-service` | Work depends on GitHub, CI, model providers, MCP clients, sidecars, or other external services. |
| `size:weekend` | The issue is scoped as a coherent weekend-sized slice. |
| `size:umbrella` | The issue is a coordinating, completion, or policy issue that may need smaller follow-ups. |
| `review:license-vendor` | Work needs explicit license, vendoring, attribution, or third-party source review. |
| `documentation` | The primary deliverable is repository or issue documentation. |

## Maintenance

When creating or revising an issue:

1. Add exactly one `surface:*` label.
2. Confirm the issue appears in the correct chunk in the roadmap issue.
3. Add one risk label when the risk is clear.
4. Add host labels for the environments required to do the work.
5. Add `size:weekend` or `size:umbrella` when it helps contributors choose
   work.
6. Add `review:license-vendor` before importing, copying, bundling, generating,
   or relying on third-party material.
7. Add `documentation` when the main output is documentation rather than runtime
   behavior.

Keep the taxonomy aligned with the roadmap issue. When an issue moves chunks or
is split into follow-ups, update stale labels and roadmap placement in the same
pass.
