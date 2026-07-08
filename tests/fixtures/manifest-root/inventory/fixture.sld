;;; Fixture collection manifest.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (fixture manifest)
  (export fixture-manifest)
  (import (scheme base))
  (begin
    (define fixture-manifest
      '((manifest-entry
        (schema-version 1)
        (kind library)
        (name (fixture tool))
        (owner fixture)
        (provider fixture)
        (visibility public)
        (layer fixture)
        (source-kind source-library)
        (source (path "tool.sld"))
        (api-version (compat 0))
        (source-version unknown)
        (realization portable-source)
        (exports (fixture-tool))
        (dependencies ((library (scheme base))))
        (provenance ((origin repo)))
        (status implemented)
        (canonical #t))))))
