---
name: consent-issue-workflow
description: Use before starting, committing, or publishing Consent Scheme issue work to follow branch, dependency, roadmap, pull request, and verification conventions.
---

# Issue Workflow

Use this skill when taking on a GitHub issue, preparing commits, updating issue
dependencies, or opening a pull request for Consent Scheme.

## Canonical References

- `AGENTS.md`
- `docs/contributing.md`
- `docs/development.md`
- `docs/roadmap.md`
- `docs/issue-taxonomy.md`
- the GitHub issue being worked

## Workflow

1. Read the issue and confirm whether it is blocked. If new dependencies are
   discovered, record them in the issue body and in GitHub Issues relationship
   metadata when that is available.
2. Check the roadmap issue, `tahoma/consent#53`, when the work changes
   dependency order, phase placement, or graph invariants.
3. Create one branch for the issue using
   `author-name/issue-N/short-name`. Keep assistant, tool, vendor, and workflow
   branding out of the branch name.
4. Make the smallest coherent change that advances the issue. Keep unrelated
   cleanups out of the branch.
5. For semantic runtime changes, preserve Emacs Lisp and portable Scheme parity
   when practical. If one side must lead, document the parity follow-up in the
   issue, commit body, or pull request.
6. Run `make test` for implementation, script, fixture, or behavior changes.
   For documentation-only changes, also run:

   ```sh
   git diff --check
   rg -n "m[y]/consent|m[y]/mcp" README.md docs
   ```

   When documentation changes include `skills/`, run the same private-history
   scan over the skill bundle too:

   ```sh
   rg -n "m[y]/consent|m[y]/mcp" skills
   ```

7. Commit one coherent change at a time with Conventional Commits form from
   `docs/contributing.md`. Use `Refs: #N` for ordinary issue references.
8. Open pull requests against `main`. Reference the issue, describe
   verification, and call out any remaining follow-up work.

## Review Checklist

- The branch name includes the issue number and project author prefix.
- The diff is scoped to the issue.
- Public documentation avoids private-machine history and obsolete project
  names except where a canonical document intentionally mentions them.
- The pull request body states exactly which verification commands were run.
