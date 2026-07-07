;;; Fixture manifest root index.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (manifest index)
  (export manifest-index)
  (import (scheme base))
  (begin
    (define manifest-index
      '(((collection . fixture)
         (category . fixture)
         (manifest-library . (fixture manifest))
         (manifest-variable . fixture-manifest)
         (manifest-file . "inventory/fixture.sld")
         (source-root . "payload/libraries/"))))))
