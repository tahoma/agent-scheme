;;; Portable development testing harness tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (development manifest)
        (development testing harness)
        (stdlib testing)
        (stdlib lightweight-testing))

(consent-test-run "Consent testing extension"
  (let ((entry
         (development-library-manifest-ref
          '(development testing harness))))
    (test-assert "harness is publicly manifested" entry)
    (test-equal "harness source path"
                '(path "testing/harness.sld")
                (cadr (assq 'source (cdr entry)))))
  (let ((sample-runner (test-runner-null)))
    (test-runner-pass-count! sample-runner 2)
    (test-runner-xfail-count! sample-runner 1)
    (test-runner-skip-count! sample-runner 3)
    (test-equal
     "Scheme-readable summary"
     '(consent-test-summary
       (suite sample)
       (pass 2)
       (fail 0)
       (xfail 1)
       (xpass 0)
       (skip 3)
       (status pass))
     (consent-test-runner-summary 'sample sample-runner))
    (test-assert "expected failures do not fail a suite"
                 (not (consent-test-runner-failed? sample-runner)))
    (test-runner-xpass-count! sample-runner 1)
    (test-assert "unexpected successes fail a suite"
                 (consent-test-runner-failed? sample-runner)))
  (consent-test-check
   "SRFI 78 checks adapt to SRFI 64" 2
   (check (+ 1 1) => 2)
   (check (reverse '(a b)) => '(b a))))
