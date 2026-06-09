;;; consent-scheme-full-host-test.el --- Full portable R7RS host suites  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; ERT bridges for running the portable R7RS Scheme tests under additional
;; R7RS hosts.  Every host, Chibi included, runs the same aggregate
;; `consent--scheme-host-run-suite' loop over the shared test-file list.

;;; Code:

(require 'ert)
(require 'consent-scheme-host)

(ert-deftest consent-scheme-gambit-host-test-r7rs-suite ()
  "Run the full portable R7RS suite with Gambit Scheme."
  (consent--scheme-host-run-suite 'gambit "gambit"))

(ert-deftest consent-scheme-gambit-native-host-test-r7rs-suite ()
  "Run the full portable R7RS suite with the Gambit-compiled Consent Scheme runner."
  (consent--scheme-host-run-suite
   'gambit-native
   "Gambit-compiled Consent Scheme"))

(ert-deftest consent-scheme-racket-host-test-r7rs-suite ()
  "Run the full portable R7RS suite with Racket's R7RS package."
  (consent--scheme-host-run-suite 'racket "racket"))

(ert-deftest consent-scheme-guile-host-test-r7rs-suite ()
  "Run the full portable R7RS suite with Guile Scheme."
  (consent--scheme-host-run-suite 'guile "guile"))

(ert-deftest consent-scheme-gauche-host-test-r7rs-suite ()
  "Run the full portable R7RS suite with Gauche Scheme."
  (consent--scheme-host-run-suite 'gauche "gauche"))

(ert-deftest consent-scheme-compiled-host-test-r7rs-suite ()
  "Run the full portable R7RS suite with the Racket-compiled Consent Scheme runner."
  (consent--scheme-host-run-suite 'compiled "Racket-compiled Consent Scheme"))

(ert-deftest consent-scheme-chibi-host-test-r7rs-suite ()
  "Run the full portable R7RS suite with Chibi Scheme."
  (consent--scheme-host-run-suite 'chibi "chibi"))

(provide 'consent-scheme-full-host-test)

;;; consent-scheme-full-host-test.el ends here
