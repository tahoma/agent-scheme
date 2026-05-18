# Project Skill Bundle

This directory is the repository-owned location for Agent Scheme development
skills. Each skill lives in its own subdirectory with a `SKILL.md` file so the
bundle is easy for agentic tooling to discover without tying the repository to
one client or runtime.

The skills are short workflow guides over the canonical project documents. They
should point to repository docs for durable policy and use task-specific
procedure only where it helps future work avoid missed checks.

## Skills

- [Issue workflow](issue-workflow/SKILL.md): issue selection, branch names,
  dependency notes, commits, pull requests, roadmap updates, and verification.
- [R7RS fixtures](r7rs-fixtures/SKILL.md): fixture fields, status choices,
  oracle metadata, conformance matrix updates, and local R7RS references.
- [Host-boundary review](host-boundary-review/SKILL.md): portable core versus
  Emacs adapter placement, policy-gated effects, opaque handles, and
  Scheme-readable data.
- [Oracle triage](oracle-triage/SKILL.md): `make conformance-oracle`, report
  statuses, optional references, and mismatch interpretation.
- [Naming lint](naming-lint/SKILL.md): public and private identifier checks,
  module/test naming, and documentation example scans.

## Maintenance

- Keep skills concise and progressively disclosed. Link to canonical docs
  instead of duplicating long reference sections.
- Keep examples free of assistant, tool, vendor, and workflow branding.
- Prefer deterministic shell commands inside a skill before adding helper
  scripts. If a helper script becomes worthwhile, add focused tests or document
  the exact smoke check that proves it works.
- Update these skills when their canonical documents change in ways that affect
  contributor workflow.
