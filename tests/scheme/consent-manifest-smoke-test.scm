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
        (testing manifest)
        (testing harness)
        (testing registry)
        (stdlib manifest)
        (consent json)
        (srfi 0)
        (srfi srfi-0)
        (srfi 1)
        (srfi :1 lists)
        (srfi 64)
        (srfi 27)
        (srfi :27 random-bits)
        (stdlib random-distributions)
        (srfi 194)
        (srfi srfi-194)
        (srfi 252)
        (srfi srfi-252)
        (srfi 42)
        (srfi srfi-42)
        (only (srfi 78) check-set-mode! check-reset! check-passed?)
        (except (srfi srfi-78)
                check
                check-ec
                check-report
                check-set-mode!
                check-reset!
                check-passed?)
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

;; Manifest entry for the SRFI 0 cond-expand shim.
(define srfi-0-entry (stdlib-manifest-ref '(srfi 0)))

;; Manifest entry for the SRFI 0 portable SRFI reference alias.
(define srfi-0-portable-entry (stdlib-manifest-ref '(srfi srfi-0)))

;; Manifest entry for the SRFI 261 reference-name shim.
(define srfi-261-entry (stdlib-manifest-ref '(srfi 261)))

;; Manifest entry for the SRFI 97 library-reference shim.
(define srfi-97-entry (stdlib-manifest-ref '(srfi 97)))

;; Manifest entry for a SRFI 97 legacy list-library alias.
(define srfi-97-list-entry (stdlib-manifest-ref '(srfi :1 lists)))

;; Manifest entry for the SRFI 27 random-bits alias.
(define srfi-27-entry (stdlib-manifest-ref '(srfi 27)))

;; Manifest entry for the SRFI 27 legacy random-bits alias.
(define srfi-27-legacy-entry (stdlib-manifest-ref '(srfi :27 random-bits)))

;; Manifest entry for the random distribution helper library.
(define random-distributions-entry
  (stdlib-manifest-ref '(stdlib random-distributions)))

;; Manifest entry for the SRFI 194 random-data-generator alias.
(define srfi-194-entry (stdlib-manifest-ref '(srfi 194)))

;; Manifest entry for the SRFI 194 portable SRFI reference alias.
(define srfi-194-portable-entry (stdlib-manifest-ref '(srfi srfi-194)))

;; Manifest entry for the SRFI 252 property-testing alias.
(define srfi-252-entry (stdlib-manifest-ref '(srfi 252)))

;; Manifest entry for the SRFI 252 portable SRFI reference alias.
(define srfi-252-portable-entry (stdlib-manifest-ref '(srfi srfi-252)))

;; Manifest entry for the SRFI 42 eager-comprehensions alias.
(define srfi-42-entry (stdlib-manifest-ref '(srfi 42)))

;; Manifest entry for the SRFI 42 portable SRFI reference alias.
(define srfi-42-portable-entry (stdlib-manifest-ref '(srfi srfi-42)))

;; Manifest entry for the SRFI 78 lightweight-testing alias.
(define srfi-78-entry (stdlib-manifest-ref '(srfi 78)))

;; Manifest entry for the SRFI 78 portable SRFI reference alias.
(define srfi-78-portable-entry (stdlib-manifest-ref '(srfi srfi-78)))

;; Manifest entry for the SRFI 261 portable SRFI reference alias.
(define srfi-261-portable-entry (stdlib-manifest-ref '(srfi srfi-261)))

;; Manifest entry for the reusable portable test harness.
(define testing-harness-entry
  (testing-library-manifest-ref '(testing harness)))

;; Manifest entry for portable registered test discovery and selection.
(define testing-registry-entry
  (testing-library-manifest-ref '(testing registry)))

;; Output string used to verify that pure alias exports include json-write.
(define json-output (open-output-string))

(json-write '((ok . #t)) json-output)

(check 'manifest-smoke-consent-json-entry-kind
       (car consent-json-entry)
       'manifest-index-entry)

(check 'manifest-smoke-testing-harness-kind
       (car testing-harness-entry)
       'manifest-entry)

(check 'manifest-smoke-testing-harness-source
       (field testing-harness-entry 'source)
       '(path "harness.sld"))

(check 'manifest-smoke-testing-registry-source
       (field testing-registry-entry 'source)
       '(path "registry.sld"))

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

(check 'manifest-smoke-srfi-0-entry-kind
       (car srfi-0-entry)
       'manifest-index-entry)

(check 'manifest-smoke-srfi-0-target
       (field srfi-0-entry 'target)
       '(scheme base))

(check 'manifest-smoke-srfi-0-aliases
       (field srfi-0-entry 'aliases)
       '((srfi srfi-0)))

(check 'manifest-smoke-srfi-0-portable-alias-target
       (field srfi-0-portable-entry 'target)
       '(scheme base))

(check 'manifest-smoke-srfi-0-cond-expand-import
       (cond-expand
        (srfi-0 'srfi-0-imported)
        (else 'missing))
       'srfi-0-imported)

(check 'manifest-smoke-srfi-27-entry-kind
       (car srfi-27-entry)
       'manifest-index-entry)

(check 'manifest-smoke-srfi-27-target
       (field srfi-27-entry 'target)
       '(stdlib random-bits))

(check 'manifest-smoke-srfi-27-legacy-target
       (field srfi-27-legacy-entry 'target)
       '(stdlib random-bits))

(check 'manifest-smoke-srfi-27-random-source
       (random-source? (make-random-source))
       #t)

(check 'manifest-smoke-random-distributions-entry-kind
       (car random-distributions-entry)
       'manifest-entry)

(check 'manifest-smoke-random-distribution-import
       (vector-length (random-permutation 4))
       4)

(check 'manifest-smoke-srfi-194-target
       (field srfi-194-entry 'target)
       '(stdlib random-data-generators))

(check 'manifest-smoke-srfi-194-portable-target
       (field srfi-194-portable-entry 'target)
       '(stdlib random-data-generators))

(check 'manifest-smoke-srfi-194-bernoulli-import
       ((make-bernoulli-generator 1))
       1)

(check 'manifest-smoke-srfi-252-target
       (field srfi-252-entry 'target)
       '(stdlib property-testing))

(check 'manifest-smoke-srfi-252-portable-target
       (field srfi-252-portable-entry 'target)
       '(stdlib property-testing))

(check 'manifest-smoke-srfi-252-property-import
       (let ((runner (test-runner-null)))
         (test-with-runner runner
           (test-begin "srfi-252-smoke" 2)
           (test-property boolean? (list (boolean-generator)) 2)
           (test-end "srfi-252-smoke"))
         (test-runner-pass-count runner))
       2)

(check 'manifest-smoke-srfi-64-runner
       (let ((runner (test-runner-null)))
         (test-with-runner runner
           (test-begin "srfi-64-smoke" 2)
           (test-assert "assertion" #t)
           (test-approximate "approximate" 10.0 10.01 0.1)
           (test-end "srfi-64-smoke"))
         (list (test-runner-pass-count runner)
               (test-runner-fail-count runner)))
       '(2 0))

(check 'manifest-smoke-srfi-42-target
       (field srfi-42-entry 'target)
       '(stdlib eager-comprehensions))

(check 'manifest-smoke-srfi-42-portable-target
       (field srfi-42-portable-entry 'target)
       '(stdlib eager-comprehensions))

(check 'manifest-smoke-srfi-42-import
       (list-ec (:range i 5) (* i i))
       '(0 1 4 9 16))

(check 'manifest-smoke-srfi-78-target
       (field srfi-78-entry 'target)
       '(stdlib lightweight-testing))

(check 'manifest-smoke-srfi-78-portable-target
       (field srfi-78-portable-entry 'target)
       '(stdlib lightweight-testing))

(check 'manifest-smoke-srfi-78-import
       (begin
         (check-set-mode! 'summary)
         (check-reset!)
         (check-passed? 0))
       #t)

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
