;;; character-case-tables.scm --- Character conformance
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

(define (matches? mapper mappings)
  "Return whether MAPPER implements every character-code MAPPING."
  (all?
   (lambda (pair)
     (= (char->integer (mapper (integer->char (car pair))))
        (cdr pair)))
   mappings))

(let ((up '((97 . 65) (122 . 90) (224 . 192) (246 . 214)
            (248 . 216) (254 . 222) (255 . 376) (181 . 924)
            (305 . 73) (945 . 913) (961 . 929) (962 . 931)
            (963 . 931) (971 . 939) (#x10428 . #x10400)
            (#x1044f . #x10427)))
      (down '((65 . 97) (90 . 122) (192 . 224) (214 . 246)
              (216 . 248) (222 . 254) (304 . 105) (376 . 255)
              (7838 . 223) (913 . 945) (929 . 961) (931 . 963)
              (939 . 971) (#x10400 . #x10428)
              (#x10427 . #x1044f))))
  (list
   (matches? char-upcase up)
   (matches? char-downcase down)
   (map (lambda (code)
          (char->integer (char-foldcase (integer->char code))))
        '(223 962 304 7838 #x10400))
   (map char->integer
        (string->list (string-upcase (string (integer->char 223)))))
   (map char->integer
        (string->list (string-downcase (string (integer->char 304)))))
   (map char->integer
        (string->list
         (string-foldcase
          (list->string (map integer->char '(223 7838 304))))))
   (map char->integer
        (string->list (string-upcase (string (integer->char #xfb03)))))
   (map char->integer
        (string->list (string-foldcase (string (integer->char #xfb03)))))
   (map char->integer
        (string->list (string-upcase (string (integer->char #x390)))))
   (map (lambda (code)
          (char->integer (char-upcase (integer->char code))))
        '(8364 128578))))
