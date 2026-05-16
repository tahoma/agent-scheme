# Contributing

Agent Scheme keeps project process lightweight, but commit history should be
structured from the outset.

## Issue Lifecycle

All project work should start from a GitHub issue unless it is truly trivial
repository maintenance.

Workflow:

1. Pick or file a GitHub issue.
2. Create a branch for that issue.
3. Make the smallest coherent change that advances the issue.
4. Open a pull request back to `main`.
5. Merge through the pull request after review and verification.

Branch names must include the issue number. Multiple branches may target the
same issue as long as each branch identifies the issue it belongs to.

Recommended branch patterns:

```text
author-name/issue-1/architecture
author-name/issue-62/test-harness
author-name/issue-12/conformance-fixtures
```

Use a short contributing author name as the branch prefix no matter which tools
the author uses. The prefix should identify who owns the branch; the `issue-N`
segment identifies the work. Do not use assistant, tool, vendor, or workflow
branding in branch names.

Pull requests should:

- target `main`
- reference the issue they advance
- describe the verification that was run
- call out any follow-up work left for the issue
- avoid bundling unrelated issue work into the same branch
- use plain project titles without assistant, tool, vendor, or workflow branding

## Commit Messages

Use the [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
format for non-merge commits:

```text
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

Rules:

- Use one commit for one coherent change.
- Keep the description concise, imperative, and specific.
- Use a lowercase `type`.
- When present, use a short lowercase `scope` that names the affected surface.
- Include a body when the motivation, tradeoff, or design context is not obvious
  from the diff.
- Write footers as git-style trailers: `Token: value`, or `Token #value` when a
  tool expects that form. Use `Refs: #N` for ordinary issue references.
- Mark breaking changes with `!` before the colon, or with a
  `BREAKING CHANGE: description` footer.
- Do not use vague summaries such as `update docs`, `fix stuff`, or `changes`.
- Do not include assistant, tool, vendor, or workflow branding in commit
  messages.

Recommended types:

- `build`: build system, packaging, or dependency changes
- `chore`: maintenance that does not affect runtime behavior
- `ci`: continuous-integration or automation changes
- `docs`: documentation-only changes
- `feat`: new user-facing or runtime behavior
- `fix`: bug fixes
- `perf`: performance improvements
- `refactor`: behavior-preserving code restructuring
- `style`: formatting-only changes
- `test`: test-only changes

Recommended early scopes:

- `architecture`
- `roadmap`
- `reader`
- `datum`
- `eval`
- `base`
- `library`
- `macro`
- `policy`
- `capability`
- `repl`
- `mcp`
- `docs`

Examples:

```text
docs(architecture): add Agent Scheme threat model

Refs: #1
```

```text
feat(reader): parse R7RS bytevector datums

Adds lexical coverage for `#u8(...)` forms and validates byte values before
returning implementation datums.

Refs: #2
```

```text
test(eval): cover tail-recursive budget exhaustion

Refs: #3
```

```text
feat(reader)!: change datum representation for bytevectors

BREAKING CHANGE: bytevectors now use a dedicated implementation record.
Refs: #2
```
