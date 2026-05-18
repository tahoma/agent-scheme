;;; agent-scheme-base-module-test.el --- Base registry module tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for the base primitive registry and manifest module boundary.
;; These checks keep metadata, prelude discovery, and effect classification
;; loadable without the interpreter backend.

;;; Code:

(require 'ert)

(defun agent-scheme-base-module-test--emacs-command ()
  "Return the current Emacs executable for base module subprocess checks."
  (expand-file-name invocation-name invocation-directory))

(ert-deftest agent-scheme-base-module-test-loads-metadata-without-evaluator ()
  "Load base registry metadata without loading the evaluator module."
  (let ((output-buffer (generate-new-buffer " *agent-scheme-base*")))
    (unwind-protect
        (let ((status
               (process-file
                (agent-scheme-base-module-test--emacs-command)
                nil
                output-buffer
                nil
                "-Q"
                "--batch"
                "-L"
                (expand-file-name "lisp" agent-scheme--test-root)
                "--eval"
                "(progn
                   (require 'seq)
                   (require 'agent-scheme-base)
                   (when (featurep 'agent-scheme-eval)
                     (error \"base loaded evaluator\"))
                   (unless (member \"+\" (agent-scheme-base-primitive-names))
                     (kill-emacs 2))
                   (unless (member \"append\"
                                   (agent-scheme-base-prelude-binding-names))
                     (kill-emacs 3))
                   (let ((spec
                          (car (seq-filter
                                (lambda (entry)
                                  (equal (plist-get entry :name)
                                         \"vector-set!\"))
                                (agent-scheme-primitive-manifest-binding-specs)))))
                     (unless (eq (plist-get spec :effect) 'mutation)
                       (kill-emacs 4))))")))
          (unless (equal status 0)
            (ert-fail
             (with-current-buffer output-buffer
               (buffer-string)))))
      (kill-buffer output-buffer))))

;;; agent-scheme-base-module-test.el ends here
