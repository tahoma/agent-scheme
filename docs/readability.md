# Narrow-Width Readability

Consent Scheme uses an 80-column soft limit and a 100-column hard limit for
maintained source, tests, fixtures, build tooling, and workflows. The goal is
reviewable structure: wrap at syntax boundaries, keep data typed, and move
substantial embedded programs into ordinary source files.

Run the gate and its format-class regression suite with:

```sh
make lint-readability
tools/lint-readability.sh --self-test
```

`lint-line-length` remains a compatibility alias. The default `make test`
shards and CI use `lint-readability` directly.

## Scope and limits

The gate checks tracked first-party files under `scheme/`, `lisp/`, `tests/`,
`fixtures/`, `tools/`, `.github/workflows/`, and `Makefile`. It recognizes
Scheme, Emacs Lisp, shell, YAML, Make, and the extensionless command wrappers
in `tools/`.

- Lines through 80 columns pass without annotation.
- Lines from 81 through 100 columns require a machine-visible category and a
  local rationale on the immediately preceding line.
- Lines over 100 columns always fail.
- An annotation with no following soft-limit line is stale and fails.

The supported annotation is:

```text
readability-allow: CATEGORY -- rationale of at least twelve characters
```

Use the host language's comment prefix. `CATEGORY` is one of:

| Category | Use |
| --- | --- |
| `contiguous-datum` | An atomic checksum, number, or other indivisible datum. |
| `external-identifier` | A URL, upstream name, or compatibility identifier. |
| `exact-text` | Text whose spaces and spelling are part of the behavior. |

These are narrow exceptions, not a baseline. Reflow an ordinary expression,
command, selector, or prose line instead of annotating it.

## Formatting decisions

| Content | Representation |
| --- | --- |
| One Scheme datum | Keep it as a structured datum and serialize at use. |
| Several Scheme forms | Store them as structured `forms`; write one per line. |
| Reader-sensitive lexical input | Keep exact `text`, wrapped only when the language preserves its bytes. |
| A substantial Scheme program | Put it in a `.scm` file and reference the file. |
| A shell command | Use shell continuations, arrays, or named intermediate values. |
| A YAML expression | Use a folded scalar and break at expression boundaries. |
| A URL or regular expression | Refactor into pieces when semantics allow; otherwise use a local exception. |
| Generated first-party source | Make the generator emit readable source. |
| Vendored byte-exact material | Record provenance in the exclusion manifest. |

For Scheme strings, use the R7RS escaped-newline form at a word boundary when
the runtime value must not gain a newline. For Emacs Lisp strings, use string
concatenation or an escaped physical newline. Do not split identifiers into
multiple tokens.

Generated output is not exempt merely because it is generated. The generator
owns line shape and should emit the same readable layout expected of authored
source. Exact upstream corpora are the exception.

## Provenance exclusions

`tools/readability-exclusions.txt` is the reviewed exclusion manifest. Each
entry records a directory prefix, whether the material is byte-exact or
verbatim, the provenance record, and a rationale. The gate validates that
shape before scanning files.

Only vendored or generated material whose bytes must remain unchanged belongs
there. First-party fixtures, generated compiler entry points, embedded Scheme,
workflow scripts, and Make recipes remain in scope.

## Metrics

The gate reports the checked and excluded file counts, repository-wide soft
and hard inventories, allowed soft exceptions, and changed-line inventories.
For the issue #962 migration, the same gate measured:

| Snapshot | Lines over 80 | Lines over 100 |
| --- | ---: | ---: |
| `origin/main` before migration | 2,013 | 601 |
| Remediated tree | 21 | 0 |

All 21 remaining soft-limit lines are locally classified exceptions. There is
no per-line legacy baseline.
