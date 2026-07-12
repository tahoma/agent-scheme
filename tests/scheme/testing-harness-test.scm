;;; Portable testing harness tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (testing manifest)
        (testing harness)
        (stdlib testing)
        (stdlib lightweight-testing))

(testing-harness-run "Testing harness"
  (let ((entry
         (testing-library-manifest-ref
          '(testing harness))))
    (test-assert "harness is publicly manifested" entry)
    (test-equal "harness source path"
                '(path "harness.sld")
                (cadr (assq 'source (cdr entry)))))
  (let ((sample-runner (test-runner-null)))
    (test-runner-pass-count! sample-runner 2)
    (test-runner-xfail-count! sample-runner 1)
    (test-runner-skip-count! sample-runner 3)
    (test-equal
     "Scheme-readable summary"
     '(testing-harness-summary
       (suite sample)
       (pass 2)
       (fail 0)
       (xfail 1)
       (xpass 0)
       (skip 3)
       (status pass))
     (testing-harness-runner-summary 'sample sample-runner))
    (test-assert "expected failures do not fail a suite"
                 (not (testing-harness-runner-failed? sample-runner)))
    (test-runner-xpass-count! sample-runner 1)
    (test-assert "unexpected successes fail a suite"
                 (testing-harness-runner-failed? sample-runner)))
  (testing-harness-check
   "SRFI 78 checks adapt to SRFI 64" 2
   (check (+ 1 1) => 2)
   (check (reverse '(a b)) => '(b a))))
