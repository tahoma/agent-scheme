;;; consent-library-module-test.el --- Library resolver module tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused tests for the library resolver module boundary.  These checks keep
;; library name parsing and portable source-library metadata loadable without
;; the interpreter backend.

;;; Code:

(require 'ert)

(defun consent-library-module-test--emacs-command ()
  "Return the current Emacs executable for library module subprocess checks."
  (expand-file-name invocation-name invocation-directory))

(ert-deftest consent-library-module-test-loads-metadata-without-evaluator ()
  "Load library resolver metadata without loading the evaluator module."
  (let ((output-buffer (generate-new-buffer " *consent-library*")))
    (unwind-protect
        (let ((status
               (process-file
                (consent-library-module-test--emacs-command)
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
                   (require 'consent-reader)
                   (require 'consent-library)
                   (when (featurep 'consent-eval)
                     (error \"library loaded evaluator\"))
                   (unless (equal
                            (consent--library-name-key
                             (consent-read \"(scheme base)\"))
                            \"(scheme base)\")
                     (kill-emacs 2))
                   (unless (member \"(scheme write)\"
                                   consent--standard-library-keys)
                     (kill-emacs 3))
                   (let ((spec
                          (seq-find
                           (lambda (entry)
                             (equal (plist-get entry :name)
                                    \"(scheme case-lambda)\"))
                           (consent-standard-source-library-specs))))
                     (unless (and spec
                                  (member \"case-lambda\"
                                          (plist-get spec :exports))
                                  (string-match-p
                                   \"scheme/consent/case-lambda.sld\"
                                   (plist-get spec :source-file)))
                       (kill-emacs 4))))")))
          (unless (equal status 0)
            (ert-fail
             (with-current-buffer output-buffer
               (buffer-string)))))
      (kill-buffer output-buffer))))

;;; consent-library-module-test.el ends here
