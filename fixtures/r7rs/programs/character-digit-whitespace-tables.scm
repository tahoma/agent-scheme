;;; character-digit-whitespace-tables.scm --- Character conformance
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This independently readable program exercises the owned
;;; character model through the shared conformance corpus.

(import (scheme base) (scheme char))

(define (all? predicate values)
  "Return whether PREDICATE accepts every member of VALUES."
  (or (null? values)
      (and (predicate (car values))
           (all? predicate (cdr values)))))

(let ((digits '((48 . 0) (57 . 9) (1632 . 0) (1641 . 9)
                (1776 . 0) (1785 . 9) (2406 . 0) (2415 . 9)
                (2534 . 0) (2543 . 9) (2662 . 0) (2671 . 9)
                (2790 . 0) (2799 . 9) (#x104a0 . 0) (#x104a9 . 9)
                (#x1d7ce . 0) (#x1d7d7 . 9) (#x1e950 . 0)
                (#x1e959 . 9) (#x1fbf0 . 0) (#x1fbf9 . 9)))
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
   (all? (lambda (pair)
           (let ((character (integer->char (car pair))))
             (and (char-numeric? character)
                  (= (digit-value character) (cdr pair)))))
         digits)
   (all? (lambda (code)
           (let ((character (integer->char code)))
             (and (not (char-numeric? character))
                  (not (digit-value character)))))
         digit-neighbors)
   (all? (lambda (code) (char-whitespace? (integer->char code)))
         spaces)
   (all? (lambda (code) (not (char-whitespace? (integer->char code))))
         space-neighbors)))
