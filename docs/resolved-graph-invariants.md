# Resolved Graph Invariants

Roadmap dependency-graph invariants (from
[tahoma/agent-scheme#53](https://github.com/tahoma/agent-scheme/issues/53))
whose referenced issues are **all closed** are archived here — mirroring the
migration of completed chunks 0.00-0.14 into `release-notes.md`. They are kept for
historical and dependency-rationale reference; the live roadmap issue retains only
invariants with at least one open referenced issue, plus standing structural rules.

Migrated 2026-05-31 (under issue #376 / PR #377).

## Invariants

- Roadmap metadata cleanup (#295) should keep labels, dependency metadata, and GitHub sub-issue relationships aligned with the taxonomy and issue prose without changing implementation scope.
- Unit test harness (#62) should precede conformance fixtures (#12) and implementation tickets such as tahoma/agent-scheme#2.
- GitHub Actions (#69) should continue to run the same `make test` command as the local harness.
- CI test splitting and timing reports (#322) should follow #69, keep `make test` as the local aggregate command, and make the Emacs-hosted and portable Chibi-backed validation paths visible as first-class CI shards before later test-suite growth hides their relative cost.
- CI shard rebalancing (#325) should follow #322 and wait for at least five CI runs with shard timing summaries so the second-pass split is based on observed wall time, ERT time, result counts, skip counts, and slowest-test data rather than a one-off local estimate.
- Docstring retention modes (#358) should follow #300, #301, #303, #344, and #325 so runtime retention tradeoffs are handled separately from CI shard rebalancing while preserving the default documentation reflection surface.
- Gambit host-compiled executable work (#273) should follow #325 and the initial `make compile` packaging scaffolding (#270), build on the interpreted Gambit host signal from #271, keep generated `gsc` artifacts under the build tree, and stay focused on Gambit compile/run coverage before broader executable variants.
- Getting started documentation (#264) should stay aligned with the native Emacs REPL UX (#20), development setup, and non-Emacs host status; it should describe planned host contracts as planned rather than usable first-use paths.
- Shared base prelude work (#73) should follow the first `(scheme base)` slice (#4) and stay distinct from full standard-library completion (#19).
- Shared fixture corpus (#92) should follow the unit harness (#62), conformance matrix (#12), reader (#2), and evaluator kernel (#3), then precede oracle, mining, and coverage-expansion work such as tahoma/agent-scheme#93, tahoma/agent-scheme#94, and tahoma/agent-scheme#95.
- Reference oracle work (#93) should come before broad external-suite mining (#94) when mined cases need comparison against available implementations.
- Gambit host parity (#271) should follow #93 and establish optional R7RS host behavior before Gambit executable packaging (#273).
- Conformance coverage audit (#95) should consume mined cases from #94 where useful and should keep policy-gated, unspecified, variant, and Agent-specific cases explicit.
- Inline implementation documentation (#77) should wait until the macro expansion surface (#13) has settled enough to avoid immediate comment churn.
- Scheme source documentation rules (#96) should complement #77 and settle before large module refactors such as tahoma/agent-scheme#100.
- Existing Scheme source documentation application (#106) should follow #96 and stay related to inline implementation documentation (#77) without changing runtime behavior.
- Pass-oriented architecture (#97) should precede primitive/effect metadata (#98), evaluator module refactors (#100), and backend effect contracts such as tahoma/agent-scheme#102 and tahoma/agent-scheme#103.
- Primitive/effect metadata (#98) should preserve the kernel versus portable-library boundary and inform derived-library migration (#101), evaluator refactors (#100), and backend effect paths (#103).
- Embedded portable library extraction (#99) and derived portable-library migration (#101) should preserve the library/import semantics from #14 and the base prelude split from #73.
- Policy/audit (#7) should precede mutating capabilities such as tahoma/agent-scheme#6 and tahoma/agent-scheme#8.
- Capability grants (#43) should follow transactional buffer edits (#6), programmable approvals (#30), and session lifecycle (#41) so grant attenuation has concrete capability and session records to constrain.
- Session lifecycle (#41) should precede the user-facing REPL UX (#20), memory scopes (#22), and jobs (#46).
- Policy-gated `(scheme repl)` interaction environment (#313) should follow #18, #19, #20, #41, and #102 so `interaction-environment` can expose only the current authorized session environment while preserving default denial outside a session.
- Capability environment design (#102) should consolidate after policy/audit (#7), session lifecycle (#41), grants (#43), and secrets/redaction (#49), while staying consistent with multi-host boundaries (#55) and pass architecture (#97).
- File and port capability domains (#220 and #221) should follow #102 and preserve the shared request, decision, revocation, handle, and audit vocabulary before later backend effect routing depends on them.
- Process capability work (#222) should follow #102 and the controlled command/window capability surface (#8), and should route process-backed ports through the port capability domain (#221).
- Policy-gated `(scheme time)` clock bindings (#311) should follow #18, #19, #102, and #103 so `current-second`, `current-jiffy`, and `jiffies-per-second` become shared capability requests instead of direct host clock reads or permanent deny-only stubs.
- Shared backend effect path (#103) should follow #102, #97, and #98 before future compiler backends implement host effects.
- Policy-gated mutating VCS operations (#279) should follow the shared VCS contract (#266), preserve the read-only versus mutation split, and route repository-changing actions through explicit authority, policy, and audit records.
- Docstring metadata convention work (#300) should follow multi-host and pass-boundary framing (#55 and #97), simple string docstrings (#301) should follow #300 plus evaluator, library, runtime reflection, and primitive metadata work (#3, #14, #27, #97, and #98), checked-in library adoption (#302) should follow #301, rich documentation property records (#303) should follow #300 and #301 while preserving ordinary R7RS reader behavior, manifest-backed primitive documentation (#344) should follow #98, #301, and #303 while keeping host-registered primitive documentation in the manifest with a distinct origin, and private procedure docstrings in debug views (#341) should follow #301 plus the debugger and Emacs debugger UI work (#44 and #227).
- Full continuation re-entry (#81) should follow the representative control feature slice (#15) before claiming complete continuation behavior in R7RS-small compliance (#19).
- Native Scheme inexact numeric ownership (#84) should follow numeric tower (#16) before claiming complete standard-library behavior in R7RS-small compliance (#19).
- Native Scheme character externalization parity (#83) should follow core data and writer behavior (#17) before ports, read/write, load, and eval policy (#18).
- Multi-host boundaries (#55) should keep Emacs as first host without making Emacs the semantic center.
- Emacs debugger UI (#227) should follow debugger and restart UX (#44) and preserve the portable condition and restart datum surface while adding policy-gated host restart actions.
- Public naming migration (#61) landed as early project-frame cleanup after the architecture named Consent Scheme, and should keep later REPL, MCP, and durable API work from introducing informal identifiers.
- Secrets/redaction (#49) should precede remote-provider routing and persistence/export work.
