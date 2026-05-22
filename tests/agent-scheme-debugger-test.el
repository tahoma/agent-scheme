;;; agent-scheme-debugger-test.el --- Debugger condition tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for Scheme-readable debugger condition records and the
;; `(agent debugger)' event/restart surface.

;;; Code:

(require 'ert)
(require 'agent-scheme-eval)
(require 'agent-scheme-result)

(defun agent-scheme-debugger-test--result-external (source &optional options)
  "Evaluate SOURCE as a result datum and return its external string."
  (agent-scheme-result->external
   (agent-scheme-eval-source-result source nil options)))

(ert-deftest agent-scheme-debugger-test-unbound-variable-result-has-condition ()
  "Unbound-variable failures produce a structured debugger condition datum."
  (let ((result (agent-scheme-debugger-test--result-external "missing")))
    (should (string-match-p (regexp-quote "(status error)") result))
    (should (string-match-p (regexp-quote "(condition (type unbound-variable)")
                            result))
    (should (string-match-p (regexp-quote "(symbol missing)") result))
    (should (string-match-p (regexp-quote "(phase evaluation)") result))
    (should (string-match-p (regexp-quote "(stack ((frame (id f-0)")
                            result))
    (should (string-match-p (regexp-quote "(environment ((frame f-0)")
                            result))
    (should (string-match-p (regexp-quote "(restarts ((restart (id abort)")
                            result))))

(ert-deftest agent-scheme-debugger-test-current-error-exposes-restarts ()
  "Exception handlers can inspect the current debugger condition restarts."
  (let ((result
         (agent-scheme-debugger-test--result-external
          "(import (scheme base) (agent debugger))
           (with-exception-handler
            (lambda (condition)
              (condition-restarts (current-error)))
            (lambda ()
              (raise-continuable 'boom)))")))
    (should (string-match-p (regexp-quote "(status ok)") result))
    (should (string-match-p (regexp-quote "(restart (id abort)")
                            result))
    (should (string-match-p (regexp-quote "(restart (id continue-with-warning)")
                            result))))

(ert-deftest agent-scheme-debugger-test-debugger-yield-records-event ()
  "Debugger records can be yielded to the outer event channel."
  (let ((result
         (agent-scheme-debugger-test--result-external
          "(import (scheme base) (agent debugger))
           (debugger-yield
            '(condition
              (type synthetic)
              (message \"example\")))
           'done")))
    (should (string-match-p (regexp-quote "(status ok)") result))
    (should (string-match-p (regexp-quote "(value done)") result))
    (should
     (string-match-p
      (regexp-quote
       "(events ((debugger (condition (type synthetic) (message \"example\")))))")
      result))))

;;; agent-scheme-debugger-test.el ends here
