;;; character-digit-whitespace-tables.scm --- Character conformance
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

(let ((zeros '(48 1632 1776 2406 2534 2662 2790))
      (digit-neighbors
       '(47 58 1631 1642 1775 1786 2405 2416 2533 2544 2661 2672
         2789 2800))
      (spaces
       '(9 10 11 12 13 32 133 160 5760 8192 8193 8194 8195 8196
         8197 8198 8199 8200 8201 8202 8232 8233 8239 8287 12288))
      (space-neighbors
       '(8 14 31 33 132 134 159 161 5759 5761 8191 8203 8231 8234
         8238 8240 8286 8288 12287 12289)))
  (list
   (all? (lambda (zero)
           (all? (lambda (value)
                   (let ((character (integer->char (+ zero value))))
                     (and (char-numeric? character)
                          (= (digit-value character) value))))
                 (range 0 9)))
         zeros)
   (all? (lambda (code)
           (let ((character (integer->char code)))
             (and (not (char-numeric? character))
                  (not (digit-value character)))))
         digit-neighbors)
   (all? (lambda (code) (char-whitespace? (integer->char code)))
         spaces)
   (all? (lambda (code) (not (char-whitespace? (integer->char code))))
         space-neighbors)))
