;;; agent-scheme-control-loop-doc-test.el --- Control-loop design doc checks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Verifies that the task lifecycle and control-loop design covers the
;; architecture contract requested by issue 281.

;;; Code:

(require 'ert)

(defun agent-scheme-control-loop-doc-test--read (relative-file)
  "Return the contents of RELATIVE-FILE under the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-file agent-scheme--test-root))
    (buffer-string)))

(ert-deftest agent-scheme-control-loop-doc-test-covers-issue-281 ()
  "Ensure the task lifecycle and control-loop design is documented."
  (let ((doc-path (expand-file-name
                   "docs/control-loop.md"
                   agent-scheme--test-root)))
    (should (file-exists-p doc-path))
    (let ((architecture
           (agent-scheme-control-loop-doc-test--read
            "docs/architecture.md"))
          (roadmap
           (agent-scheme-control-loop-doc-test--read
            "docs/roadmap.md"))
          (doc
           (agent-scheme-control-loop-doc-test--read
            "docs/control-loop.md")))
      (dolist (needle
               '("control-loop.md"
                 "Task Lifecycle and Control Loop"))
        (should (string-match-p (regexp-quote needle) architecture))
        (should (string-match-p (regexp-quote needle) roadmap)))
      (dolist (needle
               '("# Task Lifecycle and Control Loop"
                 "## Lifecycle States"
                 "created"
                 "observing"
                 "planning"
                 "acting"
                 "waiting-for-approval"
                 "waiting-for-model"
                 "waiting-for-host"
                 "blocked"
                 "cancelled"
                 "failed"
                 "complete"
                 "## Pause and Stop Receipts"
                 "## Control Loop"
                 "## Scheme-Readable Records"
                 "(agent-task"
                 "(agent-step"
                 "(agent-action"
                 "(agent-observation"
                 "(agent-decision"
                 "(agent-completion"
                 "## Capability Arbitration"
                 "read-only observations"
                 "mutating actions"
                 "stale handles"
                 "approval denied"
                 "## Model Provider Roles"
                 "planner"
                 "coder"
                 "reviewer"
                 "summarizer"
                 "memory-curator"
                 "approval-explainer"
                 "cheap-background"
                 "## Provider Request Contract"
                 "model-provider-request"
                 "model-provider-response"
                 "model-provider-stream-event"
                 "model-provider-error"
                 "model-provider-cancellation"
                 "provider-budget"
                 "## Remote and Local Provider Examples"
                 "remote-openai"
                 "local-openai-compatible"
                 "remote-provider-routing"
                 "local-only context"
                 "## Minimal Executable Slice"
                 "## Follow-Up Issues"
                 "#285"
                 "#286"
                 "#287"
                 "#288"
                 "#289"))
        (should (string-match-p (regexp-quote needle) doc))))))

;;; agent-scheme-control-loop-doc-test.el ends here
