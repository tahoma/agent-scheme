;;; consent-runtime-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused tests for the evaluator runtime module boundary.  These checks keep
;; value records, lexical environments, and per-run context setup loadable
;; without depending on interpreter entry points.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'consent-result)

(defconst consent-runtime-test--version-source
  "scheme/consent/version.sld"
  "Repository-relative canonical Consent Scheme version source.")

(ert-deftest consent-runtime-test-version-components-are-canonical ()
  "Derive the host version views from the canonical version datum."
  (let* ((datum consent--version-datum)
         (components (mapcar #'consent-number-value (cdr datum))))
    ;; The datum head is the canonical version tag symbol.
    (should (consent--version-symbol-named-p
             (car datum) "consent-version"))
    ;; Components are the datum's exact non-negative host-integer cdr.
    (should (equal (consent-version-components) components))
    (should (cl-every (lambda (component)
                        (and (integerp component) (>= component 0)))
                      components))
    ;; `consent-version' round-trips the canonical datum.
    (should (equal (consent-value->external (consent-version))
                   (consent-value->external datum)))
    ;; The version string is the components joined with dots.
    (should (equal (consent-version-string)
                   (mapconcat #'number-to-string components ".")))))

(ert-deftest consent-runtime-test-version-comes-from-shared-source ()
  "Keep the version number in one Scheme-readable source file."
  (let* ((path (expand-file-name
                consent-runtime-test--version-source
                consent--test-root))
         (forms (consent-read-all
                 (with-temp-buffer
                   (insert-file-contents path)
                   (buffer-string)))))
    (should (= (length forms) 1))
    (should
     (string-match-p
      "(define-library (consent version)"
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string))))
    (should
     (string-match-p
      "(export consent-version-datum)"
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string))))
    ;; The host version API must reflect the datum defined in this file.
    (let ((file-datum (consent--version-find-definition-value
                       (car forms))))
      (should file-datum)
      (should
       (equal (consent-value->external (consent-version))
              (consent-value->external file-datum))))
    (should
     (string-match-p
      "single source of truth"
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string))))))

(ert-deftest consent-runtime-test-version-literal-is-not-duplicated ()
  "Keep runtime implementation sources from repeating the version number."
  (let ((canonical (expand-file-name
                    consent-runtime-test--version-source
                    consent--test-root))
        matches)
    (dolist (directory '("lisp" "scheme" "fixtures"))
      (dolist (file (directory-files-recursively
                     (expand-file-name directory consent--test-root)
                     "\\.\\(el\\|scm\\|sld\\)\\'"))
        (unless (equal file canonical)
          (with-temp-buffer
            (insert-file-contents file)
            (when (re-search-forward
                   "\\(consent-version 0 15 4\\|0\\.15\\.1\\|'(0 15\
 4\\|(list 0 15 4\\)"
                   nil t)
              (push file matches))))))
    (should-not matches)))

(defun consent-runtime-test--emacs-command ()
  "Return the current Emacs executable for runtime module subprocess checks."
  (expand-file-name invocation-name invocation-directory))

(ert-deftest consent-runtime-test-records-and-context-live-in-runtime-module ()
  "Load the runtime module and construct its core state records."
  (let ((runtime-library (locate-library "consent-runtime")))
    (should runtime-library)
    (load runtime-library nil t))
  (should (featurep 'consent-runtime))
  (let ((environment (consent-make-empty-environment))
        (child (consent-make-empty-environment
                (consent-make-empty-environment))))
    (should (consent--environment-p environment))
    (should (hash-table-p (consent--environment-bindings environment)))
    (should-not (consent--environment-parent environment))
    (should (consent--environment-parent child)))
  (let ((context (consent--new-eval-context
                  '(:max-steps 3
                    :max-value-nodes 4
                    :max-source-metadata 6
                    :max-host-callbacks 5))))
    (should (consent--eval-context-p context))
    (should (= (consent--eval-context-maximum-steps context) 3))
    (should (= (consent--eval-context-maximum-value-nodes context) 4))
    (should (= (consent--eval-context-maximum-source-metadata context) 6))
    (should (= (consent--eval-context-maximum-host-callbacks context) 5))
    (should (hash-table-p (consent--eval-context-libraries context)))
    (should (consent--syntax-environment-p
             (consent--eval-context-syntax-environment context)))
    (dotimes (_ 3)
      (consent--note-step context))
    (should-error (consent--note-step context)
                  :type 'consent-budget-error)))

(ert-deftest consent-runtime-test-loads-without-evaluator-module ()
  "Load only the runtime module in a fresh Emacs process."
  (let ((output-buffer (generate-new-buffer " *consent-runtime*")))
    (unwind-protect
        (let ((status
               (process-file
                (consent-runtime-test--emacs-command)
                nil
                output-buffer
                nil
                "-Q"
                "--batch"
                "-L"
                (expand-file-name "lisp" consent--test-root)
                "--eval"
                "(progn
                   (require 'consent-runtime)
                   (when (featurep 'consent-eval)
                     (error \"runtime loaded evaluator\"))
                   (unless (equal (consent-version-components)
                                  (mapcar #'consent-number-value
                                          (cdr consent--version-datum)))
                     (kill-emacs 6))
                   (let ((context
                          (consent--new-eval-context
                           '(:max-steps 1))))
                     (consent--note-step context)
                     (condition-case nil
                         (progn
                           (consent--note-step context)
                           (kill-emacs 3))
                       (consent-budget-error
                        nil)))
                   (let ((environment
                          (consent-make-empty-environment)))
                     (consent--environment-define
                      environment \"answer\" 42)
                     (unless (= (consent--environment-ref
                                 environment \"answer\")
                                42)
                       (kill-emacs 4))
                     (consent--environment-set-cell
                      environment \"answer\" 43)
                     (unless (= (consent--environment-ref
                                 environment \"answer\")
                                43)
                       (kill-emacs 5)))
                   (kill-emacs 0))")))
          (unless (equal status 0)
            (ert-fail
             (with-current-buffer output-buffer
               (buffer-string)))))
      (kill-buffer output-buffer))))

;;; consent-runtime-test.el ends here
