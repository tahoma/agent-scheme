;;; consent-compile-elisp-docstring-test.el --- Elisp docstring lint tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Source-level coverage for checked-in Emacs Lisp docstring width.

;;; Code:

(require 'ert)

(load (expand-file-name "tools/lint-elisp-docstrings.el" consent--test-root)
      nil t)

(ert-deftest consent-compile-elisp-docstring-test-source-docstrings-fit-byte-compiler-width ()
  "Require checked-in Emacs Lisp docstrings to fit byte-compiler width."
  (should-not
   (consent-lint-elisp-docstrings-violations consent--test-target-root)))

;;; consent-compile-elisp-docstring-test.el ends here
