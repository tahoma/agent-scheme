# Runtime Definition Discovery Tutorial

This tutorial shows how to discover the definition surface available to a
running Consent Scheme session. The core idea is to combine three views:

- live bindings in the current evaluator context
- registered libraries in the current evaluator context
- manifest-backed catalog metadata

Those views intentionally overlap but do not replace each other. A manifest can
describe a library before it is imported. A library can also exist without any
manifest at all, such as a library defined ad hoc in a REPL with
`define-library`.

## Start With Reflection

Import `(agent reflect)` alongside `(scheme base)`:

```scheme
(import (scheme base)
        (agent reflect))
```

Reflection records are ordinary Scheme datums. Most records have a leading tag
and named fields. Use `reflection-field` to read those fields:

```scheme
(define (names records)
  (map (lambda (record)
         (reflection-field record 'name))
       records))
```

## Ask A Definition-First Question

When you remember a word but not the exact binding, start with `apropos`:

```scheme
(names (apropos "reflect"))
;; => (... library-search binding-libraries apropos ...)
```

`apropos` searches definitions first. It combines:

- documented bindings in the current interaction environment
- exported binding names from manifest catalog records
- exported binding names from libraries registered in the current context

Each binding match carries a `libraries` field when reflection can identify the
library or libraries exporting that binding:

```scheme
(map (lambda (match)
       (list (reflection-field match 'name)
             (reflection-field match 'libraries '())))
     (apropos "binding-libraries"))
;; => ((binding-libraries ((agent reflect))))
```

This is the REPL-friendly path: ask for a definition, then use the attached
library provenance to decide what to import or inspect next.

## Inspect Live Bindings

Bindings defined in the current interaction environment are visible even when
they are not part of a library:

```scheme
(define (scratch-normalize value)
  "Return VALUE normalized for the current experiment."
  value)

(names (apropos "scratch"))
;; => (scratch-normalize)

(docstring 'scratch-normalize)
;; => "Return VALUE normalized for the current experiment."
```

Use `documented-bindings` when you want the current documented interaction
surface instead of a search:

```scheme
(map (lambda (documentation)
       (reflection-field documentation 'subject))
     (documented-bindings))
;; => ((binding scratch-normalize) ...)
```

## Cross From Bindings To Libraries

When you know a binding name, use `binding-libraries` to discover libraries that
export it:

```scheme
(names (binding-libraries 'force))
;; => ((scheme lazy))
```

This uses both catalog metadata and the current evaluator context. Catalog
metadata can name libraries that are not currently imported. The current context
can name libraries that were defined in the session and have no manifest entry.

## Inspect The Current Library Registry

`current-imports` reports libraries registered in the current evaluator context:

```scheme
(current-imports)
;; => ((agent reflect) (scheme base) ...)
```

Use `library-bindings` to inspect the exports of an imported or otherwise
registered library:

```scheme
(map (lambda (binding)
       (list (reflection-field binding 'name)
             (reflection-field binding 'kind)
             (reflection-field binding 'library)))
     (library-bindings '(agent reflect)))
;; => ((apropos value (agent reflect)) ...)
```

This is live registry inspection. It does not require a manifest record for the
library, but the library must already be registered in the current context.

## Search Manifest Catalog Metadata

Use `library-search` when your question is about library containers rather than
individual definitions:

```scheme
(names (library-search "json"))
;; => ((stdlib json) (consent json) ...)
```

Use `library-info` when you know the library name:

```scheme
(define json-info (library-info '(stdlib json)))

(reflection-field json-info 'source-kind)
;; => portable-source

(reflection-field json-info 'exports)
;; => (json-number-of-character-limit ... json-read ... json-write)
```

`libraries`, `library-info`, and `library-search` are catalog queries. They read
manifest-backed metadata and explicit ad-hoc catalog inputs; they do not import,
load, or execute source.

## Try An Unmanifested Library

A user library can exist without any manifest. Define one directly in the
session:

```scheme
(define-library (scratch live)
  (export scratch-run)
  (import (scheme base))
  (begin
    (define (scratch-run value)
      "Return VALUE from a live scratch library."
      value)))

(import (scratch live))
```

The library is importable because it is registered in the evaluator context, not
because the catalog knows about it:

```scheme
(library-info '(scratch live))
;; => #f

(scratch-run 'ok)
;; => ok
```

Definition-first tools still find it:

```scheme
(names (binding-libraries 'scratch-run))
;; => ((scratch live))

(map (lambda (match)
       (list (reflection-field match 'name)
             (reflection-field match 'libraries '())))
     (apropos "scratch-run"))
;; => ((scratch-run ((scratch live))))
```

This is the important boundary: manifests improve catalog discovery, but they do
not own the entire dynamic runtime definition surface.

## Add Temporary Manifest Metadata

If the scratch library becomes useful, you can add a temporary catalog manifest
without changing import authority:

```scheme
(add-manifest!
 'scratch-session
 '(library-catalog
   (library
    (name (scratch live))
    (category scratch)
    (status experimental)
    (source-kind ad-hoc)
    (exports (scratch-run))
    (summary "Live scratch library from this session."))))
```

Now library-container discovery can see it too:

```scheme
(reflection-field (library-info '(scratch live)) 'summary)
;; => "Live scratch library from this session."

(names (library-search "scratch"))
;; => ((scratch live))
```

The manifest is still metadata. Removing it does not unregister the live
library:

```scheme
(remove-manifest! 'scratch-session)

(library-info '(scratch live))
;; => #f

(scratch-run 'still-here)
;; => still-here
```

## Inspect Catalog Inputs

Use `catalog-sources` to see where catalog metadata is coming from:

```scheme
(catalog-sources)
;; => ((catalog-source (kind ad-hoc) ...)
;;     (catalog-source (kind built-in-seed) ...))
```

Use `catalog-diagnostics` after adding manifests or roots:

```scheme
(catalog-diagnostics)
;; => ()
```

Duplicate catalog records are diagnostics, not import-time authority changes.
Higher-precedence catalog inputs can shadow lower-precedence metadata, but they
do not redefine already registered libraries.

## Choose The Right Query

- Use `apropos` first when you are looking for definitions.
- Use `documentation`, `docstring`, and `documented-bindings` for live
  interaction-environment bindings.
- Use `binding-libraries` to cross from a binding name to cataloged or currently
  registered libraries that export it.
- Use `current-imports` and `library-bindings` for the current evaluator
  registry.
- Use `libraries`, `library-info`, and `library-search` for manifest-backed
  catalog metadata.
- Use `add-manifest!`, `add-manifest-root!`, `catalog-sources`, and
  `catalog-diagnostics` to inspect or extend discovery metadata.

For the full reference surface, see
[Feature and Host Reflection](feature-reflection.md). For a compact API tour,
see [Reflection Quickstart](reflection-quickstart.md). For the manifest
ownership boundary, see [Library Surface and Manifests](library-surface.md).
