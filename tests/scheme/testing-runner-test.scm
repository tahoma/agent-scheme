;;; Portable developer-facing testing runner tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme file)
        (testing harness)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (field datum name)
  "Return field NAME from DATUM."
  (let ((entry (assq name (cdr datum)))) (and entry (cadr entry))))

(testing-registry-clear!)

(testing-registry-case
 'runner-pass '(fast unit) ("testing-runner-test.scm" 17)
 (test-assert "passing registered body" #t))

(testing-registry-case
 'runner-fail '(slow failure) ("testing-runner-test.scm" 21)
 (test-assert "failing registered body" #f))

(testing-registry-case
 'runner-skip '(slow skip) ("testing-runner-test.scm" 25)
 (test-skip 1)
 (test-assert "skipped registered body" #f))

(testing-registry-case
 'runner-xfail '(slow xfail) ("testing-runner-test.scm" 30)
 (test-expect-fail 1)
 (test-assert "expected registered failure" #f))

;; Result from selecting the passing tagged case.
(define passing-result
  (testing-runner-run
   "runner passing selection"
   (testing-runner-options '("--select" "(tag fast)"))))

;; Result from selecting the unexpected failure case.
(define failing-result
  (testing-runner-run
   "runner failing selection"
   (testing-runner-options '("--select" "(name runner-fail)"))))

;; Result from selecting the skipped case.
(define skipped-result
  (testing-runner-run
   "runner skipped selection"
   (testing-runner-options '("--select" "(name runner-skip)"))))

;; Result from selecting the expected-failure case.
(define xfail-result
  (testing-runner-run
   "runner expected-failure selection"
   (testing-runner-options '("--select" "(name runner-xfail)"))))

;; Short-lived report path for cross-process-style rerun coverage.
(define report-path "testing-runner-test-report.tmp")

;; Result written to the report fixture.
(define persisted-result
  (testing-runner-run
   "runner persisted failure"
   (testing-runner-options
    (list "--select" "(name runner-fail)" "--report" report-path))))

;; Result obtained by reading and rerunning the persisted failure.
(define rerun-result
  (testing-runner-run
   "runner persisted rerun"
   (testing-runner-options (list "--rerun-failed" report-path))))

(if (file-exists? report-path) (delete-file report-path))

(testing-harness-run "Testing runner"
  (test-equal "selector options"
              '(tag fast)
              (cadr
               (assq 'selector
                     (testing-runner-options
                      '("--select" "(tag fast)" "--list")))))
  (test-assert "list option"
               (cadr
                (assq 'list?
                      (testing-runner-options '("--list")))))
  (test-equal "passing run status" 'passed (field passing-result 'status))
  (test-equal "failing run status" 'failed (field failing-result 'status))
  (test-equal "skipped case status" 'skip
              (field (car (field (field skipped-result 'report) 'cases))
                     'status))
  (test-equal "expected-failure case status" 'xfail
              (field (car (field (field xfail-result 'report) 'cases))
                     'status))
  (test-equal "persisted run status" 'failed
              (field persisted-result 'status))
  (test-equal "failed name"
              '(runner-fail)
              (testing-registry-report-failed-names
               (field failing-result 'report)))
  (test-equal "persisted rerun status" 'failed
              (field rerun-result 'status))
  (test-equal "persisted rerun selects failed name"
              '(runner-fail)
              (testing-registry-report-failed-names
               (field rerun-result 'report)))
  (test-assert "selector composition"
               ((testing-runner-selector
                 '(and (tag fast) (not (name absent))))
                (car testing-registry-cases))))
