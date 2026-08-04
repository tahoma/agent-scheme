;;; consent-parity-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; CI gate that runs the shared fixture corpus through both in-repo cores --
;; the Emacs-hosted implementation and the portable R7RS implementation -- and
;; fails on any result divergence.  See `consent-parity' for the scope and
;; normalization rules.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'consent-parity)

(ert-deftest consent-parity-test-scope-is-dual-core ()
  "The parity scope is non-empty and excludes single-sourced libraries."
  (let ((cases (consent-parity-cases)))
    (should cases)
    (dolist (case cases)
      (should (eq (consent-test-fixture-field case 'oracle) 'shared))
      (should (eq (consent-test-fixture-field case 'status) 'implemented))
      (should (memq (consent-test-fixture-field case 'phase)
                    consent-parity-runnable-phases))))
  ;; Plain expressions are in scope; sources importing a single-sourced
  ;; library are excluded so the gate never diffs source against itself.
  (should (consent-parity--dual-core-source-p "(+ 1 2)"))
  (should-not
   (consent-parity--dual-core-source-p "(import (agent diff)) 1")))

(ert-deftest consent-parity-test-key-normalization ()
  "Emacs and portable key normalization agree on each result shape."
  (should (equal (consent-parity--emacs-key
                  (list :status 'value :value (consent-read "3")))
                 (consent-parity--portable-key '(value "3"))))
  (should (equal (consent-parity--emacs-key
                  (list :status 'values
                        :values
                        (consent-read-all "1 2")))
                 (consent-parity--portable-key '(values ("1" "2")))))
  (should (equal (consent-parity--emacs-key
                  (list :status 'result
                        :value
                        (consent-read "(evaluation-result)")))
                 (consent-parity--portable-key '(result
                   "(evaluation-result)"))))
  (should (equal (consent-parity--emacs-key '(:status error :condition boom))
                 (consent-parity--portable-key '(error)))))

(ert-deftest consent-parity-test-record-parsing-rejects-malformed ()
  "Parsing a non-record datum signals rather than silently passing."
  (should (equal (consent-parity--parse-records
                  "(parity-actual demo (value \"3\"))")
                 '((demo value "3"))))
  (should-error (consent-parity--parse-records "(not-a-record 1 2)")))

(ert-deftest consent-parity-test-cores-agree ()
  "The Emacs and portable cores produce identical results on every case."
  (let ((host (consent-parity-resolve-host)))
    (skip-unless host)
    (let ((divergences (consent-parity-compare (car host) (cdr host))))
      (when divergences
        (ert-fail
         (concat
          (format "%d Emacs/portable parity divergence(s) on host %s:\n"
                  (length divergences)
                  (car (car host)))
          (mapconcat #'consent-parity-divergence-message
                     divergences
                     "\n")))))))

;;; consent-parity-test.el ends here
