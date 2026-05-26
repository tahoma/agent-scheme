;;; agent-scheme-test-test.el --- Helper self-test library tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for the `(agent test)' helper self-test library.

;;; Code:

(require 'ert)
(require 'agent-scheme-eval)
(require 'agent-scheme-result)

(defun agent-scheme-test-test--result-external (source &optional options)
  "Evaluate SOURCE as an Agent Scheme result and return external text."
  (agent-scheme-result->external
   (agent-scheme-eval-source-result source nil options)))

(ert-deftest agent-scheme-test-test-case-group-and-error-results ()
  "Self-tests return Scheme-readable pass, fail, and error records."
  (let ((external
         (agent-scheme-test-test--result-external
          "(import (scheme base) (agent test))
           (define run
             (test-group 'arithmetic
               (test-case 'passes (+ 1 1) 2)
               (test-case 'fails (+ 1 1) 3)
               (test-case 'errors (error \"boom\") 'unused)
               (test-error 'expected-error (error \"boom\") error-object?)))
           (test-run 'arithmetic)")))
    (should (string-match-p (regexp-quote "(status ok)") external))
    (should (string-match-p (regexp-quote "(agent-test-group") external))
    (should (string-match-p (regexp-quote "(name arithmetic)") external))
    (should (string-match-p (regexp-quote "(status fail)") external))
    (should
     (string-match-p
      (regexp-quote
       "(summary (total 4) (pass 2) (fail 1) (error 1) (skipped 0) (budget-exhausted 0))")
      external))
    (should (string-match-p (regexp-quote "(kind case)") external))
    (should (string-match-p (regexp-quote "(kind expected-error)") external))))

(ert-deftest agent-scheme-test-test-yield-failures-emits-agent-event ()
  "Failed self-tests can be yielded through `(agent io)'."
  (let ((external
         (agent-scheme-test-test--result-external
          "(import (scheme base) (agent test) (agent io))
           (define run
             (test-group 'yielding
               (test-case 'bad (+ 1 1) 3)
               (test-error 'expected (error \"boom\") error-object?)))
           (test-yield-failures run)
           'done")))
    (should (string-match-p (regexp-quote "(status ok)") external))
    (should (string-match-p (regexp-quote "(value done)") external))
    (should
     (string-match-p
      (regexp-quote "(events ((yield (agent-test-failures")
      external))
    (should (string-match-p (regexp-quote "(name yielding)") external))
    (should (string-match-p (regexp-quote "(failures ((agent-test-result")
                            external))))

(ert-deftest agent-scheme-test-test-skill-tests-and-srfi64-adaptation ()
  "Skill-attached tests and SRFI 64-style result datums run as one group."
  (let ((external
         (agent-scheme-test-test--result-external
          "(import (scheme base) (agent test))
           (skill-test
            'helper-skill
            '((name source-pass)
              (source \"(import (scheme base)) (+ 20 22)\")
              (expect \"42\")))
           (skill-test
            'helper-skill
            '(srfi-64
              (test-name srfi-pass)
              (result pass)))
           (skill-test-run 'helper-skill)")))
    (should (string-match-p (regexp-quote "(status ok)") external))
    (should (string-match-p (regexp-quote "(name helper-skill)") external))
    (should (string-match-p (regexp-quote "(kind skill)") external))
    (should
     (string-match-p
      (regexp-quote
       "(summary (total 2) (pass 2) (fail 0) (error 0) (skipped 0) (budget-exhausted 0))")
      external))
    (should (string-match-p (regexp-quote "(name source-pass)") external))
    (should (string-match-p (regexp-quote "(name srfi-pass)") external))))

(ert-deftest agent-scheme-test-test-source-budget-exhaustion-is-a-test-status ()
  "Source-string tests classify evaluator budget exhaustion as a test result."
  (let ((external
         (agent-scheme-test-test--result-external
          "(import (scheme base) (agent test))
           (skill-test
           'budget-skill
           '((name budgeted-loop)
              (source \"(define (loop) (loop)) (loop)\")
              (expect ok)
              (options ((max-steps 20)))))
           (skill-test-run 'budget-skill)")))
    (should (string-match-p (regexp-quote "(status ok)") external))
    (should (string-match-p (regexp-quote "(name budgeted-loop)") external))
    (should (string-match-p (regexp-quote "(status budget-exhausted)")
                            external))
    (should
     (string-match-p
      (regexp-quote
       "(summary (total 1) (pass 0) (fail 0) (error 0) (skipped 0) (budget-exhausted 1))")
      external))))

;;; agent-scheme-test-test.el ends here
