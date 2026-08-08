;;; benchmark-unicode.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Opt-in same-process measurements for Unicode source-library initialization
;; and representative `(scheme char)' operations.  Results are Scheme-readable
;; records without pass/fail thresholds so developers can compare like-for-like
;; runs without making noisy wall-clock measurements part of the test suite.

;;; Code:

(let* ((tools-directory
        (file-name-directory (or load-file-name buffer-file-name)))
       (root
        (file-name-directory (directory-file-name tools-directory))))
  (add-to-list 'load-path (expand-file-name "lisp" root)))

(setq load-prefer-newer t)

(require 'benchmark)
(require 'consent-eval)
(require 'consent-result)

(defconst consent--unicode-benchmark-default-iterations 100
  "Default persistent operation count for each Unicode benchmark metric.")

(defconst consent--unicode-benchmark-default-import-iterations 3
  "Default fresh-context count for the warm Unicode import metric.")

(defun consent--unicode-benchmark-positive-integer-env (name default)
  "Return positive integer environment variable NAME, or DEFAULT."
  (let ((raw (getenv name)))
    (if (and raw (> (length raw) 0))
        (let ((value (string-to-number raw)))
          (unless (and (string-match-p "\\`[0-9]+\\'" raw)
                       (> value 0))
            (error "%s must be a positive integer" name))
          value)
      default)))

(defun consent--unicode-benchmark-options (iterations)
  "Return evaluator budget options sized for ITERATIONS operations."
  (list :max-steps (max 1000000 (* iterations 10000))
        :max-host-callbacks (max 100000 (* iterations 100))))

(defun consent--unicode-benchmark-emit (metric iterations timing)
  "Print METRIC for ITERATIONS using benchmark TIMING."
  (let ((seconds (nth 0 timing))
        (collections (nth 1 timing))
        (collection-seconds (nth 2 timing)))
    (princ
     (format
      (concat
       "(consent-benchmark (schema-version 1) (metric %s) "
       "(iterations %d) (seconds %.9f) "
       "(seconds-per-iteration %.9f) (garbage-collections %d) "
       "(garbage-collection-seconds %.9f))\n")
      (symbol-name metric)
      iterations
      seconds
      (/ seconds iterations)
      collections
      collection-seconds))))

(defun consent--unicode-benchmark-measure
    (metric iterations thunk validate)
  "Measure THUNK, VALIDATE its result, and emit METRIC for ITERATIONS."
  (let (result)
    (let ((timing
           (benchmark-call
            (lambda ()
              (setq result (funcall thunk)))
            1)))
      (funcall validate result)
      (consent--unicode-benchmark-emit metric iterations timing))))

(defun consent--unicode-benchmark-validate-value (value expected)
  "Require evaluated VALUE to render as EXPECTED."
  (let ((actual (consent-value->external value)))
    (unless (equal actual expected)
      (error "Unicode benchmark expected %s, got %s" expected actual))))

(defun consent--unicode-benchmark-validate-result (result expected-value)
  "Require interaction RESULT to be successful with EXPECTED-VALUE text."
  (let ((external (consent-result->external result)))
    (unless (and (string-match-p (regexp-quote "(status ok)") external)
                 (string-match-p
                  (regexp-quote (format "(value %s)" expected-value))
                  external))
      (error "Unicode benchmark interaction failed: %s" external))))

(defun consent--unicode-benchmark-eval-import (options)
  "Import `(scheme char)' in a fresh context using OPTIONS."
  (consent-eval-source
   "(import (scheme base) (scheme char))\n'ok"
   nil
   options))

(defun consent--unicode-benchmark-prepare-interaction (options)
  "Return an imported interaction with benchmark procedures using OPTIONS."
  (let ((interaction (consent-make-interaction-context options)))
    (dolist
        (source
         '("(import (scheme base) (scheme char))"
           "(define (benchmark-ascii remaining value)\
              (if (= remaining 0)\
                  value\
                  (benchmark-ascii\
                   (- remaining 1)\
                   (char-alphabetic? #\\A))))"
           "(define (benchmark-bmp remaining value)\
              (if (= remaining 0)\
                  value\
                  (benchmark-bmp\
                   (- remaining 1)\
                   (char-alphabetic? #\\x03BB))))"
           "(define (benchmark-full-string remaining value)\
              (if (= remaining 0)\
                  value\
                  (benchmark-full-string\
                   (- remaining 1)\
                   (string-upcase \"Stra\\x00DF;e\"))))"))
      (consent--unicode-benchmark-validate-result
       (consent-interaction-eval-form interaction (consent-read source))
       "(unspecified)"))
    interaction))

(defun consent--unicode-benchmark-interaction-call
    (interaction procedure iterations)
  "Call PROCEDURE with ITERATIONS in persistent INTERACTION."
  (consent-interaction-eval-form
   interaction
   (consent-read (format "(%s %d #f)" procedure iterations))))

(defun consent--unicode-benchmark-run ()
  "Run and print the opt-in Unicode performance measurements."
  (let* ((iterations
          (consent--unicode-benchmark-positive-integer-env
           "CONSENT_UNICODE_BENCHMARK_ITERATIONS"
           consent--unicode-benchmark-default-iterations))
         (import-iterations
          (consent--unicode-benchmark-positive-integer-env
           "CONSENT_UNICODE_BENCHMARK_IMPORT_ITERATIONS"
           consent--unicode-benchmark-default-import-iterations))
         (options
          (consent--unicode-benchmark-options
           (max iterations import-iterations))))
    (consent--unicode-benchmark-measure
     'unicode.scheme-char.import.cold
     1
     (lambda () (consent--unicode-benchmark-eval-import options))
     (lambda (value)
       (consent--unicode-benchmark-validate-value value "ok")))
    (consent--unicode-benchmark-measure
     'unicode.scheme-char.import.warm-fresh-context
     import-iterations
     (lambda ()
       (let (value)
         (dotimes (_ import-iterations value)
           (setq value
                 (consent--unicode-benchmark-eval-import options)))))
     (lambda (value)
       (consent--unicode-benchmark-validate-value value "ok")))
    (let ((interaction
           (consent--unicode-benchmark-prepare-interaction options)))
      (consent--unicode-benchmark-measure
       'unicode.char-alphabetic.ascii.persistent
       iterations
       (lambda ()
         (consent--unicode-benchmark-interaction-call
          interaction "benchmark-ascii" iterations))
       (lambda (result)
         (consent--unicode-benchmark-validate-result result "#t")))
      (consent--unicode-benchmark-measure
       'unicode.char-alphabetic.bmp.persistent
       iterations
       (lambda ()
         (consent--unicode-benchmark-interaction-call
          interaction "benchmark-bmp" iterations))
       (lambda (result)
         (consent--unicode-benchmark-validate-result result "#t")))
      (consent--unicode-benchmark-measure
       'unicode.string-upcase.full.persistent
       iterations
       (lambda ()
         (consent--unicode-benchmark-interaction-call
          interaction "benchmark-full-string" iterations))
       (lambda (result)
         (consent--unicode-benchmark-validate-result
          result "\"STRASSE\""))))))

(when noninteractive
  (condition-case condition
      (progn
        (consent--unicode-benchmark-run)
        (kill-emacs 0))
    (error
     (message "benchmark-unicode: %s" (error-message-string condition))
     (kill-emacs 1))))

;;; benchmark-unicode.el ends here
