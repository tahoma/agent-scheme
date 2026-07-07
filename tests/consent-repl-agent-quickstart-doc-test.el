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

(defun consent-repl-agent-quickstart-doc-test--transport
    (_provider _model _role prompt _options)
  "Return a deterministic quick-start fake completion for PROMPT."
  (push prompt consent-repl-agent-quickstart-doc-test--requests)
  (format "quick-start deterministic completion: %s"
          prompt))

(defun consent-repl-agent-quickstart-doc-test--reset ()
  "Reset model provider state touched by quick-start doc tests."
  (consent-models-clear!)
  (setq consent-repl-agent-quickstart-doc-test--requests nil))

(defun consent-repl-agent-quickstart-doc-test--section (doc heading)
  "Return the Markdown section named HEADING from DOC."
  (let* ((start-regexp
          (concat "^## " (regexp-quote heading) "$"))
         (start
          (or (string-match start-regexp doc)
              (ert-fail (format "No quick-start section named %S." heading))))
         (body-start (match-end 0))
         (end (string-match "^## " doc body-start)))
    (substring doc body-start end)))

(defun consent-repl-agent-quickstart-doc-test--count (needle haystack)
  "Return the number of non-overlapping NEEDLE occurrences in HAYSTACK."
  (let ((start 0)
        (count 0))
    (while (string-match (regexp-quote needle) haystack start)
      (setq count (1+ count))
      (setq start (match-end 0)))
    count))

(ert-deftest consent-repl-agent-quickstart-doc-test-code-prompt-contract ()
  "The scripter prompt asks for executable Scheme definitions, not prose."
  (let* ((doc
          (consent-repl-agent-quickstart-doc-test--read
           "docs/repl-agent-quickstart.md"))
         (code-block
          (consent-repl-agent-quickstart-doc-test--scheme-block-containing
           doc
           "(define code")))
    (dolist (needle
             '("Return only executable R7RS Scheme source."
               "Do not include Markdown fences, prose, math notation, or explanations."
               "Define deriv"
               "Define differentiator-tests"))
      (should (string-match-p (regexp-quote needle) code-block)))))

(ert-deftest consent-repl-agent-quickstart-doc-test-generated-source-gate ()
  "The tutorial gates model text through the generated-source loop."
  (let* ((doc
          (consent-repl-agent-quickstart-doc-test--read
           "docs/repl-agent-quickstart.md"))
         (flat-doc
          (replace-regexp-in-string "[[:space:]\n]+" " " doc)))
    (dolist (needle
             '("(agent generated-source)"
               "(consent eval)"
               "(define generated-run"
               "(generated-source-run"
               "(list 'required-imports '((scheme base)))"
               "(cons 'repair quickstart-repair)"
               "(list 'max-retries 1)"
               "(generated-source-apply"
               "(interaction-environment)"
               "Only an accepted run is allowed to mutate the live REPL session."
               "Do not continue to the reviewer or memory prompts until the generated-source run is accepted"))
      (should (string-match-p (regexp-quote needle) flat-doc)))
    (should-not
     (string-match-p
      (regexp-quote "Displaying `code` prints the model's string")
      flat-doc))))

(ert-deftest consent-repl-agent-quickstart-doc-test-tutorial-imports-write-once ()
  "The tutorial avoids duplicate import prompts during the same REPL session."
  (let* ((doc
          (consent-repl-agent-quickstart-doc-test--read
           "docs/repl-agent-quickstart.md"))
         (tutorial
          (consent-repl-agent-quickstart-doc-test--section
           doc
           "Fifteen-Minute Tutorial Project")))
    (should
     (= 1
        (consent-repl-agent-quickstart-doc-test--count
         "(scheme write)"
         tutorial)))))

(ert-deftest consent-repl-agent-quickstart-doc-test-primary-repl-uses-default-chrome ()
  "The primary tutorial launch path introduces the default chrome first."
  (let* ((doc
          (consent-repl-agent-quickstart-doc-test--read
           "docs/repl-agent-quickstart.md"))
         (install
          (consent-repl-agent-quickstart-doc-test--section
           doc
           "Install the Portable Runtime"))
         (start
          (consent-repl-agent-quickstart-doc-test--section
           doc
           "Start a REPL")))
    (dolist (section (list install start))
      (should-not
       (string-match-p
        (regexp-quote "--session symbolic-agent-tour --chrome quiet")
        section)))
    (should
     (string-match-p
      (regexp-quote "default `comment` chrome")
      start))))

(ert-deftest consent-repl-agent-quickstart-doc-test-main-path-has-no-canned-answer ()
  "The main tutorial path does not embed a completed differentiator answer."
  (let* ((doc
          (consent-repl-agent-quickstart-doc-test--read
           "docs/repl-agent-quickstart.md"))
         (tutorial
          (consent-repl-agent-quickstart-doc-test--section
           doc
           "Fifteen-Minute Tutorial Project")))
    (dolist (forbidden
             '("known-good baseline"
               "(define (=number? expression value)"
               "(define (make-sum left right)"
               "(define (make-product left right)"
               "(define (deriv expression variable)"))
      (should-not (string-match-p (regexp-quote forbidden) tutorial)))))

(ert-deftest consent-repl-agent-quickstart-doc-test-local-profiles-are-paste-ready ()
  "Each supported local model profile has a complete registration form."
  (let ((doc
         (consent-repl-agent-quickstart-doc-test--read
          "docs/repl-agent-quickstart.md")))
    (dolist (profile
             '(("qwen2.5-coder:7b" "qwen3:4b" "gemma3:4b")
               ("qwen2.5-coder:14b" "qwen3:8b" "gemma3:12b")
               ("qwen2.5-coder:32b" "qwen3:30b" "gemma3:12b")))
      (let ((block
             (consent-repl-agent-quickstart-doc-test--scheme-block-containing
              doc
              (format "(id %s)" (car profile)))))
        (dolist (needle
                 (append
                  '("(import (scheme base)"
                    "(agent models)"
                    "(model-provider-register!"
                    "(id local-ollama)"
                    "(roles (scheme-scripter coder reviewer))"
                    "(roles (planner approval-explainer))"
                    "(roles (summarizer memory-curator))")
                  profile))
          (should (string-match-p (regexp-quote needle) block)))))
    (should-not
     (string-match-p
      (regexp-quote "replace those model ids")
      doc))))

(ert-deftest consent-repl-agent-quickstart-doc-test-captures-reusable-values ()
  "The tutorial names outputs that later prompts reuse."
  (let ((doc
         (consent-repl-agent-quickstart-doc-test--read
          "docs/repl-agent-quickstart.md")))
    (dolist (needle
             '("(define plan"
               "(display plan)"
               "(define code"
               "(define generated-run"
               "(generated-source-run-status generated-run)"
               "(generated-source-run-diagnostics generated-run)"
               "(generated-source-run-repair-prompts generated-run)"
               "(define application"
               "(generated-source-apply"
               "(quickstart-field application 'status)"
               "(define test-results"
               "(define sample-derivative"
               "(datum->text test-results)"
               "(datum->text sample-derivative)"
               "(define review"
               "(display review)"
               "(define session-note"
               "(display session-note)"))
      (should (string-match-p (regexp-quote needle) doc)))))

(ert-deftest consent-repl-agent-quickstart-doc-test-code-prompt-stays-plan-led ()
  "The scripter step reuses the planner output without a canned outline."
  (let* ((doc
          (consent-repl-agent-quickstart-doc-test--read
           "docs/repl-agent-quickstart.md"))
         (code-block
          (consent-repl-agent-quickstart-doc-test--scheme-block-containing
           doc
           "(define code")))
    (should
     (string-match-p
      (regexp-quote "'scheme-scripter")
      code-block))
    (should
     (string-match-p
      (regexp-quote "(string-append")
      code-block))
    (should
     (string-match-p
      (regexp-quote "Plan:")
      code-block))
    (should
     (string-match-p
      (regexp-quote "    plan)")
      code-block))
    (dolist (forbidden
             '("Return exactly seven top-level forms"
               "The expected value of differentiator-tests"
               "Sums are (+ left right). Products are (* left right)."
               "(equal? (deriv 'x 'x) 1)"
               "(equal? (deriv 'y 'x) 0)"))
      (should-not (string-match-p (regexp-quote forbidden) code-block)))))

(ert-deftest consent-repl-agent-quickstart-doc-test-model-routing-is-real-api ()
  "The documented model role shape routes through the real API."
  (unwind-protect
      (cl-letf (((symbol-function
                  'consent-models--source-openai-compatible-http-complete)
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
