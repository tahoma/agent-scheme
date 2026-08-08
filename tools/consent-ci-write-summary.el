;;; consent-ci-write-summary.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(require 'consent-ci)

(let ((log-file (getenv "CONSENT_CI_LOG_FILE"))
      (summary-file (getenv "GITHUB_STEP_SUMMARY")))
  (unless (and log-file summary-file)
    (error "CONSENT_CI_LOG_FILE and GITHUB_STEP_SUMMARY are required"))
  (consent-ci-write-summary
   (list (expand-file-name log-file "ci-logs"))
   summary-file))

;;; consent-ci-write-summary.el ends here
