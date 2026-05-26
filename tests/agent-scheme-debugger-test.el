;;; agent-scheme-debugger-test.el --- Debugger condition tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for Scheme-readable debugger condition records and the
;; `(agent debugger)' event/restart surface.

;;; Code:

(require 'ert)
(require 'seq)
(require 'agent-scheme-eval)
(require 'agent-scheme-audit)
(require 'agent-scheme-debugger)
(require 'agent-scheme-policy)
(require 'agent-scheme-result)

(defun agent-scheme-debugger-test--result-external (source &optional options)
  "Evaluate SOURCE as a result datum and return its external string."
  (agent-scheme-result->external
   (agent-scheme-eval-source-result source nil options)))

(defun agent-scheme-debugger-test--actions (overrides)
  "Return policy category actions with OVERRIDES applied."
  (append overrides
          (seq-remove
           (lambda (entry)
             (assq (car entry) overrides))
           agent-scheme-policy-category-actions)))

(defun agent-scheme-debugger-test--condition (&optional context environment)
  "Return a representative debugger condition for CONTEXT and ENVIRONMENT."
  (agent-scheme-debugger-condition-datum
   '(agent-scheme-eval-error "unbound identifier: missing")
   context
   'evaluation
   environment))

(defun agent-scheme-debugger-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'agent-scheme-result->external
          (agent-scheme-audit-recent-entries)))

(defun agent-scheme-debugger-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (agent-scheme-debugger-test--audit-strings)))

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

(ert-deftest agent-scheme-debugger-test-restart-invoke-uses-policy-hook ()
  "restart-invoke! delegates host recovery restarts through policy."
  (let* ((calls nil)
         (agent-scheme-policy-category-actions
          (agent-scheme-debugger-test--actions
           '((debugger-recovery . allow))))
         (agent-scheme-debugger-restart-action-function
          (lambda (restart condition-datum options restart-context)
            (push (list restart condition-datum options restart-context) calls)
            (list (agent-scheme--syntax-symbol "restart-result")
                  (list (agent-scheme--syntax-symbol "id")
                        (agent-scheme--syntax-symbol "retry"))
                  (list (agent-scheme--syntax-symbol "status")
                        (agent-scheme--syntax-symbol "stubbed")))))
         (result
          (agent-scheme-debugger-test--result-external
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

(ert-deftest agent-scheme-debugger-test-view-datum-prepares-safe-ui-record ()
  "Debugger UI data contains summaries, events, restarts, and safe bindings."
  (let* ((environment (agent-scheme-make-empty-environment))
         (context (agent-scheme--new-eval-context '(:session-id "debugger-test"))))
    (agent-scheme--environment-define environment "secret-token"
                                      "sk-debugger-secret")
    (setf (agent-scheme--eval-context-interaction-environment context)
          environment)
    (agent-scheme--record-event!
     context
     (list (agent-scheme--syntax-symbol "debugger")
           (list (agent-scheme--syntax-symbol "condition")
                 (list (agent-scheme--syntax-symbol "type")
                       (agent-scheme--syntax-symbol "synthetic")))))
    (agent-scheme--record-event!
     context
     (list (agent-scheme--syntax-symbol "yield")
           (list (agent-scheme--syntax-symbol "message") "recent yield")))
    (let* ((condition
            (agent-scheme-debugger-test--condition context environment))
           (view (agent-scheme-debugger-view-datum condition context))
           (external (agent-scheme-result->external view)))
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
      (should (string-match-p (regexp-quote "(yield (message \"recent yield\"))")
                              external))
      (should (string-match-p (regexp-quote "(restarts ((restart (id abort)")
                              external)))))

(ert-deftest agent-scheme-debugger-test-display-renders-buffer-sections ()
  "Debugger display opens a special buffer with restart choices as buttons."
  (let* ((context (agent-scheme--new-eval-context nil))
         (condition (agent-scheme-debugger-test--condition context)))
    (agent-scheme--record-event!
     context
     (list (agent-scheme--syntax-symbol "log")
           (list (agent-scheme--syntax-symbol "message") "from result stream")))
    (let ((buffer (agent-scheme-debugger-display condition context)))
      (unwind-protect
          (with-current-buffer buffer
            (should (derived-mode-p 'agent-scheme-debugger-mode))
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
                          button 'agent-scheme-debugger-restart-id)
                         "continue-with-warning"))
                  (goto-char (button-end button)))
                (unless found
                  (goto-char
                   (or (next-single-property-change
                        (point) 'button nil (point-max))
                       (point-max)))))
              (should found)))
        (kill-buffer buffer)))))

(ert-deftest agent-scheme-debugger-test-denied-host-restart-audits-and-stops ()
  "Denied host-effecting restarts audit denial and do not call the host stub."
  (let* ((context (agent-scheme--new-eval-context nil))
         (condition (agent-scheme-debugger-test--condition context))
         (called nil)
         (agent-scheme-policy-category-actions
          (agent-scheme-debugger-test--actions
           '((debugger-recovery . deny))))
         (agent-scheme-debugger-restart-action-function
          (lambda (&rest _arguments)
            (setq called t)
            (error "restart action must not run"))))
    (agent-scheme-audit-clear)
    (should-error
     (agent-scheme-debugger-invoke-restart condition 'retry nil context)
     :type 'agent-scheme-policy-error)
    (should-not called)
    (should
     (agent-scheme-debugger-test--audit-entry-matching
      "(event debugger-restart)"
      "(category debugger-recovery)"
      "(restart-id retry)"
      "(decision denied)"))))

(ert-deftest agent-scheme-debugger-test-allowed-host-restart-runs-stub-and-events ()
  "Allowed host-effecting restarts call the host stub and record an event."
  (let* ((context (agent-scheme--new-eval-context nil))
         (condition (agent-scheme-debugger-test--condition context))
         (calls nil)
         (agent-scheme-policy-category-actions
          (agent-scheme-debugger-test--actions
           '((debugger-recovery . allow))))
         (agent-scheme-debugger-restart-action-function
          (lambda (restart condition-datum options restart-context)
            (push (list restart condition-datum options restart-context) calls)
            (list (agent-scheme--syntax-symbol "restart-result")
                  (list (agent-scheme--syntax-symbol "id")
                        (agent-scheme--syntax-symbol "retry"))
                  (list (agent-scheme--syntax-symbol "status")
                        (agent-scheme--syntax-symbol "stubbed"))))))
    (agent-scheme-audit-clear)
    (let* ((result
            (agent-scheme-debugger-invoke-restart
             condition
             'retry
             (list (list (agent-scheme--syntax-symbol "reason") "again"))
             context))
           (result-external (agent-scheme-result->external result))
           (events-external
            (agent-scheme-result->external
             (agent-scheme--context-events context))))
      (should (= (length calls) 1))
      (should (string-match-p (regexp-quote "(status stubbed)")
                              result-external))
      (should (string-match-p (regexp-quote "(debugger-restart")
                              events-external))
      (should
       (agent-scheme-debugger-test--audit-entry-matching
        "(event debugger-restart)"
        "(category debugger-recovery)"
        "(restart-id retry)"
        "(decision completed)")))))

(ert-deftest agent-scheme-debugger-test-continue-with-warning-stays-direct ()
  "continue-with-warning stays a portable direct restart path."
  (let* ((context (agent-scheme--new-eval-context nil))
         (condition (agent-scheme-debugger-test--condition context))
         (called nil)
         (agent-scheme-debugger-restart-action-function
          (lambda (&rest _arguments)
            (setq called t)
            (error "direct restart must not call host action"))))
    (let* ((result
            (agent-scheme-debugger-invoke-restart
             condition
             'continue-with-warning
             (list (list (agent-scheme--syntax-symbol "warning")
                         "kept going"))
             context))
           (external (agent-scheme-result->external result)))
      (should-not called)
      (should (string-match-p (regexp-quote "(id continue-with-warning)")
                              external))
      (should (string-match-p (regexp-quote "(status continued)")
                              external)))))

;;; agent-scheme-debugger-test.el ends here
