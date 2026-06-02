;;; consent-diff-test.el --- Diff datum and adapter tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the host-neutral `(agent diff)' datum library and the
;; Emacs `(emacs diff)' adapter that produces those datums from live buffers.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-audit)
(require 'consent-eval)
(require 'consent-result)

(defun consent-diff-test--external (source)
  "Evaluate SOURCE and return its stable external value representation."
  (consent-value->external
   (consent-eval-source source)))

(defun consent-diff-test--result-external (source)
  "Evaluate SOURCE and return its stable evaluation-result text."
  (consent-result->external
   (consent-eval-source-result source)))

(defun consent-diff-test--contains-p (text needle)
  "Return non-nil when TEXT contains NEEDLE."
  (string-match-p (regexp-quote needle) text))

(ert-deftest consent-diff-test-agent-diff-constructs-and-renders ()
  "The portable `(agent diff)' library constructs and renders diff datums."
  (let ((rendered
         (consent-eval-source
          "(import (agent diff))
           (diff-render-unified
            (proposed-edit-diff
             '(proposed-edit
               (source buffer)
               (old-label \"before.scm\")
               (new-label \"after.scm\")
               (start 2)
               (end 2)
               (before \"old\")
               (after \"new\"))))")))
    (should
     (equal rendered
            "--- before.scm\n+++ after.scm\n@@ -2,1 +2,1 @@\n-old\n+new\n"))))

(ert-deftest consent-diff-test-agent-diff-no-change ()
  "No-change diff datums are explicit and render to an empty unified diff."
  (should
   (equal
    (consent-diff-test--external
     "(import (scheme base) (agent diff))
      (let ((diff (no-change-diff 'buffer \"scratch\")))
        (list (diff? diff)
              (diff-changed? diff)
              (diff-render-unified diff)))")
    "(#t #f \"\")")))

(ert-deftest consent-diff-test-agent-diff-yields-events ()
  "Portable diff records can be yielded as Scheme-readable event data."
  (consent-audit-clear)
  (let ((result
         (consent-diff-test--result-external
          "(import (scheme base) (agent diff))
           (diff-yield (no-change-diff 'buffer \"scratch\"))
           'ok")))
    (should (consent-diff-test--contains-p result "(status ok)"))
    (should (consent-diff-test--contains-p result "(events ((yield (diff"))
    (should (consent-diff-test--contains-p result "(status no-change)"))))

(ert-deftest consent-diff-test-emacs-diff-imports-export-bindings ()
  "The `(emacs diff)' adapter library exposes diff-producing procedures."
  (should
   (equal
    (consent-diff-test--external
     "(import (scheme base) (emacs diff))
      (list (procedure? buffer-diff)
            (procedure? file-diff)
            (procedure? project-diff))")
    "(#t #t #t)")))

(ert-deftest consent-diff-test-buffer-diff-compares-disk-and-buffer ()
  "Buffer diffs compare the visited file snapshot with current buffer text."
  (let* ((path (make-temp-file "consent-diff-buffer-" nil ".scm"))
         (buffer (find-file-noselect path)))
    (unwind-protect
        (progn
          (with-temp-file path
            (insert "alpha\nold\n"))
          (with-current-buffer buffer
            (revert-buffer t t)
            (erase-buffer)
            (insert "alpha\nnew\n")
            (let ((rendered
                   (consent-eval-source
                    "(import (agent diff) (emacs buffer) (emacs diff))
                     (diff-render-unified
                      (buffer-diff (emacs-current-buffer)))")))
              (should
               (consent-diff-test--contains-p
                rendered
                "@@ -2,1 +2,1 @@\n-old\n+new\n")))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when (file-exists-p path)
        (delete-file path)))))

;;; consent-diff-test.el ends here
