;;; Fixture source library.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (fixture tool)
  (export fixture-tool fixture-shared-literal)
  (import (scheme base))
  (begin
    ;; A reader-labelled constant exercises cached source graph isolation.
    (define fixture-shared-literal '#1=(#1# . "fresh"))

    (define (fixture-tool) 'fixture-tool)))
