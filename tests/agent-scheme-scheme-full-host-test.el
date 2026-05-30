;;; agent-scheme-scheme-full-host-test.el --- Full portable R7RS host suites  -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT bridges for running the portable R7RS Scheme tests under additional
;; R7RS hosts.  Chibi remains split across optional narrower shards for manual
;; timing.

;;; Code:

(require 'ert)
(require 'agent-scheme-scheme-host)

(ert-deftest agent-scheme-scheme-gambit-host-test-r7rs-suite ()
  "Run the full portable R7RS suite with Gambit Scheme."
  (agent-scheme--scheme-host-run-suite 'gambit "gambit"))

(ert-deftest agent-scheme-scheme-racket-host-test-r7rs-suite ()
  "Run the full portable R7RS suite with Racket's R7RS package."
  (agent-scheme--scheme-host-run-suite 'racket "racket"))

(ert-deftest agent-scheme-scheme-guile-host-test-r7rs-suite ()
  "Run the full portable R7RS suite with Guile Scheme."
  (agent-scheme--scheme-host-run-suite 'guile "guile"))

(ert-deftest agent-scheme-scheme-gauche-host-test-r7rs-suite ()
  "Run the full portable R7RS suite with Gauche Scheme."
  (agent-scheme--scheme-host-run-suite 'gauche "gauche"))

(ert-deftest agent-scheme-scheme-compiled-host-test-r7rs-suite ()
  "Run the full portable R7RS suite with the compiled Agent Scheme runner."
  (agent-scheme--scheme-host-run-suite 'compiled "compiled Agent Scheme"))

(provide 'agent-scheme-scheme-full-host-test)

;;; agent-scheme-scheme-full-host-test.el ends here
