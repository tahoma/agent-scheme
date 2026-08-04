;;; character-classification-tables.scm --- Character conformance
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This independently readable program exercises the owned
;;; character model through the shared conformance corpus.

(import (scheme base) (scheme char))

(define (range lower upper)
  "Return the inclusive integer range from LOWER through UPPER."
  (let loop ((value upper) (result '()))
    (if (< value lower)
        result
        (loop (- value 1) (cons value result)))))

(define (all? predicate values)
  "Return whether PREDICATE accepts every member of VALUES."
  (or (null? values)
      (and (predicate (car values))
           (all? predicate (cdr values)))))

(define (codes-satisfy? predicate codes)
  "Return whether PREDICATE accepts the character for every code."
  (all? (lambda (code) (predicate (integer->char code))) codes))

(let* ((upper
        (append (range 65 90)
                (range 192 214)
                (range 216 222)
                '(304 376 7838)
                (range 913 929)
                (range 931 939)))
       (lower
        (append (range 97 122)
                (range 224 246)
                (range 248 255)
                '(170 181 186 305)
                (range 945 961)
                (range 962 971)))
       (outside '(64 91 96 123 169 171 185 187 215 880 930 940 128578)))
  (list
   (codes-satisfy? char-upper-case? upper)
   (codes-satisfy? char-lower-case? lower)
   (codes-satisfy? char-alphabetic? (append upper lower))
   (all? (lambda (code)
           (let ((character (integer->char code)))
             (and (not (char-upper-case? character))
                  (not (char-lower-case? character))
                  (not (char-alphabetic? character)))))
         outside)))
