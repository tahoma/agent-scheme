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
        (srfi 1)
        (srfi :1 lists)
        (srfi 97)
        (srfi :97 srfi-libraries)
        (srfi 261)
        (srfi srfi-261))

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

;; Return #t when NAME is a numeric SRFI library name.
(define (numeric-srfi-name? name)
  (and (pair? name)
       (eq? (car name) 'srfi)
       (pair? (cdr name))
       (integer? (cadr name))
       (null? (cddr name))))

;; Return ENTRY's effective implementation target.
(define (entry-target entry)
  (let ((target (field entry 'target)))
    (if target target (field entry 'name))))

;; Return SRFI 261's portable alias name for SRFI NUMBER.
(define (srfi-261-alias-name number)
  (list 'srfi
        (string->symbol
         (string-append "srfi-" (number->string number)))))

;; Return #t when every numeric SRFI entry has its SRFI 261 portable alias.
(define (srfi-261-alias-contract? entries)
  (let loop ((rest entries) (checked 0))
    (if (null? rest)
        (> checked 0)
        (let* ((entry (car rest))
               (name (field entry 'name)))
          (if (numeric-srfi-name? name)
              (let ((alias (stdlib-manifest-ref
                            (srfi-261-alias-name (cadr name)))))
                (and alias
                     (eq? (field alias 'kind) 'library-alias)
                     (equal? (entry-target alias) (entry-target entry))
                     (loop (cdr rest) (+ checked 1))))
              (loop (cdr rest) checked))))))

;; Manifest entry for the pure `(consent json)' alias.
(define consent-json-entry (stdlib-manifest-ref '(consent json)))

;; Manifest entry for the SRFI 261 reference-name shim.
(define srfi-261-entry (stdlib-manifest-ref '(srfi 261)))

;; Manifest entry for the SRFI 97 library-reference shim.
(define srfi-97-entry (stdlib-manifest-ref '(srfi 97)))

;; Manifest entry for a SRFI 97 legacy list-library alias.
(define srfi-97-list-entry (stdlib-manifest-ref '(srfi :1 lists)))

;; Manifest entry for the SRFI 261 portable SRFI reference alias.
(define srfi-261-portable-entry (stdlib-manifest-ref '(srfi srfi-261)))

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

(check 'manifest-smoke-srfi-97-entry-kind
       (car srfi-97-entry)
       'manifest-index-entry)

(check 'manifest-smoke-srfi-97-target
       (field srfi-97-entry 'target)
       '(stdlib srfi-libraries))

(check 'manifest-smoke-srfi-97-list-target
       (field srfi-97-list-entry 'target)
       '(stdlib list))

(check 'manifest-smoke-srfi-261-entry-kind
       (car srfi-261-entry)
       'manifest-index-entry)

(check 'manifest-smoke-srfi-261-target
       (field srfi-261-entry 'target)
       '(stdlib srfi-reference))

(check 'manifest-smoke-srfi-261-aliases
       (field srfi-261-entry 'aliases)
       '((srfi srfi-261)))

(check 'manifest-smoke-srfi-261-portable-alias-contract
       (srfi-261-alias-contract? stdlib-manifest)
       #t)

(check 'manifest-smoke-srfi-261-portable-alias-target
       (field srfi-261-portable-entry 'target)
       '(stdlib srfi-reference))

(if (= failures 0)
    (begin
      (display "Manifest smoke tests passed")
      (newline))
    (begin
      (display failures)
      (display " manifest smoke test failure(s)")
      (newline)
      (error "manifest smoke tests failed" failures)))
