;;; Fixture source library.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (fixture tool)
  (export fixture-tool)
  (import (scheme base))
  (begin
    (define (fixture-tool) 'fixture-tool)))
