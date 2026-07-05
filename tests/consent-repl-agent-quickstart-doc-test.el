;;; consent-repl-agent-quickstart-doc-test.el --- REPL quick-start doc checks  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Keeps the REPL agent harness quick-start grounded in executable Scheme and
;; deterministic model routing, while real local model quality remains opt-in.

;;; Code:

(require 'ert)
(require 'consent-base)
(require 'consent-eval)
(require 'consent-models)
(require 'consent-result)

(defvar consent-repl-agent-quickstart-doc-test--requests nil
  "Requests received by the quick-start fake model transport.")

(defun consent-repl-agent-quickstart-doc-test--read (relative-file)
  "Return the contents of RELATIVE-FILE under the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-file consent--test-root))
    (buffer-string)))

(defun consent-repl-agent-quickstart-doc-test--scheme-block-containing
    (doc needle)
  "Return the first Scheme code block in DOC that contains NEEDLE."
  (let ((start 0)
        block)
    (while (and (not block)
                (string-match "```scheme\n" doc start))
      (let* ((code-start (match-end 0))
             (code-end (string-match "\n```" doc code-start)))
        (unless code-end
          (ert-fail "Unterminated Scheme code block in quick-start document."))
        (let ((candidate (substring doc code-start code-end)))
          (if (string-match-p (regexp-quote needle) candidate)
              (setq block candidate)
            (setq start (match-end 0))))))
    (or block
        (ert-fail
         (format "No quick-start Scheme code block contains %S." needle)))))

(defun consent-repl-agent-quickstart-doc-test--external (source)
  "Evaluate SOURCE and return its stable external value representation."
  (consent-value->external
   (consent-eval-source source)))

(defun consent-repl-agent-quickstart-doc-test--external-sequence (&rest sources)
  "Evaluate SOURCES in one environment and return the last value externally."
  (let ((environment (consent-make-base-environment))
        value)
    (dolist (source sources)
      (setq value (consent-eval-source source environment)))
    (consent-value->external value)))

(defun consent-repl-agent-quickstart-doc-test--transport
    (_provider _model request _context)
  "Return a deterministic quick-start fake completion for REQUEST."
  (push request consent-repl-agent-quickstart-doc-test--requests)
  (format "quick-start deterministic completion: %s"
          (plist-get request :prompt)))

(defun consent-repl-agent-quickstart-doc-test--reset ()
  "Reset model provider state touched by quick-start doc tests."
  (consent-models-clear!)
  (setq consent-repl-agent-quickstart-doc-test--requests nil))

(ert-deftest consent-repl-agent-quickstart-doc-test-known-good-baseline-runs ()
  "The tutorial's known-good differentiator and fact capture remain executable."
  (let* ((doc
          (consent-repl-agent-quickstart-doc-test--read
           "docs/repl-agent-quickstart.md"))
         (baseline
          (consent-repl-agent-quickstart-doc-test--scheme-block-containing
           doc
           "(import (scheme cxr))"))
         (capture
          (consent-repl-agent-quickstart-doc-test--scheme-block-containing
           doc
           "(define test-results"))
         (external
          (consent-repl-agent-quickstart-doc-test--external-sequence
           baseline
           capture)))
    (should (equal external
                   "((#t #t #t #t) (+ (+ x x) 3))"))))

(ert-deftest consent-repl-agent-quickstart-doc-test-captures-reusable-values ()
  "The tutorial names outputs that later prompts reuse."
  (let ((doc
         (consent-repl-agent-quickstart-doc-test--read
          "docs/repl-agent-quickstart.md")))
    (dolist (needle
             '("(define plan"
               "(display plan)"
               "(define code"
               "(display code)"
               "(define test-results"
               "(define sample-derivative"
               "(datum->text test-results)"
               "(datum->text sample-derivative)"
               "(define review"
               "(display review)"
               "(define session-note"
               "(display session-note)"))
      (should (string-match-p (regexp-quote needle) doc)))))

(ert-deftest consent-repl-agent-quickstart-doc-test-model-routing-is-real-api ()
  "The documented model role shape routes through the real API."
  (unwind-protect
      (let ((consent-models-transport-function
             #'consent-repl-agent-quickstart-doc-test--transport))
        (consent-repl-agent-quickstart-doc-test--reset)
        (let ((external
               (consent-repl-agent-quickstart-doc-test--external
                "(import (scheme base)
                         (agent models))

                 (model-provider-register!
                  '(model-provider
                    (id local-ollama)
                    (kind local)
                    (transport openai-compatible-http)
                    (endpoint \"http://127.0.0.1:11434/v1\")
                    (models
                     (((id qwen2.5-coder:14b)
                       (roles (scheme-scripter coder reviewer))
                       (privacy local))
                      ((id qwen3:8b)
                       (roles (planner approval-explainer))
                       (privacy local))
                      ((id gemma3:12b)
                       (roles (summarizer memory-curator))
                       (privacy local))))))

                 (list (model-route 'planner '())
                       (model-route 'scheme-scripter '())
                       (model-route 'reviewer '())
                       (model-route 'memory-curator '())
                       (model-complete
                        'scheme-scripter
                        \"deterministic quick-start check\"
                        '((temperature 0.1))))")))
          (dolist (needle
                   '("(role planner)"
                     "(model qwen3:8b)"
                     "(role scheme-scripter)"
                     "(role reviewer)"
                     "(model qwen2.5-coder:14b)"
                     "(role memory-curator)"
                     "(model gemma3:12b)"
                     "\"quick-start deterministic completion: deterministic quick-start check\""))
            (should (string-match-p (regexp-quote needle) external)))
          (should (= (length consent-repl-agent-quickstart-doc-test--requests)
                     1))))
    (consent-repl-agent-quickstart-doc-test--reset)))

(ert-deftest consent-repl-agent-quickstart-doc-test-runs-in-tools-shard ()
  "The quick-start doc tests are included in the default tools shard."
  (let ((makefile
         (consent-repl-agent-quickstart-doc-test--read "Makefile")))
    (should
     (string-match-p
      (regexp-quote "consent-repl-agent-quickstart-doc.*")
      makefile))))

;;; consent-repl-agent-quickstart-doc-test.el ends here
