;;; consent-scheme-module-ownership-test.el --- Portable module ownership checks  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Structural checks for the portable R7RS pass-boundary libraries.  These
;; tests catch facade regressions where a pass module merely re-exports the
;; monolithic evaluator instead of owning its definitions.

;;; Code:

(require 'ert)
(require 'scheme)

(defun consent-scheme-module-ownership-test--read (path)
  "Return repository-relative PATH contents."
  (with-temp-buffer
    (insert-file-contents (expand-file-name path consent--test-root))
    (buffer-string)))

(defun consent-scheme-module-ownership-test--imports-eval-p (source)
  "Return non-nil when SOURCE imports the portable evaluator module.
Only actual import forms count; prose mentions of the library name in
comments or docstrings do not."
  (with-temp-buffer
    (insert source)
    (scheme-mode)
    (goto-char (point-min))
    (let (found)
      (while (and (not found)
                  (re-search-forward "(import\\_>" nil t))
        (let ((start (match-beginning 0)))
          (unless (nth 8 (syntax-ppss start))
            (goto-char start)
            (forward-sexp)
            (setq found
                  (string-match-p
                   "(consent eval)"
                   (buffer-substring-no-properties start (point)))))))
      found)))

(defun consent-scheme-module-ownership-test--contains-symbol-p (source symbol)
  "Return non-nil when SOURCE mentions SYMBOL outside strings/comments."
  (with-temp-buffer
    (insert source)
    (scheme-mode)
    (goto-char (point-min))
    (let ((pattern (concat "\\_<" (regexp-quote symbol) "\\_>"))
          found)
      (while (and (not found)
                  (re-search-forward pattern nil t))
        (unless (nth 8 (syntax-ppss (match-beginning 0)))
          (setq found t)))
      found)))

(defun consent-scheme-module-ownership-test--non-core-library-paths ()
  "Return repository-relative Scheme library paths outside `scheme/consent'."
  (let* ((scheme-root (expand-file-name "scheme" consent--test-root))
         (core-root (file-name-as-directory
                     (expand-file-name "consent" scheme-root)))
         (absolute-paths (directory-files-recursively scheme-root "\\.sld\\'"))
         relative-paths)
    (dolist (path absolute-paths (sort relative-paths #'string<))
      (unless (string-prefix-p core-root path)
        (push (file-relative-name path consent--test-root) relative-paths)))))

(ert-deftest consent-scheme-module-ownership-test-runtime-result-own-definitions ()
  "Keep runtime values and result rendering out of the portable evaluator."
  (let ((runtime
         (consent-scheme-module-ownership-test--read
          "scheme/consent/runtime.sld"))
        (result
         (consent-scheme-module-ownership-test--read
          "scheme/consent/result.sld"))
        (eval
         (consent-scheme-module-ownership-test--read
          "scheme/consent/eval.sld")))
    (should-not
     (consent-scheme-module-ownership-test--imports-eval-p runtime))
    (should-not
     (consent-scheme-module-ownership-test--imports-eval-p result))
    (should
     (string-match-p "(define-record-type <eval-context>" runtime))
    (should-not
     (string-match-p "(define-record-type <eval-context>" eval))
    (should
     (string-match-p "(define (consent-value->external" result))
    (should-not
     (string-match-p "(define (consent-value->external" eval))))

(ert-deftest consent-scheme-module-ownership-test-base-owns-registry ()
  "Keep the portable base registry out of the evaluator module."
  (let ((base
         (consent-scheme-module-ownership-test--read
          "scheme/consent/base.sld"))
        (eval
         (consent-scheme-module-ownership-test--read
          "scheme/consent/eval.sld")))
    (should-not
     (consent-scheme-module-ownership-test--imports-eval-p base))
    (should
     (string-match-p "(define base-primitive-registry" base))
    (should-not
     (string-match-p "(define base-primitive-registry" eval))
    (should
     (string-match-p
      "(define (consent-install-base-backend!" base))))

(ert-deftest consent-scheme-module-ownership-test-library-owns-resolver ()
  "Keep the portable library resolver out of the evaluator module."
  (let ((library
         (consent-scheme-module-ownership-test--read
          "scheme/consent/library.sld"))
        (eval
         (consent-scheme-module-ownership-test--read
          "scheme/consent/eval.sld")))
    (should-not
     (consent-scheme-module-ownership-test--imports-eval-p library))
    (should
     (string-match-p "(define (resolve-library" library))
    (should-not
     (string-match-p "(define (resolve-library" eval))
    (should
     (string-match-p
      "(define (consent-install-library-backend!" library))))

(ert-deftest consent-scheme-module-ownership-test-macro-owns-expander ()
  "Keep the portable macro expander out of the evaluator module."
  (let ((macro
         (consent-scheme-module-ownership-test--read
          "scheme/consent/macro.sld"))
        (eval
         (consent-scheme-module-ownership-test--read
          "scheme/consent/eval.sld")))
    (should-not
     (consent-scheme-module-ownership-test--imports-eval-p macro))
    (should
     (string-match-p "(define (apply-syntax-transformer" macro))
    (should-not
     (string-match-p "(define (apply-syntax-transformer" eval))
    (should
     (string-match-p "(define (consent-expand-source" macro))))

(ert-deftest consent-scheme-module-ownership-test-interpreter-owns-backend ()
  "Keep the portable interpreter backend out of the evaluator facade."
  (let ((interpreter
         (consent-scheme-module-ownership-test--read
          "scheme/consent/interpreter.sld"))
        (eval
         (consent-scheme-module-ownership-test--read
          "scheme/consent/eval.sld")))
    (should-not
     (consent-scheme-module-ownership-test--imports-eval-p interpreter))
    (should
     (string-match-p "(define (trampoline" interpreter))
    (should-not
     (string-match-p "(define (trampoline" eval))
    (should
     (< (length (split-string eval "\n")) 80))))

(ert-deftest consent-scheme-module-ownership-test-portable-libraries-use-scheme-numbers ()
  "Keep reader-owned numeric constructors and accessors out of pure libraries."
  (let ((forbidden-symbols '("consent-make-canonical-integer"
                             "consent-make-canonical-decimal"
                             "consent-make-canonical-rational"
                             "consent-make-canonical-infnan"
                             "consent-make-canonical-complex"
                             "consent-number?"
                             "consent-number-value"
                             "consent-number-kind"
                             "consent-number-exactness"
                             "consent-number-raw-value"
                             "consent-number-zero?"
                             "consent-number-negative?"
                             "consent-number-abs"
                             "consent-number->external")))
    (dolist (path (consent-scheme-module-ownership-test--non-core-library-paths))
      (let ((source (consent-scheme-module-ownership-test--read path)))
        (dolist (symbol forbidden-symbols)
          (ert-info ((format "path=%s symbol=%s" path symbol))
            (should-not
             (consent-scheme-module-ownership-test--contains-symbol-p
              source symbol))))))))

;;; consent-scheme-module-ownership-test.el ends here
