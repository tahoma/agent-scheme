;;; Portable compiler-front-end plan tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (consent compiler-plan)
        (testing registry)
        (testing runner)
        (stdlib testing))

;; Resolve the default compiler image once for structural assertions.
(define plan (consent-compiler-plan))
;; Keep the canonical unit sequence available to every plan test.
(define units (consent-compiler-plan-units plan))

(define (raises? thunk)
  "Return #t when THUNK raises a Scheme condition."
  (guard (condition (else #t))
    (thunk)
    #f))

(define (unit-names values)
  "Return the canonical names of compiler unit VALUES."
  (map consent-compiler-unit-name values))

(define (name-position name names)
  "Return NAME's zero-based position in NAMES, or #f."
  (let loop ((rest names) (index 0))
    (cond
     ((null? rest) #f)
     ((equal? name (car rest)) index)
     (else (loop (cdr rest) (+ index 1))))))

(define (unique-names? names)
  "Return #t when NAMES contains no duplicate library identity."
  (let loop ((rest names) (seen '()))
    (or (null? rest)
        (and (not (member (car rest) seen))
             (loop (cdr rest) (cons (car rest) seen))))))

(define (dependencies-precede-units? values)
  "Return #t when every planned dependency precedes its consumer."
  (let ((names (unit-names values)))
    (let loop ((rest values))
      (or
       (null? rest)
       (let* ((unit (car rest))
              (position
               (name-position (consent-compiler-unit-name unit) names)))
         (and
          (let dependency-loop
              ((dependencies
                (consent-compiler-unit-dependencies unit)))
            (or
             (null? dependencies)
             (let ((dependency-position
                    (name-position (car dependencies) names)))
               (and (or (not dependency-position)
                        (< dependency-position position))
                    (dependency-loop (cdr dependencies))))))
          (loop (cdr rest))))))))

(define (ordered-before? earlier later)
  "Return #t when planned unit EARLIER precedes planned unit LATER."
  (let* ((names (unit-names units))
         (earlier-position (name-position earlier names))
         (later-position (name-position later names)))
    (and earlier-position
         later-position
         (< earlier-position later-position))))

(define (unit-ref name)
  "Return the planned compiler unit named NAME, or #f."
  (let loop ((rest units))
    (cond
     ((null? rest) #f)
     ((equal? name (consent-compiler-unit-name (car rest))) (car rest))
     (else (loop (cdr rest))))))

(testing-registry-case
 'canonical-plan '(portable compiler manifest)
(let ((names (unit-names units)))
  (test-assert 'compiler-unit-names-unique (unique-names? names))
  (test-assert 'dependencies-precede-consumers
               (dependencies-precede-units? units))
  (test-equal 'plan-deterministic plan (consent-compiler-plan))
  (test-assert 'unknown-image-rejected
               (raises?
                (lambda ()
                  (consent-compiler-plan 'missing-image))))))

(testing-registry-case
 'symbol-storage-order '(portable compiler manifest symbol)
(begin
  (test-assert
   'avl-implementation-library-absent
   (not (member '(data avl-tree implementation) (unit-names units))))
  (test-assert
   'avl-before-transient-map
   (ordered-before? '(data avl-tree) '(data transient-map)))
  (test-assert
   'transient-map-before-symbols
   (ordered-before? '(data transient-map) '(consent symbol)))
  (test-assert
   'symbols-before-boundary
   (ordered-before? '(consent symbol) '(consent symbol-boundary)))
  (test-assert
   'symbol-boundary-before-reader
   (ordered-before? '(consent symbol-boundary) '(consent reader)))
  (test-assert
   'borrowed-host-shares-compiled-symbol-storage
   (let ((native-libraries
          (consent-compiler-plan-native-libraries plan)))
     (and
      (member '(data avl-tree) native-libraries)
      (not (member '(data transient-map) native-libraries))
      (member '(consent symbol) native-libraries)
      (member '(consent symbol-boundary) native-libraries))))
  (test-assert
   'symbol-storage-remains-in-compiler-graph
   (let ((names (unit-names units)))
     (and (member '(data avl-tree) names)
          (member '(data transient-map) names)
          (member '(consent symbol) names)
          (member '(consent symbol-boundary) names))))
  (test-equal
   'avl-uses-canonical-portable-source
   "data/avl-tree.sld"
   (consent-compiler-unit-source (unit-ref '(data avl-tree))))
  (test-equal
   'transient-map-uses-canonical-portable-source
   "data/transient-map.sld"
   (consent-compiler-unit-source (unit-ref '(data transient-map))))
  (test-equal
   'symbol-table-uses-canonical-portable-source
   "consent/symbol.sld"
   (consent-compiler-unit-source (unit-ref '(consent symbol))))
  (test-assert
   'mapping-implementation-before-facade
   (ordered-before?
    '(stdlib mapping implementation)
    '(stdlib mapping)))
  (test-assert
   'mapping-facade-before-avl-provider
   (ordered-before? '(stdlib mapping) '(data mapping avl)))))

(testing-registry-case
 'compiler-link-contract '(portable compiler manifest)
(let ((roots (consent-compiler-plan-roots plan))
      (native-libraries
       (consent-compiler-plan-native-libraries plan))
      (names (unit-names units)))
  (test-assert
   'native-libraries-are-roots
   (let loop ((rest native-libraries))
     (or (null? rest)
         (and (member (car rest) roots)
              (loop (cdr rest))))))
  (test-assert
   'native-libraries-have-units
   (let loop ((rest native-libraries))
     (or (null? rest)
         (and (member (car rest) names)
              (loop (cdr rest))))))
  (test-equal
   'generated-embedded-source-is-last
   '(consent embedded-source)
   (consent-compiler-unit-name
    (car (reverse units))))))

(testing-registry-case
 'portable-agent-realizations '(portable compiler manifest agent)
(begin
  (test-equal
   'context-uses-canonical-portable-source
   "agent/context.sld"
   (consent-compiler-unit-source (unit-ref '(agent context))))
  (test-equal
   'redaction-uses-canonical-portable-source
   "agent/redaction.sld"
   (consent-compiler-unit-source (unit-ref '(agent redaction))))))

(testing-runner-main "Compiler plan" (command-line))
