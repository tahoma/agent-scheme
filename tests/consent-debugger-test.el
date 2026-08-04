;;; consent-debugger-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for Scheme-readable debugger condition records and the
;; `(agent debugger)' event/restart surface.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-eval)
(require 'consent-audit)
(require 'consent-debugger)
(require 'consent-policy)
(require 'consent-result)

(defun consent-debugger-test--result-external (source &optional options)
  "Evaluate SOURCE as a result datum and return its external string."
  (consent-result->external
   (consent-eval-source-result source nil options)))

(defun consent-debugger-test--actions (overrides)
  "Return policy category actions with OVERRIDES applied."
  (append overrides
          (seq-remove
           (lambda (entry)
             (assq (car entry) overrides))
           consent-policy-category-actions)))

(defun consent-debugger-test--condition (&optional context environment)
  "Return a representative debugger condition for CONTEXT and ENVIRONMENT."
  (consent-debugger-condition-datum
   '(consent-eval-error "unbound identifier: missing")
   context
   'evaluation
   environment))

(defun consent-debugger-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'consent-result->external
          (consent-audit-recent-entries)))

(defun consent-debugger-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (consent-debugger-test--audit-strings)))

(ert-deftest consent-debugger-test-unbound-variable-result-has-condition ()
  "Unbound-variable failures produce a structured debugger condition datum."
  (let ((result (consent-debugger-test--result-external "missing")))
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

(ert-deftest consent-debugger-test-condition-datum-carries-irritants ()
  "Condition datums keep bounded structured irritants for diagnostics."
  (let* ((context (consent--new-eval-context nil))
         (condition
          (consent-debugger-condition-datum
           '(consent-eval-error
             "local model transport failed"
             (model-provider-error
              (status unavailable)
              (provider local-fail)
              (model qwen-coder)
              (transport openai-compatible-http)
              (process
               (process-failure
                (detail "curl: failed")))
              (credentials
               ((api-key "sk-debugger-secret123456")))))
           context))
         (external (consent-result->external condition)))
    (should
     (string-match-p
      (regexp-quote "(irritants ((model-provider-error")
      external))
    (should
     (string-match-p
      (regexp-quote "(provider local-fail)")
      external))
    (should-not (string-match-p "sk-debugger-secret" external))))

(ert-deftest consent-debugger-test-private-procedure-docstring-in-environment
  ()
  "Debugger environment records expose reachable procedure-value docs."
  (let ((result
         (consent-debugger-test--result-external
         "(define (private-helper x)
             \"Explain the private helper for debugger inspection.\"
             x)
           missing"
          '(:docstring-retention full))))
    (should
     (string-match-p
      (regexp-quote "(binding (name private-helper) (procedure-documentation")
      result))
    (should
     (string-match-p
      (regexp-quote "(subject (procedure))")
      result))
    (should
     (string-match-p
      (regexp-quote "(origin (body-literal string))")
      result))
    (should
     (string-match-p
      (regexp-quote
       "(documentation \"Explain the private helper for debugger\
 inspection.\")")
      result))))

(ert-deftest consent-debugger-test-current-error-exposes-restarts ()
  "Exception handlers can inspect the current debugger condition restarts."
  (let ((result
         (consent-debugger-test--result-external
          "(import (scheme base) (agent debugger))
           (with-exception-handler
            (lambda (condition)
              (condition-restarts (current-error)))
            (lambda ()
              (raise-continuable 'boom)))")))
    (should (string-match-p (regexp-quote "(status ok)") result))
    (should (string-match-p (regexp-quote "(restart (id abort)")
                            result))
    (should (string-match-p (regexp-quote
      "(restart (id continue-with-warning)")
                            result))))

(ert-deftest consent-debugger-test-debugger-yield-records-event ()
  "Debugger records can be yielded to the outer event channel."
  (let ((result
         (consent-debugger-test--result-external
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
       "(events ((debugger (condition (type synthetic) (message\
 \"example\")))))")
      result))))

(ert-deftest consent-debugger-test-restart-invoke-uses-policy-hook ()
  "restart-invoke! delegates host recovery restarts through policy."
  (let* ((calls nil)
         (consent-policy-category-actions
          (consent-debugger-test--actions
           '((debugger-recovery . allow))))
         (consent-debugger-restart-action-function
          (lambda (restart condition-datum options restart-context)
            (push (list restart condition-datum options restart-context) calls)
            (list (consent--syntax-symbol "restart-result")
                  (list (consent--syntax-symbol "id")
                        (consent--syntax-symbol "retry"))
                  (list (consent--syntax-symbol "status")
                        (consent--syntax-symbol "stubbed")))))
         (result
          (consent-debugger-test--result-external
           "(import (scheme base) (agent debugger))
            (with-exception-handler
             (lambda (condition)
               (restart-invoke! 'retry '((reason again))))
             (lambda ()
               (raise-continuable 'boom)))")))
    (should (= (length calls) 1))
    (should (string-match-p (regexp-quote "(status ok)") result))
    (should (string-match-p (regexp-quote "(value (restart-result")
                            result))
    (should (string-match-p (regexp-quote "(status stubbed)")
                            result))))

(ert-deftest consent-debugger-test-view-datum-prepares-safe-ui-record ()
  "Debugger UI data contains summaries, events, restarts, and safe bindings."
  (let* ((environment (consent-make-empty-environment))
         (context (consent--new-eval-context '(:session-id "debugger-test"))))
    (consent--environment-define environment "secret-token"
                                      "sk-debugger-secret")
    (setf (consent--eval-context-interaction-environment context)
          environment)
    (consent--record-event!
     context
     (list (consent--syntax-symbol "debugger")
           (list (consent--syntax-symbol "condition")
                 (list (consent--syntax-symbol "type")
                       (consent--syntax-symbol "synthetic")))))
    (consent--record-event!
     context
     (list (consent--syntax-symbol "yield")
           (list (consent--syntax-symbol "message") "recent yield")))
    (let* ((condition
            (consent-debugger-test--condition context environment))
           (view (consent-debugger-view-datum condition context))
           (external (consent-result->external view)))
      (should (string-match-p (regexp-quote "(debugger-view") external))
      (should (string-match-p (regexp-quote "(summary") external))
      (should (string-match-p (regexp-quote "(stack ((frame") external))
      (should (string-match-p (regexp-quote "(environment ((frame f-0)")
                              external))
      (should (string-match-p (regexp-quote "(binding (name secret-token))")
                              external))
      (should-not (string-match-p "sk-debugger-secret" external))
      (should (string-match-p (regexp-quote "(events ((debugger")
                              external))
      (should (string-match-p (regexp-quote
        "(yield (message \"recent yield\"))")
                              external))
      (should (string-match-p (regexp-quote "(restarts ((restart (id abort)")
                              external)))))

(ert-deftest consent-debugger-test-display-renders-buffer-sections ()
  "Debugger display opens a special buffer with restart choices as buttons."
  (let* ((context (consent--new-eval-context nil))
         (condition (consent-debugger-test--condition context)))
    (consent--record-event!
     context
     (list (consent--syntax-symbol "log")
           (list (consent--syntax-symbol "message") "from result stream")))
    (let ((buffer (consent-debugger-display condition context)))
      (unwind-protect
          (with-current-buffer buffer
            (should (derived-mode-p 'consent-debugger-mode))
            (should (string-match-p "Condition" (buffer-string)))
            (should (string-match-p "Stack Frames" (buffer-string)))
            (should (string-match-p "Environment" (buffer-string)))
            (should (string-match-p "Recent Events" (buffer-string)))
            (should (string-match-p "Restart Choices" (buffer-string)))
            (goto-char (point-min))
            (let ((found nil))
              (while (and (not found) (< (point) (point-max)))
                (when-let ((button (button-at (point))))
                  (setq found
                        (equal
                         (button-get
                          button 'consent-debugger-restart-id)
                         "continue-with-warning"))
                  (goto-char (button-end button)))
                (unless found
                  (goto-char
                   (or (next-single-property-change
                        (point) 'button nil (point-max))
                       (point-max)))))
              (should found)))
        (kill-buffer buffer)))))

(ert-deftest consent-debugger-test-denied-host-restart-audits-and-stops ()
  "Denied host-effecting restarts audit denial and do not call the host stub."
  (let* ((context (consent--new-eval-context nil))
         (condition (consent-debugger-test--condition context))
         (called nil)
         (consent-policy-category-actions
          (consent-debugger-test--actions
           '((debugger-recovery . deny))))
         (consent-debugger-restart-action-function
          (lambda (&rest _arguments)
            (setq called t)
            (error "restart action must not run"))))
    (consent-audit-clear)
    (should-error
     (consent-debugger-invoke-restart condition 'retry nil context)
     :type 'consent-policy-error)
    (should-not called)
    (should
     (consent-debugger-test--audit-entry-matching
      "(event debugger-restart)"
      "(category debugger-recovery)"
      "(restart-id retry)"
      "(decision denied)"))))

(ert-deftest consent-debugger-test-allowed-host-restart-runs-stub-and-events ()
  "Allowed host-effecting restarts call the host stub and record an event."
  (let* ((context (consent--new-eval-context nil))
         (condition (consent-debugger-test--condition context))
         (calls nil)
         (consent-policy-category-actions
          (consent-debugger-test--actions
           '((debugger-recovery . allow))))
         (consent-debugger-restart-action-function
          (lambda (restart condition-datum options restart-context)
            (push (list restart condition-datum options restart-context) calls)
            (list (consent--syntax-symbol "restart-result")
                  (list (consent--syntax-symbol "id")
                        (consent--syntax-symbol "retry"))
                  (list (consent--syntax-symbol "status")
                        (consent--syntax-symbol "stubbed"))))))
    (consent-audit-clear)
    (let* ((result
            (consent-debugger-invoke-restart
             condition
             'retry
             (list (list (consent--syntax-symbol "reason") "again"))
             context))
           (result-external (consent-result->external result))
           (events-external
            (consent-result->external
             (consent--context-events context))))
      (should (= (length calls) 1))
      (should (string-match-p (regexp-quote "(status stubbed)")
                              result-external))
      (should (string-match-p (regexp-quote "(debugger-restart")
                              events-external))
      (should
       (consent-debugger-test--audit-entry-matching
        "(event debugger-restart)"
        "(category debugger-recovery)"
        "(restart-id retry)"
        "(decision completed)")))))

(ert-deftest consent-debugger-test-continue-with-warning-stays-direct ()
  "continue-with-warning stays a portable direct restart path."
  (let* ((context (consent--new-eval-context nil))
         (condition (consent-debugger-test--condition context))
         (called nil)
         (consent-debugger-restart-action-function
          (lambda (&rest _arguments)
            (setq called t)
            (error "direct restart must not call host action"))))
    (let* ((result
            (consent-debugger-invoke-restart
             condition
             'continue-with-warning
             (list (list (consent--syntax-symbol "warning")
                         "kept going"))
             context))
           (external (consent-result->external result)))
      (should-not called)
      (should (string-match-p (regexp-quote "(id continue-with-warning)")
                              external))
      (should (string-match-p (regexp-quote "(status continued)")
                              external)))))

;;; consent-debugger-test.el ends here
