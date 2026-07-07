;;; Fixture collection manifest.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (fixture manifest)
  (export fixture-manifest)
  (import (scheme base))
  (begin
    (define fixture-manifest
      '(((library . (fixture tool))
         (visibility . public)
         (layer . fixture)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "tool.sld")
         (implementation-library . (fixture tool))
         (exports . (fixture-tool))
         (owner . fixture)
         (provider . fixture)
         (dependencies . ((scheme base))))))))
