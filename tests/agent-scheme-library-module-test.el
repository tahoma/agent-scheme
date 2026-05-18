;;; agent-scheme-library-module-test.el --- Library resolver module tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for the library resolver module boundary.  These checks keep
;; library name parsing and portable source-library metadata loadable without
;; the interpreter backend.

;;; Code:

(require 'ert)

(defun agent-scheme-library-module-test--emacs-command ()
  "Return the current Emacs executable for library module subprocess checks."
  (expand-file-name invocation-name invocation-directory))

(ert-deftest agent-scheme-library-module-test-loads-metadata-without-evaluator ()
  "Load library resolver metadata without loading the evaluator module."
  (let ((output-buffer (generate-new-buffer " *agent-scheme-library*")))
    (unwind-protect
        (let ((status
               (process-file
                (agent-scheme-library-module-test--emacs-command)
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
                   (require 'agent-scheme-reader)
                   (require 'agent-scheme-library)
                   (when (featurep 'agent-scheme-eval)
                     (error \"library loaded evaluator\"))
                   (unless (equal
                            (agent-scheme--library-name-key
                             (agent-scheme-read \"(scheme base)\"))
                            \"(scheme base)\")
                     (kill-emacs 2))
                   (unless (member \"(scheme write)\"
                                   agent-scheme--standard-library-keys)
                     (kill-emacs 3))
                   (let ((spec
                          (seq-find
                           (lambda (entry)
                             (equal (plist-get entry :name)
                                    \"(scheme case-lambda)\"))
                           (agent-scheme-standard-source-library-specs))))
                     (unless (and spec
                                  (member \"case-lambda\"
                                          (plist-get spec :exports))
                                  (string-match-p
                                   \"scheme/standard-library/case-lambda.sld\"
                                   (plist-get spec :source-file)))
                       (kill-emacs 4))))")))
          (unless (equal status 0)
            (ert-fail
             (with-current-buffer output-buffer
               (buffer-string)))))
      (kill-buffer output-buffer))))

;;; agent-scheme-library-module-test.el ends here
