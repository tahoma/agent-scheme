;;; consent-smoke-test.el --- Smoke tests for the test harness  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; These tests prove that ERT discovery and runner setup are wired into
;; the repository-local harness.

;;; Code:

(require 'ert)

(ert-deftest consent-smoke-test-harness-runs ()
  "Confirm the batch runner can discover and execute an ERT test."
  (should (bound-and-true-p consent--test-root))
  (should (file-directory-p consent--test-root))
  (should (member (expand-file-name "tests" consent--test-root) load-path)))

;;; consent-smoke-test.el ends here
