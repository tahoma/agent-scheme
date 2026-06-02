;;; consent-test-options-test.el --- CI test option helper tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Tests for the CI-facing test option defaults used by matrix shards.

;;; Code:

(require 'ert)
(require 'consent-test-options)

(ert-deftest consent-test-options-test-default-plist-from-environment ()
  "Parse CI matrix option values into evaluator option defaults."
  (let ((process-environment
         (append
          '("CONSENT_TEST_SOURCE_METADATA=off"
            "CONSENT_TEST_DOCSTRING_RETENTION=simple")
          process-environment)))
    (should
     (equal
      (consent-test-options-default-plist)
      '(:source-metadata nil :docstring-retention simple)))))

(ert-deftest consent-test-options-test-merge-preserves-explicit-values ()
  "Keep explicit test options stronger than CI matrix defaults."
  (let ((process-environment
         (append
          '("CONSENT_TEST_SOURCE_METADATA=off"
            "CONSENT_TEST_DOCSTRING_RETENTION=none")
          process-environment)))
    (should
     (equal
      (consent-test-options-merge-defaults
       '(:source-metadata t :max-steps 10))
      '(:source-metadata t
        :max-steps 10
        :docstring-retention nil)))))

(ert-deftest consent-test-options-test-eval-argument-filter-adds-options ()
  "Add CI matrix defaults as the optional evaluator options argument."
  (let ((process-environment
         (append
          '("CONSENT_TEST_SOURCE_METADATA=off"
            "CONSENT_TEST_DOCSTRING_RETENTION=full")
          process-environment)))
    (should
     (equal
      (consent-test-options-eval-args-with-defaults
       '("(+ 1 2)"))
      '("(+ 1 2)" nil (:source-metadata nil :docstring-retention full))))
    (should
     (equal
      (consent-test-options-eval-args-with-defaults
       '("(+ 1 2)" nil (:source-metadata t)))
      '("(+ 1 2)" nil (:source-metadata t :docstring-retention full))))))

(ert-deftest consent-test-options-test-session-argument-filter-adds-options ()
  "Add CI matrix defaults to session source evaluation calls."
  (let ((process-environment
         (append
          '("CONSENT_TEST_SOURCE_METADATA=on"
            "CONSENT_TEST_DOCSTRING_RETENTION=none")
          process-environment)))
    (should
     (equal
      (consent-test-options-session-args-with-defaults
       '("session" "(+ 1 2)"))
      '("session" "(+ 1 2)"
        (:source-metadata t :docstring-retention nil))))))

(provide 'consent-test-options-test)

;;; consent-test-options-test.el ends here
