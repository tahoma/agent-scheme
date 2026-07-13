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
        (testing plan)
        (testing registry)
        (testing runner)
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
        (srfi srfi-261)
        (scheme process-context)
        (stdlib testing))

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

;; Manifest entry for portable multi-program test plans.
(define testing-plan-entry
  (testing-library-manifest-ref '(testing plan)))

;; Manifest entry for the developer-facing portable test runner.
(define testing-runner-entry
  (testing-library-manifest-ref '(testing runner)))

;; Output string used to verify that pure alias exports include json-write.
(define json-output (open-output-string))

(testing-registry-case
 'consent-manifest-smoke-case-1 '(portable core)
 ("consent-manifest-smoke-test.scm" 168)
(json-write '((ok . #t)) json-output))

(testing-registry-case
 'manifest-smoke-consent-json-entry-kind '(portable core)
 ("consent-manifest-smoke-test.scm" 173)
(test-equal 'manifest-smoke-consent-json-entry-kind
             'manifest-index-entry
             (car consent-json-entry)))

(testing-registry-case
 'manifest-smoke-testing-harness-kind '(portable core)
 ("consent-manifest-smoke-test.scm" 180)
(test-equal 'manifest-smoke-testing-harness-kind
             'manifest-entry
             (car testing-harness-entry)))

(testing-registry-case
 'manifest-smoke-testing-harness-source '(portable core)
 ("consent-manifest-smoke-test.scm" 187)
(test-equal 'manifest-smoke-testing-harness-source
             '(path "harness.sld")
             (field testing-harness-entry 'source)))

(testing-registry-case
 'manifest-smoke-testing-registry-source '(portable core)
 ("consent-manifest-smoke-test.scm" 194)
(test-equal 'manifest-smoke-testing-registry-source
             '(path "registry.sld")
             (field testing-registry-entry 'source)))

(testing-registry-case
 'manifest-smoke-testing-plan-source '(portable core)
 ("consent-manifest-smoke-test.scm" 201)
(test-equal 'manifest-smoke-testing-plan-source
             '(path "plan.sld")
             (field testing-plan-entry 'source)))

(testing-registry-case
 'manifest-smoke-testing-runner-source '(portable core)
 ("consent-manifest-smoke-test.scm" 208)
(test-equal 'manifest-smoke-testing-runner-source
             '(path "runner.sld")
             (field testing-runner-entry 'source)))

(testing-registry-case
 'manifest-smoke-consent-json-target '(portable core)
 ("consent-manifest-smoke-test.scm" 215)
(test-equal 'manifest-smoke-consent-json-target
             '(stdlib json)
             (field consent-json-entry 'target)))

(testing-registry-case
 'manifest-smoke-consent-json-omits-redundant-exports '(portable core)
 ("consent-manifest-smoke-test.scm" 222)
(test-equal 'manifest-smoke-consent-json-omits-redundant-exports
             #f
             (field-present? consent-json-entry 'exports)))

(testing-registry-case
 'manifest-smoke-consent-json-inherits-write '(portable core)
 ("consent-manifest-smoke-test.scm" 229)
(test-equal 'manifest-smoke-consent-json-inherits-write
             #t
             (let ((decoded (json-read (open-input-string (get-output-string json-output)))))
         (cdr (assq 'ok decoded)))))

(testing-registry-case
 'manifest-smoke-srfi-1-alias-import '(portable core)
 ("consent-manifest-smoke-test.scm" 237)
(test-equal 'manifest-smoke-srfi-1-alias-import
             '(0 1 2 3)
             (iota 4)))

(testing-registry-case
 'manifest-smoke-srfi-0-entry-kind '(portable core)
 ("consent-manifest-smoke-test.scm" 244)
(test-equal 'manifest-smoke-srfi-0-entry-kind
             'manifest-index-entry
             (car srfi-0-entry)))

(testing-registry-case
 'manifest-smoke-srfi-0-target '(portable core)
 ("consent-manifest-smoke-test.scm" 251)
(test-equal 'manifest-smoke-srfi-0-target
             '(scheme base)
             (field srfi-0-entry 'target)))

(testing-registry-case
 'manifest-smoke-srfi-0-aliases '(portable core)
 ("consent-manifest-smoke-test.scm" 258)
(test-equal 'manifest-smoke-srfi-0-aliases
             '((srfi srfi-0))
             (field srfi-0-entry 'aliases)))

(testing-registry-case
 'manifest-smoke-srfi-0-portable-alias-target '(portable core)
 ("consent-manifest-smoke-test.scm" 265)
(test-equal 'manifest-smoke-srfi-0-portable-alias-target
             '(scheme base)
             (field srfi-0-portable-entry 'target)))

(testing-registry-case
 'manifest-smoke-srfi-0-cond-expand-import '(portable core)
 ("consent-manifest-smoke-test.scm" 272)
(test-equal 'manifest-smoke-srfi-0-cond-expand-import
             'srfi-0-imported
             (cond-expand
        (srfi-0 'srfi-0-imported)
        (else 'missing))))

(testing-registry-case
 'manifest-smoke-srfi-27-entry-kind '(portable core)
 ("consent-manifest-smoke-test.scm" 281)
(test-equal 'manifest-smoke-srfi-27-entry-kind
             'manifest-index-entry
             (car srfi-27-entry)))

(testing-registry-case
 'manifest-smoke-srfi-27-target '(portable core)
 ("consent-manifest-smoke-test.scm" 288)
(test-equal 'manifest-smoke-srfi-27-target
             '(stdlib random-bits)
             (field srfi-27-entry 'target)))

(testing-registry-case
 'manifest-smoke-srfi-27-legacy-target '(portable core)
 ("consent-manifest-smoke-test.scm" 295)
(test-equal 'manifest-smoke-srfi-27-legacy-target
             '(stdlib random-bits)
             (field srfi-27-legacy-entry 'target)))

(testing-registry-case
 'manifest-smoke-srfi-27-random-source '(portable core)
 ("consent-manifest-smoke-test.scm" 302)
(test-equal 'manifest-smoke-srfi-27-random-source
             #t
             (random-source? (make-random-source))))

(testing-registry-case
 'manifest-smoke-random-distributions-entry-kind '(portable core)
 ("consent-manifest-smoke-test.scm" 309)
(test-equal 'manifest-smoke-random-distributions-entry-kind
             'manifest-entry
             (car random-distributions-entry)))

(testing-registry-case
 'manifest-smoke-random-distribution-import '(portable core)
 ("consent-manifest-smoke-test.scm" 316)
(test-equal 'manifest-smoke-random-distribution-import
             4
             (vector-length (random-permutation 4))))

(testing-registry-case
 'manifest-smoke-srfi-194-target '(portable core)
 ("consent-manifest-smoke-test.scm" 323)
(test-equal 'manifest-smoke-srfi-194-target
             '(stdlib random-data-generators)
             (field srfi-194-entry 'target)))

(testing-registry-case
 'manifest-smoke-srfi-194-portable-target '(portable core)
 ("consent-manifest-smoke-test.scm" 330)
(test-equal 'manifest-smoke-srfi-194-portable-target
             '(stdlib random-data-generators)
             (field srfi-194-portable-entry 'target)))

(testing-registry-case
 'manifest-smoke-srfi-194-bernoulli-import '(portable core)
 ("consent-manifest-smoke-test.scm" 337)
(test-equal 'manifest-smoke-srfi-194-bernoulli-import
             1
             ((make-bernoulli-generator 1))))

(testing-registry-case
 'manifest-smoke-srfi-252-target '(portable core)
 ("consent-manifest-smoke-test.scm" 344)
(test-equal 'manifest-smoke-srfi-252-target
             '(stdlib property-testing)
             (field srfi-252-entry 'target)))

(testing-registry-case
 'manifest-smoke-srfi-252-portable-target '(portable core)
 ("consent-manifest-smoke-test.scm" 351)
(test-equal 'manifest-smoke-srfi-252-portable-target
             '(stdlib property-testing)
             (field srfi-252-portable-entry 'target)))

(testing-registry-case
 'manifest-smoke-srfi-252-property-import '(portable core)
 ("consent-manifest-smoke-test.scm" 358)
(test-equal 'manifest-smoke-srfi-252-property-import
             2
             (let ((runner (test-runner-null)))
         (test-with-runner runner
           (test-begin "srfi-252-smoke" 2)
           (test-property boolean? (list (boolean-generator)) 2)
           (test-end "srfi-252-smoke"))
         (test-runner-pass-count runner))))

(testing-registry-case
 'manifest-smoke-srfi-64-runner '(portable core)
 ("consent-manifest-smoke-test.scm" 370)
(test-equal 'manifest-smoke-srfi-64-runner
             '(2 0)
             (let ((runner (test-runner-null)))
         (test-with-runner runner
           (test-begin "srfi-64-smoke" 2)
           (test-assert "assertion" #t)
           (test-approximate "approximate" 10.0 10.01 0.1)
           (test-end "srfi-64-smoke"))
         (list (test-runner-pass-count runner)
               (test-runner-fail-count runner)))))

(testing-registry-case
 'manifest-smoke-srfi-42-target '(portable core)
 ("consent-manifest-smoke-test.scm" 384)
(test-equal 'manifest-smoke-srfi-42-target
             '(stdlib eager-comprehensions)
             (field srfi-42-entry 'target)))

(testing-registry-case
 'manifest-smoke-srfi-42-portable-target '(portable core)
 ("consent-manifest-smoke-test.scm" 391)
(test-equal 'manifest-smoke-srfi-42-portable-target
             '(stdlib eager-comprehensions)
             (field srfi-42-portable-entry 'target)))

(testing-registry-case
 'manifest-smoke-srfi-42-import '(portable core)
 ("consent-manifest-smoke-test.scm" 398)
(test-equal 'manifest-smoke-srfi-42-import
             '(0 1 4 9 16)
             (list-ec (:range i 5) (* i i))))

(testing-registry-case
 'manifest-smoke-srfi-78-target '(portable core)
 ("consent-manifest-smoke-test.scm" 405)
(test-equal 'manifest-smoke-srfi-78-target
             '(stdlib lightweight-testing)
             (field srfi-78-entry 'target)))

(testing-registry-case
 'manifest-smoke-srfi-78-portable-target '(portable core)
 ("consent-manifest-smoke-test.scm" 412)
(test-equal 'manifest-smoke-srfi-78-portable-target
             '(stdlib lightweight-testing)
             (field srfi-78-portable-entry 'target)))

(testing-registry-case
 'manifest-smoke-srfi-78-import '(portable core)
 ("consent-manifest-smoke-test.scm" 419)
(test-equal 'manifest-smoke-srfi-78-import
             #t
             (begin
         (check-set-mode! 'summary)
         (check-reset!)
         (check-passed? 0))))

(testing-registry-case
 'manifest-smoke-srfi-97-entry-kind '(portable core)
 ("consent-manifest-smoke-test.scm" 429)
(test-equal 'manifest-smoke-srfi-97-entry-kind
             'manifest-index-entry
             (car srfi-97-entry)))

(testing-registry-case
 'manifest-smoke-srfi-97-target '(portable core)
 ("consent-manifest-smoke-test.scm" 436)
(test-equal 'manifest-smoke-srfi-97-target
             '(stdlib srfi-libraries)
             (field srfi-97-entry 'target)))

(testing-registry-case
 'manifest-smoke-srfi-97-list-target '(portable core)
 ("consent-manifest-smoke-test.scm" 443)
(test-equal 'manifest-smoke-srfi-97-list-target
             '(stdlib list)
             (field srfi-97-list-entry 'target)))

(testing-registry-case
 'manifest-smoke-srfi-261-entry-kind '(portable core)
 ("consent-manifest-smoke-test.scm" 450)
(test-equal 'manifest-smoke-srfi-261-entry-kind
             'manifest-index-entry
             (car srfi-261-entry)))

(testing-registry-case
 'manifest-smoke-srfi-261-target '(portable core)
 ("consent-manifest-smoke-test.scm" 457)
(test-equal 'manifest-smoke-srfi-261-target
             '(stdlib srfi-reference)
             (field srfi-261-entry 'target)))

(testing-registry-case
 'manifest-smoke-srfi-261-aliases '(portable core)
 ("consent-manifest-smoke-test.scm" 464)
(test-equal 'manifest-smoke-srfi-261-aliases
             '((srfi srfi-261))
             (field srfi-261-entry 'aliases)))

(testing-registry-case
 'manifest-smoke-srfi-261-portable-alias-contract '(portable core)
 ("consent-manifest-smoke-test.scm" 471)
(test-equal 'manifest-smoke-srfi-261-portable-alias-contract
             #t
             (srfi-261-alias-contract? stdlib-manifest)))

(testing-registry-case
 'manifest-smoke-srfi-261-portable-alias-target '(portable core)
 ("consent-manifest-smoke-test.scm" 478)
(test-equal 'manifest-smoke-srfi-261-portable-alias-target
             '(stdlib srfi-reference)
             (field srfi-261-portable-entry 'target)))

(testing-runner-main "Consent Manifest Smoke portable tests" (command-line))
