<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Tahoma Toelkes -->

# Data Library Reference Corpus

This directory contains the user specifications for project-owned portable
libraries in the `(data ...)` collection.  Unlike the externally authored SRFI
snapshots under `scheme/stdlib/reference/`, these documents are maintained with
their implementations and describe the public Consent Scheme contracts.

Data manifest `local-reference-documents` paths are relative to
`scheme/data/manifest.sld`, so entries point into this directory as
`reference/...`.

The specifications use the aggregate shape common to Scheme Requests for
Implementation: abstract, rationale, terminology, complete procedure
signatures, examples, complexity guidance, implementation notes, and
copyright.  They are not SRFIs, but are intentionally structured so a useful
interface can be proposed through the SRFI process without first reconstructing
its semantics from implementation code.

## Specifications

- [Persistent AVL trees](avl-tree.md) specifies `(data avl-tree)` and describes
  its optional SRFI 146 integration through `(data mapping avl)`.
- [Transient maps](transient-map.md) specifies `(data transient-map)`, including
  the persistent-container adapter protocol.
