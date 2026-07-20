;;; consent-scheme-numeric-test.el --- Portable numeric source checks  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Structural regression checks for performance-sensitive portable numeric and
;; evaluator seams.  Behavioral arithmetic coverage lives in the Scheme-native
;; test plan; these checks forbid fallback shapes that remain semantically
;; correct while making compiled execution catastrophically slow.

;;; Code:

(require 'ert)
(require 'scheme)

(defun consent-scheme-numeric-test--definition-source (file name)
  "Return the complete Scheme definition of NAME from repository-relative FILE."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name file consent--test-target-root))
    (scheme-mode)
    (goto-char (point-min))
    (unless
        (re-search-forward
         (format
          "^[[:space:]]*(define[[:space:]]+(%s\\_>"
          (regexp-quote name))
         nil
         t)
      (ert-fail (format "Missing Scheme definition %s in %s" name file)))
    (goto-char (match-beginning 0))
    (let ((start (point)))
      (forward-sexp 1)
      (buffer-substring-no-properties start (point)))))

(defun consent-scheme-numeric-test--regexp-count (regexp text)
  "Return the number of non-overlapping REGEXP matches in TEXT."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let ((count 0))
      (while (re-search-forward regexp nil t)
        (setq count (1+ count)))
      count)))

(ert-deftest consent-scheme-numeric-test-binary64-host-seam-avoids-text ()
  "Keep finite binary64 host conversion on direct numeric reconstruction."
  (let ((encode
         (consent-scheme-numeric-test--definition-source
          "scheme/consent/numeric.sld"
          "binary64->host"))
        (decode
         (consent-scheme-numeric-test--definition-source
          "scheme/consent/numeric.sld"
          "host-finite->binary64")))
    (dolist (forbidden
             '("binary64->string"
               "binary64-parse"
               "number->string"
               "string->number"))
      (should-not (string-match-p (regexp-quote forbidden) encode))
      (should-not (string-match-p (regexp-quote forbidden) decode)))
    (should-not (string-match-p "integer-import-host" decode))))

(ert-deftest consent-scheme-numeric-test-special-form-name-resolved-once ()
  "Keep one mixed-symbol conversion per combination dispatch."
  (let ((source
         (consent-scheme-numeric-test--definition-source
          "scheme/consent/interpreter.sld"
          "eval-combination")))
    (should
     (= 1
        (consent-scheme-numeric-test--regexp-count
         "(interpreter-symbol-name\\_>"
         source)))
    (should-not (string-match-p "(identifier-named\\?\\_>" source))))

;;; consent-scheme-numeric-test.el ends here
