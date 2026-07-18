;;; consent-context-test.el --- Current context library tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the `(agent context)' library: request, focus, region,
;; buffer, project, conversation, privacy, memory, and event-yield behavior.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-audit)
(require 'consent-context)
(require 'consent-eval)
(require 'consent-memory)
(require 'consent-policy)
(require 'consent-result)

(defun consent-context-test--external (datum)
  "Return DATUM as stable Scheme-readable text."
  (consent-result->external datum))

(defun consent-context-test--value-external (value)
  "Return VALUE as stable Consent Scheme value text."
  (consent-value->external value))

(defun consent-context-test--eval-external (source &optional options)
  "Evaluate SOURCE with OPTIONS and return its external value."
  (consent-context-test--value-external
   (consent-eval-source source nil options)))

(defun consent-context-test--result-external (source &optional options)
  "Evaluate SOURCE with OPTIONS and return its external result datum."
  (consent-context-test--external
   (consent-eval-source-result source nil options)))

(defun consent-context-test--actions (overrides)
  "Return policy category actions with OVERRIDES applied."
  (append overrides
          (seq-remove
           (lambda (entry) (assq (car entry) overrides))
           consent-policy-category-actions)))

(ert-deftest consent-context-test-request-and-conversation-options ()
  "Expose supplied request and conversation context as datums."
  (let ((external
         (consent-context-test--eval-external
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

(ert-deftest consent-context-test-buffer-region-and-project-context ()
  "Represent live buffer, active region, and project source metadata."
  (let ((default-directory consent--test-root))
    (with-temp-buffer
      (rename-buffer "consent-context-buffer" t)
      (setq buffer-file-name
            (expand-file-name "tests/context-example.scm"
                              consent--test-root))
      (insert "first line\nsecond target\nthird line\n")
      (goto-char (point-min))
      (forward-line 1)
      (set-mark (point))
      (search-forward "target")
      (let ((mark-active t)
            (transient-mark-mode t))
        (let ((external
               (consent-context-test--eval-external
                "(import (scheme base) (agent context))
                 (list (current-buffer-context)
                       (current-region-context)
                       (current-project-context))")))
          (should (string-match-p (regexp-quote "(buffer-context") external))
          (should (string-match-p
                   (regexp-quote "(name \"consent-context-buffer\")")
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
                             (expand-file-name consent--test-root))))
                   external)))))))

(ert-deftest consent-context-test-missing-context_returns-false ()
  "Return #f for missing request, region, and conversation context."
  (with-temp-buffer
    (should
     (equal
      (consent-context-test--eval-external
       "(import (scheme base) (agent context))
        (list (current-request)
              (current-region-context)
              (current-conversation-summary))")
      "(#f #f #f)"))))

(ert-deftest consent-context-test-policy-denies-buffer-context ()
  "Respect read-only policy denial for live buffer context."
  (let ((consent-policy-category-actions
         (consent-context-test--actions '((emacs-read-only . deny)))))
    (with-temp-buffer
      (should-error
       (consent-eval-source
        "(import (agent context))
         (current-buffer-context)")
       :type 'consent-policy-error))))

(ert-deftest consent-context-test-private-buffer-is-local-only ()
  "Mark private buffer observations unsafe for provider routing."
  (with-temp-buffer
    (rename-buffer "consent-context-private" t)
    (setq-local consent-context-local-only-reason "private buffer")
    (insert "local planning notes")
    (let ((external
           (consent-context-test--eval-external
            "(import (scheme base) (agent context) (agent redaction))
             (let ((context (current-buffer-context)))
               (list (safe-for-provider? context 'openai)
                     (vector? (cadr (cadr context)))
                     context))")))
      (should (string-match-p (regexp-quote "(#f") external))
      (should (string-match-p (regexp-quote "(#f #f") external))
      (should (string-match-p (regexp-quote "(local-only #t)") external))
      (should (string-match-p
               (regexp-quote "(local-only-reason \"private buffer\")")
               external)))))

(ert-deftest consent-context-test-context-yield-and-memory-record ()
  "Yield current context and allow intentional memory storage."
  (consent-memory-clear!)
  (with-temp-buffer
    (rename-buffer "consent-context-yield" t)
    (insert "yield buffer context")
    (let ((external
           (consent-context-test--result-external
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
        (consent-context-test--external
         (consent-memory-ref 'instance 'active-focus)))))))

;;; consent-context-test.el ends here
