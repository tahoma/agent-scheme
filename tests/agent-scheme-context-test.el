;;; agent-scheme-context-test.el --- Current context library tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for the `(agent context)' library: request, focus, region,
;; buffer, project, conversation, privacy, memory, and event-yield behavior.

;;; Code:

(require 'ert)
(require 'seq)
(require 'agent-scheme-audit)
(require 'agent-scheme-context)
(require 'agent-scheme-eval)
(require 'agent-scheme-memory)
(require 'agent-scheme-policy)
(require 'agent-scheme-result)

(defun agent-scheme-context-test--external (datum)
  "Return DATUM as stable Scheme-readable text."
  (agent-scheme-result->external datum))

(defun agent-scheme-context-test--value-external (value)
  "Return VALUE as stable Agent Scheme value text."
  (agent-scheme-value->external value))

(defun agent-scheme-context-test--eval-external (source &optional options)
  "Evaluate SOURCE with OPTIONS and return its external value."
  (agent-scheme-context-test--value-external
   (agent-scheme-eval-source source nil options)))

(defun agent-scheme-context-test--result-external (source &optional options)
  "Evaluate SOURCE with OPTIONS and return its external result datum."
  (agent-scheme-context-test--external
   (agent-scheme-eval-source-result source nil options)))

(defun agent-scheme-context-test--actions (overrides)
  "Return policy category actions with OVERRIDES applied."
  (append overrides
          (seq-remove
           (lambda (entry) (assq (car entry) overrides))
           agent-scheme-policy-category-actions)))

(ert-deftest agent-scheme-context-test-request-and-conversation-options ()
  "Expose supplied request and conversation context as datums."
  (let ((external
         (agent-scheme-context-test--eval-external
          "(import (scheme base) (agent context))
           (list (current-request)
                 (current-conversation-summary)
                 (current-focus))"
          '(:request-id "req-28"
            :request "add current context library"
            :conversation-summary "User asked for issue #28."))))
    (should (string-match-p
             (regexp-quote
              "(request-context (request-id req-28) (request \"add current context library\"))")
             external))
    (should (string-match-p
             (regexp-quote
              "(conversation-summary (summary \"User asked for issue #28.\"))")
             external))
    (should (string-match-p (regexp-quote "(focus-context") external))
    (should (string-match-p (regexp-quote "(request-context") external))))

(ert-deftest agent-scheme-context-test-buffer-region-and-project-context ()
  "Represent live buffer, active region, and project source metadata."
  (let ((default-directory agent-scheme--test-root))
    (with-temp-buffer
      (rename-buffer "agent-scheme-context-buffer" t)
      (setq buffer-file-name
            (expand-file-name "tests/context-example.scm"
                              agent-scheme--test-root))
      (insert "first line\nsecond target\nthird line\n")
      (goto-char (point-min))
      (forward-line 1)
      (set-mark (point))
      (search-forward "target")
      (let ((mark-active t)
            (transient-mark-mode t))
        (let ((external
               (agent-scheme-context-test--eval-external
                "(import (scheme base) (agent context))
                 (list (current-buffer-context)
                       (current-region-context)
                       (current-project-context))")))
          (should (string-match-p (regexp-quote "(buffer-context") external))
          (should (string-match-p
                   (regexp-quote "(name \"agent-scheme-context-buffer\")")
                   external))
          (should (string-match-p
                   (regexp-quote "(file \"")
                   external))
          (should (string-match-p (regexp-quote "(line 2)") external))
          (should (string-match-p
                   (regexp-quote "(line-text \"second target\")")
                   external))
          (should (string-match-p (regexp-quote "(region-context") external))
          (should (string-match-p
                   (regexp-quote "(text \"second target\")")
                   external))
          (should (string-match-p
                   (regexp-quote
                    (format "(root \"%s\")"
                            (file-name-as-directory
                             (expand-file-name agent-scheme--test-root))))
                   external)))))))

(ert-deftest agent-scheme-context-test-missing-context_returns-false ()
  "Return #f for missing request, region, and conversation context."
  (with-temp-buffer
    (should
     (equal
      (agent-scheme-context-test--eval-external
       "(import (scheme base) (agent context))
        (list (current-request)
              (current-region-context)
              (current-conversation-summary))")
      "(#f #f #f)"))))

(ert-deftest agent-scheme-context-test-policy-denies-buffer-context ()
  "Respect read-only policy denial for live buffer context."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-context-test--actions '((emacs-read-only . deny)))))
    (with-temp-buffer
      (should-error
       (agent-scheme-eval-source
        "(import (agent context))
         (current-buffer-context)")
       :type 'agent-scheme-policy-error))))

(ert-deftest agent-scheme-context-test-private-buffer-is-local-only ()
  "Mark private buffer observations unsafe for provider routing."
  (with-temp-buffer
    (rename-buffer "agent-scheme-context-private" t)
    (setq-local agent-scheme-context-local-only-reason "private buffer")
    (insert "local planning notes")
    (let ((external
           (agent-scheme-context-test--eval-external
            "(import (scheme base) (agent context) (agent redaction))
             (let ((context (current-buffer-context)))
               (list (safe-for-provider? context 'openai)
                     context))")))
      (should (string-match-p (regexp-quote "(#f") external))
      (should (string-match-p (regexp-quote "(local-only #t)") external))
      (should (string-match-p
               (regexp-quote "(local-only-reason \"private buffer\")")
               external)))))

(ert-deftest agent-scheme-context-test-context-yield-and-memory-record ()
  "Yield current context and allow intentional memory storage."
  (agent-scheme-memory-clear!)
  (with-temp-buffer
    (rename-buffer "agent-scheme-context-yield" t)
    (insert "yield buffer context")
    (let ((external
           (agent-scheme-context-test--result-external
            "(import (scheme base)
                     (agent context)
                     (agent memory))
             (memory-put! 'instance 'active-focus (current-focus))
             (context-yield 'buffer)
             'done"
            '(:request-id "req-yield"
              :request "yield the current buffer context"))))
      (should (string-match-p (regexp-quote "(status ok)") external))
      (should (string-match-p
               (regexp-quote "(events ((yield (buffer-context")
               external))
      (should
       (string-match-p
        (regexp-quote "(key active-focus)")
        (agent-scheme-context-test--external
         (agent-scheme-memory-ref 'instance 'active-focus)))))))

;;; agent-scheme-context-test.el ends here
