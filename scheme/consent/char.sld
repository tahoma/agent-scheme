;;; Portable source for Consent-owned R7RS `(scheme char)' semantics.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This bootstrap profile owns ASCII, Latin-1 casing letters, representative
;;; Greek casing, selected decimal digit blocks, and the Unicode White_Space
;;; property directly in portable Scheme.  Characters outside those tables
;;; remain valid Unicode scalar values: classification returns false and case
;;; conversion returns the input.  Issue #727 expands the same boundary with
;;; generated, versioned Unicode data.

(define-library (scheme char)
  (export char-alphabetic?
          char-ci<=?
          char-ci<?
          char-ci=?
          char-ci>=?
          char-ci>?
          char-downcase
          char-foldcase
          char-lower-case?
          char-numeric?
          char-upcase
          char-upper-case?
          char-whitespace?
          digit-value
          string-ci<=?
          string-ci<?
          string-ci=?
          string-ci>=?
          string-ci>?
          string-downcase
          string-foldcase
          string-upcase)
  (import (scheme base))
  (begin
    (define (code-in-range? code lower upper)
      "Return #t when CODE lies in the inclusive LOWER..UPPER range."
      (and (<= lower code) (<= code upper)))

    (define (code-in-either-range? code first-low first-high second-low second-high)
      "Return #t when CODE lies in either supplied inclusive range."
      (or (code-in-range? code first-low first-high)
          (code-in-range? code second-low second-high)))

    (define (ascii-upper-code? code)
      "Return #t when CODE is an ASCII uppercase letter."
      (code-in-range? code #x41 #x5a))

    (define (ascii-lower-code? code)
      "Return #t when CODE is an ASCII lowercase letter."
      (code-in-range? code #x61 #x7a))

    (define (latin-upper-code? code)
      "Return #t when CODE is an owned-profile Latin uppercase letter."
      (or (code-in-either-range? code #xc0 #xd6 #xd8 #xde)
          (= code #x130)
          (= code #x178)
          (= code #x1e9e)))

    (define (latin-lower-code? code)
      "Return #t when CODE is an owned-profile Latin lowercase letter."
      (or (code-in-either-range? code #xe0 #xf6 #xf8 #xff)
          (= code #xaa)
          (= code #xb5)
          (= code #xba)
          (= code #x131)))

    (define (greek-upper-code? code)
      "Return #t when CODE is an owned-profile Greek uppercase letter."
      (code-in-either-range? code #x391 #x3a1 #x3a3 #x3ab))

    (define (greek-lower-code? code)
      "Return #t when CODE is an owned-profile Greek lowercase letter."
      (code-in-either-range? code #x3b1 #x3c1 #x3c2 #x3cb))

    (define (char-upper-case? character)
      "Report whether CHARACTER has the owned Unicode Uppercase property."
      #((parameters
         (character (type character) (description "Character to classify.")))
        (returns (type boolean) (description "Whether CHARACTER is uppercase."))
        (effects pure))
      (let ((code (char->integer character)))
        (or (ascii-upper-code? code)
            (latin-upper-code? code)
            (greek-upper-code? code))))

    (define (char-lower-case? character)
      "Report whether CHARACTER has the owned Unicode Lowercase property."
      #((parameters
         (character (type character) (description "Character to classify.")))
        (returns (type boolean) (description "Whether CHARACTER is lowercase."))
        (effects pure))
      (let ((code (char->integer character)))
        (or (ascii-lower-code? code)
            (latin-lower-code? code)
            (greek-lower-code? code))))

    (define (char-alphabetic? character)
      "Report whether CHARACTER has the owned Unicode Alphabetic property."
      #((parameters
         (character (type character) (description "Character to classify.")))
        (returns (type boolean)
         (description "Whether CHARACTER is alphabetic in this profile."))
        (effects pure))
      (or (char-upper-case? character)
          (char-lower-case? character)))

    ;; Unicode decimal-zero scalars included by the bootstrap profile.
    (define decimal-zero-codes
      '(#x30 #x660 #x6f0 #x966 #x9e6 #xa66 #xae6))

    (define (digit-value character)
      "Return CHARACTER's owned decimal digit value, or #f."
      #((parameters
         (character (type character) (description "Character to classify.")))
        (returns (type (or exact-integer boolean))
         (description "Decimal value from zero through nine, or #f."))
        (effects pure))
      (let ((code (char->integer character)))
        (let loop ((zeros decimal-zero-codes))
          (cond
           ((null? zeros) #f)
           ((code-in-range? code (car zeros) (+ (car zeros) 9))
            (- code (car zeros)))
           (else (loop (cdr zeros)))))))

    (define (char-numeric? character)
      "Report whether CHARACTER has Numeric_Type=Decimal in this profile."
      #((parameters
         (character (type character) (description "Character to classify.")))
        (returns (type boolean)
         (description "Whether CHARACTER is an owned decimal digit."))
        (effects pure))
      (if (digit-value character) #t #f))

    ;; Unicode White_Space scalars are small and stable enough to own directly.
    (define whitespace-codes
      '(#x9 #xa #xb #xc #xd #x20 #x85 #xa0 #x1680
        #x2000 #x2001 #x2002 #x2003 #x2004 #x2005 #x2006 #x2007
        #x2008 #x2009 #x200a #x2028 #x2029 #x202f #x205f #x3000))

    (define (char-whitespace? character)
      "Report whether CHARACTER has the Unicode White_Space property."
      #((parameters
         (character (type character) (description "Character to classify.")))
        (returns (type boolean) (description "Whether CHARACTER is whitespace."))
        (effects pure))
      (if (memv (char->integer character) whitespace-codes) #t #f))

    (define (char-upcase character)
      "Return CHARACTER's owned simple uppercase mapping."
      #((parameters
         (character (type character) (description "Character to map.")))
        (returns (type character) (description "Simple uppercase character."))
        (effects pure))
      (let ((code (char->integer character)))
        (integer->char
         (cond
          ((ascii-lower-code? code) (- code #x20))
          ((code-in-either-range? code #xe0 #xf6 #xf8 #xfe)
           (- code #x20))
          ((= code #xff) #x178)
          ((= code #xb5) #x39c)
          ((= code #xdf) #x1e9e)
          ((= code #x131) #x49)
          ((code-in-range? code #x3b1 #x3c1) (- code #x20))
          ((= code #x3c2) #x3a3)
          ((code-in-range? code #x3c3 #x3cb) (- code #x20))
          (else code)))))

    (define (char-downcase character)
      "Return CHARACTER's owned simple lowercase mapping."
      #((parameters
         (character (type character) (description "Character to map.")))
        (returns (type character) (description "Simple lowercase character."))
        (effects pure))
      (let ((code (char->integer character)))
        (integer->char
         (cond
          ((ascii-upper-code? code) (+ code #x20))
          ((code-in-either-range? code #xc0 #xd6 #xd8 #xde)
           (+ code #x20))
          ((= code #x130) #x69)
          ((= code #x178) #xff)
          ((= code #x1e9e) #xdf)
          ((code-in-range? code #x391 #x3a1) (+ code #x20))
          ((code-in-range? code #x3a3 #x3ab) (+ code #x20))
          (else code)))))

    (define (char-foldcase character)
      "Return CHARACTER's owned Unicode simple case-folding mapping."
      #((parameters
         (character (type character) (description "Character to fold.")))
        (returns (type character) (description "Simple foldcase character."))
        (effects pure))
      (let ((code (char->integer character)))
        (cond
         ((= code #x3c2) (integer->char #x3c3))
         ((= code #x130) character)
         (else (char-downcase character)))))

    (define (folded-char-compare predicate first second rest)
      "Compare FIRST, SECOND, and REST after owned character foldcase."
      (let loop ((left (char-foldcase first))
                 (right (char-foldcase second))
                 (tail rest))
        (and (predicate (char->integer left) (char->integer right))
             (or (null? tail)
                 (loop right (char-foldcase (car tail)) (cdr tail))))))

    (define (char-ci=? first second . rest)
      "Report whether FIRST, SECOND, and REST are character-ci equal."
      #((parameters
         (first (type character) (description "First character."))
         (second (type character) (description "Second character."))
         (rest (type list) (description "Additional characters.")))
        (returns (type boolean)
         (description "Whether the characters are case-insensitively equal."))
        (effects pure))
      (folded-char-compare = first second rest))

    (define (char-ci<? first second . rest)
      "Report whether FIRST, SECOND, and REST are character-ci increasing."
      #((parameters
         (first (type character) (description "First character."))
         (second (type character) (description "Second character."))
         (rest (type list) (description "Additional characters.")))
        (returns (type boolean)
         (description "Whether folded scalar values strictly increase."))
        (effects pure))
      (folded-char-compare < first second rest))

    (define (char-ci>? first second . rest)
      "Report whether FIRST, SECOND, and REST are character-ci decreasing."
      #((parameters
         (first (type character) (description "First character."))
         (second (type character) (description "Second character."))
         (rest (type list) (description "Additional characters.")))
        (returns (type boolean)
         (description "Whether folded scalar values strictly decrease."))
        (effects pure))
      (folded-char-compare > first second rest))

    (define (char-ci<=? first second . rest)
      "Report whether FIRST, SECOND, and REST are character-ci nondecreasing."
      #((parameters
         (first (type character) (description "First character."))
         (second (type character) (description "Second character."))
         (rest (type list) (description "Additional characters.")))
        (returns (type boolean)
         (description "Whether folded scalar values do not decrease."))
        (effects pure))
      (folded-char-compare <= first second rest))

    (define (char-ci>=? first second . rest)
      "Report whether FIRST, SECOND, and REST are character-ci nonincreasing."
      #((parameters
         (first (type character) (description "First character."))
         (second (type character) (description "Second character."))
         (rest (type list) (description "Additional characters.")))
        (returns (type boolean)
         (description "Whether folded scalar values do not increase."))
        (effects pure))
      (folded-char-compare >= first second rest))

    (define (full-upcase-characters character)
      "Return CHARACTER's owned full uppercase mapping as a list."
      (let ((code (char->integer character)))
        (if (= code #xdf)
            (list (integer->char #x53) (integer->char #x53))
            (list (char-upcase character)))))

    (define (full-downcase-characters character)
      "Return CHARACTER's owned full lowercase mapping as a list."
      (let ((code (char->integer character)))
        (if (= code #x130)
            (list (integer->char #x69) (integer->char #x307))
            (list (char-downcase character)))))

    (define (full-foldcase-characters character)
      "Return CHARACTER's owned full case-folding mapping as a list."
      (let ((code (char->integer character)))
        (cond
         ((or (= code #xdf) (= code #x1e9e))
          (list (integer->char #x73) (integer->char #x73)))
         ((= code #x130)
          (list (integer->char #x69) (integer->char #x307)))
         (else (list (char-foldcase character))))))

    (define (string-case-map string mapper)
      "Return STRING transformed by MAPPER's full character mappings."
      (let loop ((index 0) (characters '()))
        (if (= index (string-length string))
            (list->string (reverse characters))
            (loop (+ index 1)
                  (append (reverse (mapper (string-ref string index)))
                          characters)))))

    (define (string-upcase string)
      "Return STRING under the owned Unicode full uppercase mapping."
      #((parameters
         (string (type string) (description "String to map.")))
        (returns (type string) (description "Uppercase string."))
        (effects allocation))
      (string-case-map string full-upcase-characters))

    (define (string-downcase string)
      "Return STRING under the owned Unicode full lowercase mapping."
      #((parameters
         (string (type string) (description "String to map.")))
        (returns (type string) (description "Lowercase string."))
        (effects allocation))
      (string-case-map string full-downcase-characters))

    (define (string-foldcase string)
      "Return STRING under the owned Unicode full case-folding mapping."
      #((parameters
         (string (type string) (description "String to fold.")))
        (returns (type string) (description "Foldcased string."))
        (effects allocation))
      (string-case-map string full-foldcase-characters))

    (define (string-scalar-compare left right)
      "Return -1, 0, or 1 from scalar-lexicographic string comparison."
      (let ((left-length (string-length left))
            (right-length (string-length right)))
        (let loop ((index 0))
          (cond
           ((= index left-length)
            (cond
             ((= index right-length) 0)
             (else -1)))
           ((= index right-length) 1)
           (else
            (let ((left-code (char->integer (string-ref left index)))
                  (right-code (char->integer (string-ref right index))))
              (cond
               ((< left-code right-code) -1)
               ((> left-code right-code) 1)
               (else (loop (+ index 1))))))))))

    (define (folded-string-compare predicate first second rest)
      "Compare FIRST, SECOND, and REST after owned string foldcase."
      (let loop ((left (string-foldcase first))
                 (right (string-foldcase second))
                 (tail rest))
        (and (predicate (string-scalar-compare left right) 0)
             (or (null? tail)
                 (loop right (string-foldcase (car tail)) (cdr tail))))))

    (define (string-ci=? first second . rest)
      "Report whether FIRST, SECOND, and REST are string-ci equal."
      #((parameters
         (first (type string) (description "First string."))
         (second (type string) (description "Second string."))
         (rest (type list) (description "Additional strings.")))
        (returns (type boolean)
         (description "Whether the folded strings are equal."))
        (effects allocation))
      (folded-string-compare = first second rest))

    (define (string-ci<? first second . rest)
      "Report whether FIRST, SECOND, and REST are string-ci increasing."
      #((parameters
         (first (type string) (description "First string."))
         (second (type string) (description "Second string."))
         (rest (type list) (description "Additional strings.")))
        (returns (type boolean)
         (description "Whether folded strings strictly increase."))
        (effects allocation))
      (folded-string-compare < first second rest))

    (define (string-ci>? first second . rest)
      "Report whether FIRST, SECOND, and REST are string-ci decreasing."
      #((parameters
         (first (type string) (description "First string."))
         (second (type string) (description "Second string."))
         (rest (type list) (description "Additional strings.")))
        (returns (type boolean)
         (description "Whether folded strings strictly decrease."))
        (effects allocation))
      (folded-string-compare > first second rest))

    (define (string-ci<=? first second . rest)
      "Report whether FIRST, SECOND, and REST are string-ci nondecreasing."
      #((parameters
         (first (type string) (description "First string."))
         (second (type string) (description "Second string."))
         (rest (type list) (description "Additional strings.")))
        (returns (type boolean)
         (description "Whether folded strings do not decrease."))
        (effects allocation))
      (folded-string-compare <= first second rest))

    (define (string-ci>=? first second . rest)
      "Report whether FIRST, SECOND, and REST are string-ci nonincreasing."
      #((parameters
         (first (type string) (description "First string."))
         (second (type string) (description "Second string."))
         (rest (type list) (description "Additional strings.")))
        (returns (type boolean)
         (description "Whether folded strings do not increase."))
        (effects allocation))
      (folded-string-compare >= first second rest))))
