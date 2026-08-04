;;; consent-base-module-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused tests for the base primitive registry and manifest module boundary.
;; These checks keep metadata, prelude discovery, and effect classification
;; loadable without the interpreter backend.

;;; Code:

(require 'ert)

(defun consent-base-module-test--emacs-command ()
  "Return the current Emacs executable for base module subprocess checks."
  (expand-file-name invocation-name invocation-directory))

(ert-deftest consent-base-module-test-loads-metadata-without-evaluator ()
  "Load base registry metadata without loading the evaluator module."
  (let ((output-buffer (generate-new-buffer " *consent-base*")))
    (unwind-protect
        (let ((status
               (process-file
                (consent-base-module-test--emacs-command)
                nil
                output-buffer
                nil
                "-Q"
                "--batch"
                "-L"
                (expand-file-name "lisp" consent--test-root)
                "--eval"
                "(progn
                   (require 'seq)
                   (require 'consent-base)
                   (when (featurep 'consent-eval)
                     (error \"base loaded evaluator\"))
                   (unless (member \"+\" (consent-base-primitive-names))
                     (kill-emacs 2))
                   (unless (member \"append\"
                                   (consent-base-prelude-binding-names))
                     (kill-emacs 3))
                   (let ((spec
                          (car (seq-filter
                                (lambda (entry)
                                  (equal (plist-get entry :name)
                                         \"vector-set!\"))
                                (consent-primitive-manifest-binding-specs)))))
                     (unless (eq (plist-get spec :effect) 'mutation)
                       (kill-emacs 4))))")))
          (unless (equal status 0)
            (ert-fail
             (with-current-buffer output-buffer
               (buffer-string)))))
      (kill-buffer output-buffer))))

;;; consent-base-module-test.el ends here
