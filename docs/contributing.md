# Contributing

Consent Scheme keeps project process lightweight, but commit history should be
structured from the outset.

## Issue Lifecycle

All project work should start from a GitHub issue unless it is truly trivial
repository maintenance.

Workflow:

1. Pick or file a GitHub issue.
2. Create a branch for that issue.
3. Confirm the issue's roadmap chunk placement in #53.
4. Retire any newly completed chunk: if an earlier chunk now has every issue
   shipped while still listed in #53's chunk map, migrate it to
   `docs/release-notes.md` and remove its section from #53 as a drive-by in this
   same change. This is a standing invariant checked on every issue, not a
   one-time action at the chunk edge.
5. Make the smallest coherent change that advances the issue.
6. Update the canonical runtime version in `scheme/consent/version.sld`
   to match the roadmap-derived version for that issue.
7. Open a pull request back to `main`.
8. Merge through the pull request after review and verification.

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
- include the roadmap-derived version bump for the issue being advanced
- call out any follow-up work left for the issue
- avoid bundling unrelated issue work into the same branch
- use plain project titles without assistant, tool, vendor, or workflow branding

## Runtime Versioning

Every issue branch updates the canonical runtime version source at
`scheme/consent/version.sld`. The version is roadmap-derived from #53's
flat chunk map.

Each chunk is numbered `Chunk <major>.<minor>` (for example `Chunk 0.15`).
Derive the version `<major>.<minor>.<ordinal>` as:

- major and minor versions: the chunk's dotted number (`Chunk 0.15` → `0.15`)
- ordinal version: the issue's one-based position inside that chunk

The major component is no longer hardcoded to `0`. Future major releases are
sculpted by adding `Chunk 1.0`, `Chunk 1.1`, ... to the chunk map, which yields
the `1.x` version series. The `version.sld` datum shape
`(consent-version <major> <minor> <ordinal>)` is unchanged.

For example, the first issue in `Chunk 0.14` is version `0.14.1`, represented by
the canonical Scheme datum `(consent-version 0 14 1)`; the first issue in a
future `Chunk 1.0` would be `1.0.1`, or `(consent-version 1 0 1)`.

Completed chunks migrate from #53 into `docs/release-notes.md` (see Issue
Lifecycle step 4). Treat this as a standing invariant: on every issue, if an
earlier chunk now has all of its issues shipped while still listed in #53,
migrate it and drop its #53 section in the same change. Do not split a chunk
mid-flight — a chunk with any still-open issue keeps all of its issues, and
their `<major>.<minor>.<ordinal>` positions, in #53 until the whole chunk has
shipped.

If the issue is missing from #53, resolve the roadmap placement before opening
the pull request. If a branch must advance more than one issue, prefer splitting
the branch; otherwise use the latest roadmap position advanced by the PR and
explain that choice in the PR body.

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
docs(architecture): add Consent Scheme threat model

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
