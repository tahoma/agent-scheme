;;; Fixture source library.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (fixture tool)
  (export fixture-tool
          fixture-documented
          fixture-shared-literal
          fixture-shared-literal-ref
          fixture-template-form-ref
          fixture-template-literal)
  (import (scheme base))
  (begin
    ;; A reader-labelled constant exercises cached source graph isolation.
    (define fixture-shared-literal '#1=(#1# . "fresh"))

    (define (fixture-shared-literal-ref)
      "Return one context-owned realization of a reader-labelled constant."
      fixture-shared-literal)

    (define (fixture-documented)
      "fresh documentation"
      'fixture-documented)

    (define (fixture-template-form-ref)
      "Return a context-owned form that invokes the exported fixture macro."
      '(fixture-template-literal))

    (define-syntax fixture-template-literal
      (syntax-rules ()
        ((_) '#("fresh"))))

    (define (fixture-tool) 'fixture-tool)))
