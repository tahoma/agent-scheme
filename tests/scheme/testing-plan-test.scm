;;; Portable multi-program test-plan tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (testing manifest)
        (testing harness)
        (testing plan)
        (testing runner)
        (stdlib testing))

;; Small plan exercising selection independently of the repository inventory.
(define sample-plan
  '(testing-plan
    (version 1)
    (programs
     ((program (path "fast.scm") (tags (full fast)))
      (program (path "slow.scm") (tags (full slow)))
      (program (path "compiled.scm") (tags (compiled slow)))))
    (shards
     ((shard (name full) (selector (tag full)))
      (shard
       (name fast)
       (selector (and (tag full) (not (tag slow)))))
      (shard (name compiled) (selector (tag compiled)))))))

;; Checked-in project plan used for integration assertions below.
(define project-plan (testing-plan-read "tests/scheme/test-plan.scm"))

(testing-harness-run "Testing plan"
  (test-assert "valid plan predicate" (testing-plan? sample-plan))
  (test-equal "declared shard names"
              '(full fast compiled)
              (testing-plan-shard-names sample-plan))
  (test-equal "tag selection preserves declaration order"
              '("fast.scm" "slow.scm")
              (testing-plan-files sample-plan 'full))
  (test-equal "composable scheduling selectors"
              '("fast.scm")
              (testing-plan-files sample-plan 'fast))
  (test-equal "runner consumes plan data"
              '("compiled.scm")
              (testing-runner-plan-files
               "tests/scheme/testing-plan-fixture.scm" 'compiled))
  (test-assert
   "invalid duplicate program path is rejected"
   (guard (condition (else #t))
     (testing-plan-validate
      '(testing-plan
        (version 1)
        (programs
         ((program (path "same.scm") (tags (full)))
          (program (path "same.scm") (tags (compiled)))))
        (shards ((shard (name full) (selector (tag full)))))))
     #f))
  (test-assert "project full shard contains registered suites"
               (member "tests/scheme/consent-context-test.scm"
                       (testing-plan-files project-plan 'full)))
  (test-equal "compiled project shard stays compact"
              '("tests/scheme/consent-reader-test.scm"
                "tests/scheme/consent-manifest-smoke-test.scm")
              (testing-plan-files project-plan 'compiled))
  (test-equal "compiled live shard uses the self-hosted program"
              '("tests/scheme/consent-models-compiled-live-test.scm")
              (testing-plan-files project-plan 'live-compiled))
  (let ((entry (testing-library-manifest-ref '(testing plan))))
    (test-assert "plan library is publicly manifested" entry)
    (test-equal "plan library source"
                '(path "plan.sld")
                (cadr (assq 'source (cdr entry))))))
