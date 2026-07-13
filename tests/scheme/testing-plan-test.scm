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

(define (program-tagged? program tag)
  "Return true when PROGRAM carries TAG."
  (if (memq tag (testing-plan-program-tags program)) #t #f))

(define (program-count-with-tag programs tag)
  "Return the number of PROGRAMS carrying TAG."
  (let loop ((rest programs) (count 0))
    (if (null? rest)
        count
        (loop (cdr rest)
              (+ count (if (program-tagged? (car rest) tag) 1 0))))))

(define (full-program-self-host-classified? program)
  "Return true when every full PROGRAM is either compiled or a named gap."
  (if (program-tagged? program 'full)
      (let ((compiled? (program-tagged? program 'compiled))
            (gap? (program-tagged? program 'self-host-gap)))
        (or (and compiled? (not gap?))
            (and gap? (not compiled?))))
      #t))

(define (every predicate values)
  "Return true when PREDICATE accepts every member of VALUES."
  (or (null? values)
      (and (predicate (car values))
           (every predicate (cdr values)))))

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
  (test-equal "evaluator shard isolates the measured bottleneck"
              '("tests/scheme/consent-eval-test.scm")
              (testing-plan-files project-plan 'full-evaluator))
  (test-assert "support shard excludes the evaluator bottleneck"
               (not (member "tests/scheme/consent-eval-test.scm"
                            (testing-plan-files project-plan 'full-support))))
  (let ((programs (testing-plan-programs project-plan))
        (compiled-files (testing-plan-files project-plan 'compiled)))
    (test-equal "compiled project shard program count" 38
                (length compiled-files))
    (test-assert "compiled project shard includes registered semantics"
                 (member "tests/scheme/consent-context-test.scm"
                         compiled-files))
    (test-assert "compiled project shard includes JSON reference stress"
                 (member "tests/scheme/stdlib-json-reference-test.scm"
                         compiled-files))
    (test-assert "compiled project shard includes runtime manifest smoke"
                 (member "tests/scheme/consent-manifest-smoke-test.scm"
                         compiled-files))
    (test-equal "programs admitted to compiled self-host" 38
                (program-count-with-tag programs 'compiled))
    (test-equal "ordinary full-suite programs" 55
                (program-count-with-tag programs 'full))
    (test-equal "full programs carrying an explicit self-host gap" 18
                (program-count-with-tag programs 'self-host-gap))
    (test-assert "full programs exactly partition compiled coverage and gaps"
                 (every full-program-self-host-classified? programs)))
  (test-equal "compiled live shard uses the self-hosted program"
              '("tests/scheme/consent-models-compiled-live-test.scm")
              (testing-plan-files project-plan 'live-compiled))
  (let ((entry (testing-library-manifest-ref '(testing plan))))
    (test-assert "plan library is publicly manifested" entry)
    (test-equal "plan library source"
                '(path "plan.sld")
                (cadr (assq 'source (cdr entry))))))
