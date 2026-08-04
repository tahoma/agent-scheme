;;; character-case-tables.scm --- Character conformance
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

(define (pairs lower upper delta)
  "Return source and mapped character-code pairs across one range."
  (map (lambda (code) (cons code (+ code delta)))
       (range lower upper)))

(define (all? predicate values)
  "Return whether PREDICATE accepts every member of VALUES."
  (or (null? values)
      (and (predicate (car values))
           (all? predicate (cdr values)))))

(define (matches? mapper mappings)
  "Return whether MAPPER implements every character-code MAPPING."
  (all?
   (lambda (pair)
     (= (char->integer (mapper (integer->char (car pair))))
        (cdr pair)))
   mappings))

(let ((up
       (append (pairs 97 122 -32)
               (pairs 224 246 -32)
               (pairs 248 254 -32)
               '((255 . 376) (181 . 924) (223 . 7838) (305 . 73))
               (pairs 945 961 -32)
               '((962 . 931))
               (pairs 963 971 -32)))
      (down
       (append (pairs 65 90 32)
               (pairs 192 214 32)
               (pairs 216 222 32)
               '((304 . 105) (376 . 255) (7838 . 223))
               (pairs 913 929 32)
               (pairs 931 939 32))))
  (list
   (matches? char-upcase up)
   (matches? char-downcase down)
   (map (lambda (code)
          (char->integer (char-foldcase (integer->char code))))
        '(962 304 7838))
   (map char->integer
        (string->list (string-upcase (string (integer->char 223)))))
   (map char->integer
        (string->list (string-downcase (string (integer->char 304)))))
   (map char->integer
        (string->list
         (string-foldcase
          (list->string (map integer->char '(223 7838 304))))))
   (map (lambda (code)
          (char->integer (char-upcase (integer->char code))))
        '(8364 128578))))
