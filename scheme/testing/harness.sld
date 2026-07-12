;;; Consent Scheme test-suite orchestration.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (testing harness)
  (export testing-harness-run
          testing-harness-check
          testing-harness-runner-summary
          testing-harness-runner-failed?)
  (import (scheme base)
          (scheme write)
          (stdlib testing)
          (stdlib lightweight-testing))
  (begin
    (define (testing-harness-runner-failed? runner)
      "Return true when RUNNER contains an unexpected result."
      #((parameters
         (runner (type test-runner)
          (description "Completed SRFI 64 test runner.")))
        (returns (type boolean)
         (description "True for an unexpected failure or success."))
        (effects state-read))
      (or (> (test-runner-fail-count runner) 0)
          (> (test-runner-xpass-count runner) 0)))

    (define (testing-harness-runner-summary suite runner)
      "Return a Scheme-readable result summary for SUITE and RUNNER."
      #((parameters
         (suite (type object) (description "Suite name."))
         (runner (type test-runner)
          (description "Completed SRFI 64 test runner.")))
        (returns (type list)
         (description "Portable test result receipt."))
        (effects state-read allocation))
      (list 'testing-harness-summary
            (list 'suite suite)
            (list 'pass (test-runner-pass-count runner))
            (list 'fail (test-runner-fail-count runner))
            (list 'xfail (test-runner-xfail-count runner))
            (list 'xpass (test-runner-xpass-count runner))
            (list 'skip (test-runner-skip-count runner))
            (list 'status
                  (if (testing-harness-runner-failed? runner)
                      'fail
                      'pass))))

    ;; Adapt one group of SRFI 78 checks into a named SRFI 64 assertion.
    (define-syntax testing-harness-check
      (syntax-rules ()
        ((_ name expected-count body ...)
         (begin
           (check-reset!)
           (check-set-mode! 'summary)
           body ...
           (test-assert name (check-passed? expected-count))))))

    ;; Run BODY as SUITE and emit a portable batch result receipt.
    (define-syntax testing-harness-run
      (syntax-rules ()
        ((_ suite body ...)
         (let ((runner (test-runner-simple)))
           (test-with-runner runner
             (test-begin suite)
             body ...
             (test-end suite))
           (let ((summary (testing-harness-runner-summary suite runner)))
             (write summary)
             (newline)
             (if (testing-harness-runner-failed? runner)
                 (error "Consent test suite failed" summary)
                 summary))))))))
