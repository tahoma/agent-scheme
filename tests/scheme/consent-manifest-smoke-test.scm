;;; Portable manifest bootstrap smoke tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This compact file runs under compiled portable hosts, where manifest-only
;;; aliases are resolved by the Consent runtime rather than by a direct R7RS
;;; host's native source-file lookup. It keeps manifest-root bootstrap, pure
;;; alias export inheritance, and source-library imports covered without
;;; replaying the full evaluator fixture corpus through compiled `--host-run'
;;; nested interpretation.

(import (scheme base)
        (scheme write)
        (stdlib manifest)
        (consent json)
        (srfi 1))

;; Number of manifest smoke failures seen so far.
(define failures 0)

;; Record one failed manifest smoke check and keep running.
(define (record-failure name expected actual)
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

;; Compare ACTUAL and EXPECTED using R7RS equal?.
(define (check name actual expected)
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

;; Return NAME's field from manifest ENTRY, or #f when absent.
(define (field entry name)
  (let ((pair (assq name (cdr entry))))
    (if pair (cadr pair) #f)))

;; Report whether ENTRY explicitly carries field NAME.
(define (field-present? entry name)
  (if (assq name (cdr entry)) #t #f))

;; Manifest entry for the pure `(consent json)' alias.
(define consent-json-entry (stdlib-manifest-ref '(consent json)))

;; Output string used to verify that pure alias exports include json-write.
(define json-output (open-output-string))

(json-write '((ok . #t)) json-output)

(check 'manifest-smoke-consent-json-entry-kind
       (car consent-json-entry)
       'manifest-index-entry)

(check 'manifest-smoke-consent-json-target
       (field consent-json-entry 'target)
       '(stdlib json))

(check 'manifest-smoke-consent-json-omits-redundant-exports
       (field-present? consent-json-entry 'exports)
       #f)

(check 'manifest-smoke-consent-json-inherits-write
       (let ((decoded (json-read (open-input-string (get-output-string json-output)))))
         (cdr (assq 'ok decoded)))
       #t)

(check 'manifest-smoke-srfi-1-alias-import
       (iota 4)
       '(0 1 2 3))

(if (= failures 0)
    (begin
      (display "Manifest smoke tests passed")
      (newline))
    (begin
      (display failures)
      (display " manifest smoke test failure(s)")
      (newline)
      (error "manifest smoke tests failed" failures)))
