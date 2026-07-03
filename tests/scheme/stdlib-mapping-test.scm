;;; Portable SRFI 146 ordered mapping stdlib tests.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2016 Marc Nieper-Wißkirchen
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Focused ordered-mapping coverage adapted from the upstream SRFI 146 tests.

(import (scheme base)
        (scheme write)
        (stdlib comparator)
        (stdlib mapping))

;; Number of failed ordered mapping checks seen so far.
(define failures 0)

(define (record-failure name expected actual)
  "Record one failed ordered mapping check."
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

(define (check name actual expected)
  "Compare ACTUAL and EXPECTED and record NAME on mismatch."
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

(define (finish-mapping-tests)
  "Report the ordered mapping test result."
  (if (= failures 0)
      (begin
        (display "Ordered mapping tests passed")
        (newline))
      (begin
        (display failures)
        (display " ordered mapping test failure(s)")
        (newline)
        (error "ordered mapping tests failed" failures))))

;; Comparator shared by the ordered mapping checks.
(define integer-comparator
  (make-comparator integer? = < number-hash))

;; Shared populated mapping with deliberately out-of-order construction input.
(define mapping1
  (mapping integer-comparator 3 'three 1 'one 2 'two 2 'TWO))

;; Mapping after replacement and extension operations.
(define mapping2
  (mapping-set mapping1 4 'four 2 'TWO))

(check 'constructor-preserves-earlier-duplicate
       (list (mapping? mapping1)
             (mapping-size mapping1)
             (mapping-ref mapping1 2))
       '(#t 3 two))

(check 'alist-conversion-is-ordered
       (mapping->alist mapping2)
       '((1 . one) (2 . TWO) (3 . three) (4 . four)))

(check 'keys-and-values-follow-key-order
       (call-with-values
        (lambda () (mapping-entries mapping2))
        (lambda (keys values)
          (list keys values)))
       '((1 2 3 4) (one TWO three four)))

(check 'range-and-boundary-operations
       (list (mapping-min-key mapping2)
             (mapping-max-key mapping2)
             (mapping-key-predecessor mapping2 3 (lambda () 'none))
             (mapping-key-successor mapping2 3 (lambda () 'none))
             (mapping->alist (mapping-range>= mapping2 3)))
       '(1 4 2 4 ((3 . three) (4 . four))))

(check 'set-operations-and-delete
       (let ((without-one (mapping-delete mapping2 1))
             (overlap (mapping integer-comparator 2 'TWO 4 'four 9 'nine)))
         (list (mapping-ref/default without-one 1 'missing)
               (mapping->alist (mapping-intersection mapping2 overlap))
               (mapping->alist (mapping-difference mapping2 overlap))))
       '(missing ((2 . TWO) (4 . four)) ((1 . one) (3 . three))))

(check 'search-can-update-and-ignore
       (let ((searched
              (call-with-values
               (lambda ()
                 (mapping-search mapping2
                                 3
                                 (lambda (insert ignore)
                                   (ignore 'missing))
                                 (lambda (key value update remove)
                                   (update key 'THREE 'updated))))
               (lambda (next status)
                 (list status (mapping-ref next 3))))))
         (call-with-values
          (lambda ()
            (mapping-search mapping2
                            99
                            (lambda (insert ignore)
                              (ignore 'ignored))
                            (lambda (key value update remove)
                              (remove 'removed))))
          (lambda (next status)
            (list searched status (mapping->alist next)))))
       '((updated THREE) ignored
         ((1 . one) (2 . TWO) (3 . three) (4 . four))))

(finish-mapping-tests)
