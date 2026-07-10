;;; Portable reflection catalog stress tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs the full manifest-backed reflection discovery checks that
;;; intentionally traverse and rebuild the catalog.  It is split from the quick
;;; contract file so CI can parallelize this behavior surface across hosts.

(import (scheme base)
        (scheme char)
        (scheme process-context)
        (scheme time)
        (scheme write)
        (rename (consent eval)
                (consent-eval-source raw-consent-eval-source))
        (only (consent reader)
              consent-datum->external
              consent-read
              consent-source-metadata-count))

;; Count failed checks so the portable runner reports every mismatch.
(define failures 0)

;; Minimum check duration emitted as a fine-grained CI timing diagnostic.
(define consent-ci-check-minimum-milliseconds 10)

;; Unique marker for unset CI matrix defaults.
(define consent-test-option-unset (list 'unset))

;; Return #t when VALUE is the unset marker.
(define (consent-test-option-unset? value)
  (eq? value consent-test-option-unset))

;; Parse NAME's environment value as the CI source metadata default.
(define (consent-test-source-metadata-default name)
  (let ((value (get-environment-variable name)))
    (cond
     ((or (not value) (= (string-length value) 0))
      consent-test-option-unset)
     ((or (string-ci=? value "on")
          (string-ci=? value "true")
          (string-ci=? value "t")
          (string-ci=? value "yes")
          (string=? value "1"))
      #t)
     ((or (string-ci=? value "off")
          (string-ci=? value "false")
          (string-ci=? value "nil")
          (string-ci=? value "no")
          (string=? value "0"))
      #f)
     (else
      (error "CONSENT_TEST_SOURCE_METADATA must be on or off" value)))))

;; Parse NAME's environment value as the CI docstring retention default.
(define (consent-test-docstring-retention-default name)
  (let ((value (get-environment-variable name)))
    (cond
     ((or (not value) (= (string-length value) 0))
      consent-test-option-unset)
     ((string-ci=? value "full") 'full)
     ((string-ci=? value "simple") 'simple)
     ((or (string-ci=? value "none")
          (string-ci=? value "nil")
          (string-ci=? value "off")
          (string-ci=? value "false")
          (string=? value "0"))
      #f)
     (else
      (error "CONSENT_TEST_DOCSTRING_RETENTION must be full, simple, or none"
             value)))))

;; Parse NAME's environment value as the CI source metadata budget default.
(define (consent-test-max-source-metadata-default name)
  (let ((value (get-environment-variable name)))
    (cond
     ((or (not value) (= (string-length value) 0))
      consent-test-option-unset)
     ((let ((parsed (string->number value)))
        (and parsed
             (exact? parsed)
             (integer? parsed)
             (>= parsed 0)))
      (string->number value))
     (else
      (error "CONSENT_TEST_MAX_SOURCE_METADATA must be a non-negative integer"
             value)))))

;; Return CI matrix defaults as evaluator options.
(define (consent-test-default-options)
  (let ((source-metadata
         (consent-test-source-metadata-default
          "CONSENT_TEST_SOURCE_METADATA"))
        (docstring-retention
         (consent-test-docstring-retention-default
          "CONSENT_TEST_DOCSTRING_RETENTION"))
        (max-source-metadata
         (consent-test-max-source-metadata-default
          "CONSENT_TEST_MAX_SOURCE_METADATA")))
    (append
     (if (consent-test-option-unset? source-metadata)
         '()
         (list (cons 'source-metadata source-metadata)))
     (if (consent-test-option-unset? docstring-retention)
         '()
         (list (cons 'docstring-retention docstring-retention)))
     (if (consent-test-option-unset? max-source-metadata)
         '()
         (list (cons 'max-source-metadata max-source-metadata))))))

;; Return OPTIONS with missing CI matrix defaults appended.
(define (consent-test-merge-options options)
  (let loop ((defaults (consent-test-default-options))
             (merged (if options options '())))
    (if (null? defaults)
        merged
        (let ((entry (car defaults)))
          (loop (cdr defaults)
                (if (assq (car entry) merged)
                    merged
                    (append merged (list entry))))))))

;; Return the optional environment argument from REST.
(define (consent-test-rest-environment rest)
  (if (null? rest) #f (car rest)))

;; Return the optional evaluator options argument from REST.
(define (consent-test-rest-options rest)
  (if (or (null? rest) (null? (cdr rest)))
      '()
      (cadr rest)))

;; Evaluate SOURCE text under the CI matrix defaults.
(define (consent-eval-source source . rest)
  (raw-consent-eval-source
   source
   (consent-test-rest-environment rest)
   (consent-test-merge-options (consent-test-rest-options rest))))

;; Return MILLISECONDS as three digits for fixed seconds output.
(define (milliseconds-fragment milliseconds)
  (let ((text (number->string milliseconds)))
    (cond
     ((< milliseconds 10) (string-append "00" text))
     ((< milliseconds 100) (string-append "0" text))
     (else text))))

;; Render MILLISECONDS as a fixed decimal seconds value.
(define (display-check-seconds milliseconds)
  (display (quotient milliseconds 1000))
  (display ".")
  (display (milliseconds-fragment (remainder milliseconds 1000))))

;; Emit one fine-grained timing line for CI diagnostics.
(define (record-check-timing name thunk)
  (let ((started (current-jiffy)))
    (let ((result (thunk)))
      (let ((milliseconds
             (quotient
              (+ (* (- (current-jiffy) started) 1000)
                 (quotient (jiffies-per-second) 2))
              (jiffies-per-second))))
        (if (>= milliseconds consent-ci-check-minimum-milliseconds)
            (begin
              (display "CONSENT_CI_CHECK_SECONDS=")
              (write name)
              (display " ")
              (display-check-seconds milliseconds)
              (newline))))
      result)))

;; Record one failed portable reflection check and keep running.
(define (record-failure name expected actual)
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

;; Compare ACTUAL and EXPECTED using R7RS equal? and record a named failure.
(define (check-value name actual expected)
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

;; Time one reflection stress check and then compare its value.
(define-syntax check
  (syntax-rules ()
    ((_ name actual expected)
     (record-check-timing
      name
      (lambda ()
        (check-value name actual expected))))))

;; Evaluate SOURCE and compare the stable external value representation.
(define (check-external name source expected)
  (check name
         (consent-value->external (consent-eval-source source))
         expected))

;; Evaluate SOURCE with OPTIONS and compare the stable external value.
(define (check-external/options name source options expected)
  (check name
         (consent-value->external
          (consent-eval-source source #f options))
         expected))

;; Render a readable expected datum shape as canonical external text.
(define (expected-datum-external . fragments)
  (consent-datum->external
   (consent-read (apply string-append fragments)
                 '((source-metadata . #f)))))

(check 'reflect-library-catalog-discovery-source-metadata-budget
       (let ((before (consent-source-metadata-count)))
         (let ((ignored
                (consent-eval-source
                 "(import (scheme base) (agent reflect))
                  (length (library-search \"reflect\"))"
                 #f
                 '((source-metadata . #t)
                   (max-source-metadata . 10000000)))))
           (< (- (consent-source-metadata-count) before) 1000)))
       #t)

(check-external 'reflect-library-catalog-discovery
                "(import (scheme base) (agent reflect))
                 (define (field datum name)
                   (cadr (assq name (cdr datum))))
                 (let* ((before (current-imports))
                        (reflect (library-info '(agent reflect)))
                        (lazy (library-info '(scheme lazy)))
                        (json-read (library-info '(consent json read)))
                        (hits (library-search \"reflect\"))
                        (after (current-imports)))
                   (list (field reflect 'name)
                         (field reflect 'category)
                         (field reflect 'source-kind)
                         (field lazy 'source-file)
                         (field json-read 'target)
                         (if (memq 'json-read (field json-read 'exports))
                             'json-read-exported
                             'missing-json-read)
                         (if (member '(agent reflect)
                                     (map (lambda (hit) (field hit 'name))
                                          hits))
                             'found-reflect
                             'missing-reflect)
                         (if (library-info '(missing library)) 'bad 'missing)
                         (equal? before after)))"
                (expected-datum-external
                 "((agent reflect)
                   agent
                   primitive
                   \"consent/lazy.sld\"
                   (stdlib json)
                   json-read-exported
                   found-reflect
                   missing
                   #t)"))

(check-external 'reflect-library-catalog-visibility-tiers
                "(import (scheme base) (agent reflect))
                 (define (field datum name)
                   (cadr (assq name (cdr datum))))
                 (list
                  (field (library-info '(scheme base)) 'visibility)
                  (field (library-info '(consent capability)) 'visibility)
                  (field (library-info '(srfi 16)) 'visibility)
                  (field (library-info '(consent reader)) 'visibility)
                  (field (library-info '(agent memory primitive)) 'visibility)
                  (field (library-info '(emacs buffer)) 'availability)
                  (field (library-info '(emacs buffer))
                         'availability-condition))"
                (expected-datum-external
                 "(public
                   public-consent
                   alias
                   internal-runtime
                   internal-agent-primitive
                   optional
                   (host emacs))"))

(check-external/options 'reflect-documented-bindings-and-apropos
                        "(import (scheme base) (agent reflect))
                         (define (field datum name)
                           (cadr (assq name (cdr datum))))
                         (define (metadata-field datum name)
                           (let ((entry (assq name (field datum 'fields))))
                             (if entry (cadr entry) #f)))
                         (define (documented-subject? docs name)
                           (cond
                            ((null? docs) #f)
                            ((equal? (field (car docs) 'subject)
                                     (list 'binding name))
                             #t)
                            (else (documented-subject? (cdr docs) name))))
                         (define (any-kind? matches kind)
                           (cond
                            ((null? matches) #f)
                            ((eq? (field (car matches) 'kind) kind) #t)
                            (else (any-kind? (cdr matches) kind))))
                         (define (needle-procedure x)
                           \"Return the needle value for discovery tests.\"
                           x)
                         (let* ((docs (documented-bindings))
                                (matches (apropos \"needle\"))
                                (reflect-matches (apropos \"reflect\"))
                                (library-hits (library-search \"reflect\")))
                           (list
                            (if (documented-subject? docs 'needle-procedure)
                                'documented
                                'missing)
                            (metadata-field (documentation 'needle-procedure)
                                            'documentation)
                            (if (member '(binding needle-procedure)
                                        (map (lambda (match)
                                               (list (field match 'kind)
                                                     (field match 'name)))
                                             matches))
                                'found-binding
                                'missing-binding)
                            (any-kind? reflect-matches 'library)
                            (not (null? library-hits))))"
                        '((docstring-retention . full))
                        "(documented \"Return the needle value for discovery tests.\" found-binding #f #t)")

(check-external 'reflect-binding-libraries-crosswalk
                "(import (scheme base) (agent reflect))
                 (define (field datum name)
                   (cadr (assq name (cdr datum))))
                 (let ((before (current-imports)))
                   (list (map (lambda (info) (field info 'name))
                              (binding-libraries 'force))
                         (map (lambda (info) (field info 'name))
                              (binding-libraries 'json-read))
                         (equal? before (current-imports))))"
                (expected-datum-external
                 "(((scheme lazy))
                   ((stdlib json)
                    (stdlib json read)
                    (consent json read)
                    (consent json)
                    (srfi srfi-180)
                    (srfi 180))
                   #t)"))

(check-external/options 'reflect-apropos-unmanifested-library
                        "(define-library (adhoc scratch)
                           (export adhoc-needle)
                           (import (scheme base))
                           (begin
                             (define (adhoc-needle x)
                               \"Return X from an ad-hoc library.\"
                               x)))
                         (import (scheme base) (agent reflect) (adhoc scratch))
                         (define (field datum name)
                           (cadr (assq name (cdr datum))))
                         (define (library-present? libraries name)
                           (cond
                            ((null? libraries) #f)
                            ((equal? (car libraries) name) #t)
                            (else (library-present? (cdr libraries) name))))
                         (define (match-libraries matches name)
                           (cond
                            ((null? matches) '())
                            ((eq? (field (car matches) 'name) name)
                             (field (car matches) 'libraries))
                            (else (match-libraries (cdr matches) name))))
                         (let ((binding-library-names
                                (map (lambda (info) (field info 'name))
                                     (binding-libraries 'adhoc-needle)))
                               (apropos-library-names
                                (match-libraries (apropos \"adhoc-needle\")
                                                 'adhoc-needle)))
                           (list
                            (library-present? binding-library-names
                                              '(adhoc scratch))
                            (library-present? apropos-library-names
                                              '(adhoc scratch))))"
                        '((docstring-retention . full))
                        "(#t #t)")

(check-external 'reflect-dynamic-manifest-inputs
                "(import (scheme base) (agent reflect))
                 (define (field datum name)
                   (cadr (assq name (cdr datum))))
                 (define (source-has? sources id name)
                   (cond
                    ((null? sources) #f)
                    ((and (equal? (field (car sources) 'id) id)
                          (member name (field (car sources) 'libraries)))
                     #t)
                    (else (source-has? (cdr sources) id name))))
                 (remove-manifest! 'reflect-test-session)
                 (remove-manifest-root! \"reflect-test-root\")
                 (add-manifest!
                  'reflect-test-session
                 '(library-catalog
                    (manifest-entry
                     (schema-version 1)
                     (kind library)
                     (name (project generated))
                     (owner project)
                     (provider repo-source)
                     (visibility public)
                     (layer package)
                     (category project)
                     (status experimental)
                     (source-kind source-library)
                     (source (path \"project/generated.sld\"))
                     (api-version (compat 2))
                     (source-version unknown)
                     (realization portable-source)
                     (aliases ((project generated alias)))
                     (exports (generated-run))
                     (dependencies ((library (scheme base))))
                     (documentation
                      ((summary \"Generated project library.\")))
                     (provenance ((origin project)))
                     (canonical #t)
                     (future-field ignored))))
                 (define ad-hoc-info (library-info '(project generated)))
                 (define ad-hoc-libraries
                   (map (lambda (info) (field info 'name))
                        (binding-libraries 'generated-run)))
                 (define ad-hoc-source-visible
                   (source-has? (catalog-sources)
                                'reflect-test-session
                                '(project generated)))
                 (define removed-ad-hoc
                   (remove-manifest! 'reflect-test-session))
                 (add-manifest-root!
                  \"reflect-test-root\"
                  '(library-catalog
                    (manifest-entry
                     (schema-version 1)
                     (kind library)
                     (name (project rooted))
                     (owner project)
                     (provider reflect-test-root)
                     (visibility public)
                     (category project)
                     (status available)
                     (source-kind manifest-root)
                     (realization manifest-root)
                     (exports (rooted-run))
                     (documentation
                      ((summary \"Root manifest library.\")))
                     (provenance ((origin manifest-root)))
                     (canonical #t))))
                 (define root-info (library-info '(project rooted)))
                 (define root-libraries
                   (map (lambda (info) (field info 'name))
                        (binding-libraries 'rooted-run)))
                 (define root-source-visible
                   (source-has? (catalog-sources)
                                \"reflect-test-root\"
                                '(project rooted)))
                 (define removed-root
                   (remove-manifest-root! \"reflect-test-root\"))
                 (list (field ad-hoc-info 'schema-version)
                       (field ad-hoc-info 'kind)
                       (field ad-hoc-info 'owner)
                       (field ad-hoc-info 'provider)
                       (field ad-hoc-info 'source)
                       (field ad-hoc-info 'api-version)
                       (field ad-hoc-info 'source-version)
                       (field ad-hoc-info 'realization)
                       (field ad-hoc-info 'canonical)
                       (field ad-hoc-info 'origin)
                       (field ad-hoc-info 'source-id)
                       (field ad-hoc-info 'summary)
                       ad-hoc-libraries
                       ad-hoc-source-visible
                       removed-ad-hoc
                       (if (library-info '(project generated))
                           'bad
                           'removed)
                       (field root-info 'origin)
                       (field root-info 'source-id)
                       root-libraries
                       root-source-visible
                       removed-root
                       (if (library-info '(project rooted))
                           'bad
                           'root-removed))"
                (expected-datum-external
                "(1
                  library
                  project
                  repo-source
                  (path \"project/generated.sld\")
                  (compat 2)
                  unknown
                  portable-source
                  #t
                  ad-hoc-manifest
                  reflect-test-session
                  \"Generated project library.\"
                  ((project generated))
                   #t
                   #t
                   removed
                   manifest-root
                   \"reflect-test-root\"
                   ((project rooted))
                   #t
                   #t
                   root-removed)"))

(check-external 'reflect-library-resolution-api
                "(import (scheme base) (agent reflect))
                 (define (field datum name)
                   (cadr (assq name (cdr datum))))
                 (define (has-name? names name)
                   (cond
                    ((null? names) #f)
                    ((equal? (car names) name) #t)
                    (else (has-name? (cdr names) name))))
                 (define (has-resolution? records name)
                   (cond
                    ((null? records) #f)
                    ((equal? (field (car records) 'name) name) #t)
                    (else (has-resolution? (cdr records) name))))
                 (remove-manifest! 'reflect-resolution-fixture)
                 (add-manifest!
                  'reflect-resolution-fixture
                  '(library-catalog
                    (manifest-entry
                     (schema-version 1)
                     (kind library)
                     (name (project unavailable))
                     (owner project)
                     (provider reflect-resolution-fixture)
                     (visibility public)
                     (category project)
                     (status available)
                     (source-kind source-library)
                     (source (path \"missing/unavailable.sld\"))
                     (availability optional)
                     (availability-condition (host missing-host))
                     (api-version (compat 0))
                     (source-version unknown)
                     (realization portable-source)
                     (exports (unavailable-run))
                     (dependencies ((library (scheme base))))
                     (canonical #t))
                    (manifest-index-entry
                     (schema-version 1)
                     (kind library-alias)
                     (name (project duplicated))
                     (target (scheme base))
                     (owner project)
                     (provider first-duplicate)
                     (visibility public)
                     (category project)
                     (source-kind alias)
                     (api-version (inherits (scheme base)))
                     (source-version runtime)
                     (realization alias)
                     (status available)
                     (canonical #f))
                    (manifest-index-entry
                     (schema-version 1)
                     (kind library-alias)
                     (name (project duplicated))
                     (target (scheme base))
                     (owner project)
                     (provider second-duplicate)
                     (visibility public)
                     (category project)
                     (source-kind alias)
                     (api-version (inherits (scheme base)))
                     (source-version runtime)
                     (realization alias)
                     (status available)
                     (canonical #f))
                    (manifest-entry
                     (schema-version 1)
                     (kind library)
                     (name (project needs-missing))
                     (owner project)
                     (provider repo-source)
                     (visibility public)
                     (layer package)
                     (category project)
                     (source-kind source-library)
                     (source (path \"project/needs-missing.sld\"))
                     (api-version (compat 0))
                     (source-version unknown)
                     (realization portable-source)
                     (exports (run))
                     (dependencies ((library (project absent))))
                     (provenance ((origin test-fixture)))
                     (status available)
                     (canonical #t))))
                 (define result
                   (let* ((base (library-resolve '(scheme base)))
                          (alias (library-resolve '(srfi 16)))
                          (missing (library-resolve '(missing library)))
                          (denied (library-resolve '(consent reader)))
                          (unavailable
                           (library-resolve '(project unavailable)))
                          (loaded (library-load '(srfi 16)))
                          (dependencies
                           (library-solve-dependencies '(scheme lazy)))
                          (dependency-failure
                           (library-solve-dependencies
                            '(project needs-missing)))
                          (conflict
                           (car (library-conflicts '(project duplicated))))
                          (paths (library-paths))
                          (snapshot (library-snapshot '(srfi 16)))
                          (vendored (vendored-srfi-manifest 16))
                          (vendored-missing (vendored-srfi-manifest 99999)))
                     (list
                      (list 'base
                            (field base 'status)
                            (field base 'name)
                            (field base 'resolved-name)
                            (field base 'root)
                            (field base 'source-kind)
                            (field base 'visibility))
                      (list 'alias
                            (field alias 'status)
                            (field alias 'name)
                            (field alias 'resolved-name)
                            (field alias 'target)
                            (field alias 'source-kind))
                      (list 'missing
                            (field missing 'status)
                            (field missing 'reason))
                      (list 'denied
                            (field denied 'status)
                            (field denied 'reason))
                      (list 'unavailable
                            (field unavailable 'status)
                            (field unavailable 'reason)
                            (field unavailable 'availability-condition))
                      (list 'conflict
                            (field conflict 'status)
                            (field conflict 'name)
                            (length (field conflict 'candidates)))
                      (list 'loaded
                            (field loaded 'status)
                            (field loaded 'loaded?))
                      (list 'dependencies
                            (field dependencies 'status)
                            (has-name? (field dependencies 'dependencies)
                                       '(scheme base)))
                      (list 'dependency-failure
                            (field dependency-failure 'status)
                            (field dependency-failure 'reason)
                            (has-name?
                             (field dependency-failure 'missing-dependencies)
                             '(project absent)))
                      (list 'paths
                            (not (null? paths))
                            (field (car paths) 'kind))
                      (list 'snapshot
                            (field snapshot 'status)
                            (field snapshot 'name)
                            (has-resolution? (field snapshot 'resolved)
                                             '(srfi 16)))
                      (list 'srfi-name (srfi-library-name 16))
                      (list 'srfi-aliases (srfi-library-aliases 16))
                      (list 'vendored
                            (field vendored 'classification)
                            (field vendored 'library)
                            (field vendored 'target))
                      (list 'vendored-missing
                            (field vendored-missing 'status)
                            (field vendored-missing 'reason)))))
                 (remove-manifest! 'reflect-resolution-fixture)
                 result"
                (expected-datum-external
                 "((base resolved (scheme base) (scheme base)
                         builtin base-snapshot public)
                   (alias resolved (srfi 16) (scheme case-lambda)
                          (scheme case-lambda) alias)
                   (missing missing missing-library)
                   (denied denied internal-library)
                   (unavailable unavailable availability-condition
                                (host missing-host))
                   (conflict conflict (project duplicated) 2)
                   (loaded resolved #t)
                   (dependencies resolved #t)
                   (dependency-failure unsatisfied-dependency
                                       missing-dependency #t)
                   (paths #t ad-hoc-manifest)
                   (snapshot resolved (srfi 16) #t)
                   (srfi-name (srfi 16))
                   (srfi-aliases ((srfi 16) (srfi srfi-16)))
                   (vendored shim (srfi 16) (scheme case-lambda))
                   (vendored-missing missing missing-srfi))"))

(if (= failures 0)
    (begin
      (display "Portable reflection catalog stress tests passed")
      (newline))
    (begin
      (display failures)
      (display " portable reflection catalog stress test failure(s)")
      (newline)
      (error "Portable reflection catalog stress tests failed")))
