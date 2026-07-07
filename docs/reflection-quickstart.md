# Reflection Quickstart

Consent Scheme reflection is meant to be used from ordinary Scheme code. The
procedures in `(agent reflect)` return Scheme-readable datums, so the same
queries work in a REPL, a script, a test, or an agent-authored helper library.

Start by importing the reflection library:

```scheme
(import (scheme base)
        (agent reflect))
```

Most records use a common shape: the first symbol names the record kind and the
rest of the list contains named fields. Use `reflection-field` for general
records, `documentation-field` for documentation metadata, and `docstring` when
you only need the user-facing text:

```scheme
(define info (library-info '(agent reflect)))

(reflection-field info 'name)
;; => (agent reflect)

(reflection-field info 'exports '())
;; => (... library-search ... apropos ...)
```

The optional default is used only when the record or field is absent. A field
whose value is `#f` still returns `#f`.

## Search First

Use `apropos` when you have a word and want the runtime to find relevant
bindings or libraries:

```scheme
(map (lambda (match)
       (list (reflection-field match 'kind)
             (reflection-field match 'name)
             (reflection-field match 'summary #f)))
     (apropos "json"))
```

`apropos` combines three discovery inputs:

- documented bindings in the current interaction environment
- library catalog metadata, including names, aliases, source paths,
  categories, and exports
- exported binding names from libraries registered in the current context

Binding matches report `(kind binding)` and library matches report
`(kind library)`. This makes `apropos` the first tool to reach for in a REPL
when you remember a concept but not the exact binding or library name.

## Inspect A Binding

`documentation` returns a `documentation-metadata` record for a binding symbol,
binding name string, or procedure value:

```scheme
(define (needle-procedure x)
  "Return the needle value."
  x)

(documentation 'needle-procedure)
;; =>
;; (documentation-metadata
;;   (subject (binding needle-procedure))
;;   (kind procedure)
;;   ...
;;   (fields
;;     ((arguments (x))
;;      (documentation "Return the needle value."))))
```

Use `docstring` when the plain documentation string is enough:

```scheme
(docstring 'needle-procedure)
;; => "Return the needle value."

(docstring 'missing 'not-found)
;; => not-found
```

Use `documentation-field` when you need structured metadata:

```scheme
(define doc (documentation 'needle-procedure))

(documentation-field doc 'arguments '())
;; => (x)

(documentation-field doc 'documentation)
;; => "Return the needle value."
```

`consent-doc` returns the same metadata as `documentation`. `consent-describe`
adds binding-level context, including the binding kind, value kind, source, and
nested documentation when it is available.

## Explore Libraries

The library catalog is separate from the current imports. Catalog queries
describe known libraries without importing them into the caller's environment:

```scheme
(library-info '(agent reflect))
;; => (library-info (name (agent reflect)) ...)

(map (lambda (info)
       (reflection-field info 'name))
     (library-search "reflect"))
;; => ((agent reflect) ...)

(map (lambda (info)
       (reflection-field info 'name))
     (library-search "json"))
;; => ((stdlib json) (consent json) ...)
```

`library-info` returns one record or `#f`. `libraries` returns all cataloged
records. `library-search` searches names, aliases, categories, source paths, and
exports.

Useful fields on `library-info` records include:

- `name`: the library name datum, such as `(agent reflect)`
- `category`: broad library family, such as `agent`, `scheme`, or `stdlib`
- `status`: implementation status
- `source-kind`: implementation source kind, such as `portable-source`,
  `base-snapshot`, `primitive`, `alias`, `manifest`, `ad-hoc`, or
  `manifest-root`
- `source-file`: repo-relative source path when known
- `aliases`: alternate library names
- `target`: target library for aliases
- `exports`: exported binding names
- `dependencies`: declared dependencies when known
- `origin` and `source-id`: the catalog source that supplied the record
- `summary`: a short library summary when the manifest supplies one

## Cross From Bindings To Libraries

Use `binding-libraries` when you know a binding name and want to know which
libraries export it:

```scheme
(map (lambda (info)
       (reflection-field info 'name))
     (binding-libraries 'force))
;; => ((scheme lazy))
```

This combines catalog metadata with libraries registered in the current
evaluation context. Catalog metadata lets it find libraries that are not
currently imported; the context registry lets it report ad-hoc REPL libraries
that were defined without a related manifest.

When you know the library and want its exported documentation, use
`library-documentation`:

```scheme
(map (lambda (doc)
       (list (reflection-field doc 'subject)
             (docstring doc #f)))
     (library-documentation '(scheme lazy)))
```

`library-documentation` resolves the library in a private reflection context. It
does not add that library to the caller's `current-imports`.

## Register A Local Manifest

Ad-hoc manifest datums let a REPL session, test, or helper script describe
project-local libraries before they are checked into the built-in catalog:

```scheme
(add-manifest!
 'scratch
 '(library-catalog
   (library
    (name (project generated))
    (category project)
    (status experimental)
    (source-kind ad-hoc)
    (aliases ((project generated alias)))
    (exports (generated-run))
    (dependencies ((scheme base)))
    (summary "Generated project library."))))

(reflection-field (library-info '(project generated)) 'summary)
;; => "Generated project library."

(map (lambda (info)
       (reflection-field info 'name))
     (binding-libraries 'generated-run))
;; => ((project generated))

(remove-manifest! 'scratch)
```

Explicit manifest-root inputs use the same manifest datum shape, but their
source identity is a root string:

```scheme
(add-manifest-root!
 "project-reflection"
 '(library-catalog
   (library
    (name (project rooted))
    (category project)
    (status available)
    (source-kind manifest-root)
    (exports (rooted-run))
    (summary "Root manifest library."))))

(catalog-sources)
(catalog-diagnostics)

(remove-manifest-root! "project-reflection")
```

Use `refresh-library-catalog!` after changing catalog inputs outside the normal
add/remove helpers. `catalog-diagnostics` reports Scheme-readable issues such
as lower-precedence duplicate libraries shadowed by a higher-precedence source.

## Keep The Surfaces Straight

Reflection intentionally separates live environment discovery from library
catalog discovery:

- Live environment: `documentation`, `consent-doc`, `consent-describe`,
  `documented-bindings`, `docstring`, `current-imports`, and
  `library-bindings`
- Library catalog: `libraries`, `library-info`, `library-search`,
  `library-documentation`, `catalog-sources`, `catalog-diagnostics`, and the
  manifest add/remove helpers
- Mixed search: `apropos` and `binding-libraries`, which combine catalog
  metadata with current-context definition or library registry data

Catalog records are metadata, not authority. Adding a manifest or manifest-root
input does not import, load, or execute source code, and it does not grant a
host capability. Calling a reflected host capability still goes through grants,
policy checks, redaction, and audit.

For a step-by-step workflow, see
[Runtime Definition Discovery Tutorial](runtime-definition-discovery.md).
For the full reference surface, see
[Feature and Host Reflection](feature-reflection.md). For macro expansion
records in particular, see
[Macro Expansion Introspection](macro-introspection.md).
