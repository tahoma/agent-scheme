;;; consent-scheme-eval-test.el --- Portable evaluator source checks  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Host-independent source checks for the portable R7RS evaluator.  The
;; portable evaluator test file itself runs through the shared aggregate host
;; suite (`consent--scheme-host-run-suite'), not a per-file Chibi bridge.

;;; Code:

(require 'ert)

(ert-deftest consent-scheme-eval-test-bootstrap-avoids-host-call/cc ()
  "Keep portable evaluator continuations explicit for bootstrapping."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name
      "scheme/consent/eval.sld"
      consent--test-target-root))
    (goto-char (point-min))
    (should-not
     (re-search-forward
      "^[[:space:]]*(\\(?:call-with-current-continuation\\|call/cc\\)\\_>"
      nil
      t))))

;;; consent-scheme-eval-test.el ends here
