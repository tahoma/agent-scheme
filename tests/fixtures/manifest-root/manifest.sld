;;; Fixture manifest root index.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (manifest index)
  (export manifest-index)
  (import (scheme base))
  (begin
    (define manifest-index
      '((manifest-index-entry
        (schema-version 1)
        (kind manifest-collection)
        (name fixture)
        (owner consent-core)
        (provider repo-source)
        (collection fixture)
        (category fixture)
        (manifest-library (fixture manifest))
        (manifest-variable fixture-manifest)
        (manifest-file "inventory/fixture.sld")
        (source-root "payload/libraries/")
        (source-kind manifest)
        (api-version internal)
        (source-version runtime)
        (realization manifest)
        (status available)
        (canonical #t))))))
