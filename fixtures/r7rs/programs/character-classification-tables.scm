;;; character-classification-tables.scm --- Character conformance
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

(define (codes-satisfy? predicate codes)
  "Return whether PREDICATE accepts the character for every code."
  (all? (lambda (code) (predicate (integer->char code))) codes))

(let* ((upper '(65 90 192 214 216 222 256 304 376 7838
                913 929 931 939 #x10400 #x10427))
       (lower '(97 122 170 181 186 224 246 248 255 305
                945 961 962 971 #x10428 #x1044f))
       (alphabetic-without-case '(#x5d0 #x627 #x4e00))
       (outside '(64 91 96 123 169 171 185 187 215 885 894 930
                  #x378 #x1f642)))
  (list
   (codes-satisfy? char-upper-case? upper)
   (codes-satisfy? char-lower-case? lower)
   (codes-satisfy? char-alphabetic?
                   (append upper lower alphabetic-without-case))
   (all? (lambda (code)
           (let ((character (integer->char code)))
             (and (not (char-upper-case? character))
                  (not (char-lower-case? character))
                  (not (char-alphabetic? character)))))
         outside)))
