;;; Portable source for Consent-owned R7RS `(scheme char)' semantics.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Unicode classification and mapping use the pinned, generated tables in
;;; `(consent unicode-data)'.  Characters outside those versioned properties
;;; remain valid Unicode scalar values: classification returns false and case
;;; conversion returns the input.

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
  (import (scheme base)
          (consent unicode-data))
  (begin
    (define (simple-character-map mapper character lower upper offset)
      "Return CHARACTER's ASCII or generated simple mapping."
      (let ((code (char->integer character)))
        (cond
         ((< code lower) character)
         ((<= code upper) (integer->char (+ code offset)))
         ((< code #x80) character)
         (else (integer->char (mapper code))))))

    (define (char-upper-case? character)
      "Report whether CHARACTER has the owned Unicode Uppercase property."
      #((parameters
         (character (type character) (description "Character to classify.")))
        (returns (type boolean) (description
          "Whether CHARACTER is uppercase."))
        (effects pure))
      (let ((code (char->integer character)))
        (cond
         ((< code #x41) #f)
         ((<= code #x5a) #t)
         ((< code #x80) #f)
         (else (consent-unicode-uppercase? code)))))

    (define (char-lower-case? character)
      "Report whether CHARACTER has the owned Unicode Lowercase property."
      #((parameters
         (character (type character) (description "Character to classify.")))
        (returns (type boolean) (description
          "Whether CHARACTER is lowercase."))
        (effects pure))
      (let ((code (char->integer character)))
        (cond
         ((< code #x61) #f)
         ((<= code #x7a) #t)
         ((< code #x80) #f)
         (else (consent-unicode-lowercase? code)))))

    (define (char-alphabetic? character)
      "Report whether CHARACTER has the owned Unicode Alphabetic property."
      #((parameters
         (character (type character) (description "Character to classify.")))
        (returns (type boolean)
         (description "Whether CHARACTER has the Alphabetic property."))
        (effects pure))
      (let ((code (char->integer character)))
        (cond
         ((< code #x41) #f)
         ((<= code #x5a) #t)
         ((< code #x61) #f)
         ((<= code #x7a) #t)
         ((< code #x80) #f)
         (else (consent-unicode-alphabetic? code)))))

    (define (digit-value character)
      "Return CHARACTER's owned decimal digit value, or #f."
      #((parameters
         (character (type character) (description "Character to classify.")))
        (returns (type (or exact-integer boolean))
         (description "Decimal value from zero through nine, or #f."))
        (effects pure))
      (let ((code (char->integer character)))
        (cond
         ((< code #x30) #f)
         ((<= code #x39) (- code #x30))
         ((< code #x80) #f)
         (else (consent-unicode-decimal-value code)))))

    (define (char-numeric? character)
      "Report whether CHARACTER has Numeric_Type=Decimal in this profile."
      #((parameters
         (character (type character) (description "Character to classify.")))
        (returns (type boolean)
         (description "Whether CHARACTER is an owned decimal digit."))
        (effects pure))
      (if (digit-value character) #t #f))

    (define (char-whitespace? character)
      "Report whether CHARACTER has the Unicode White_Space property."
      #((parameters
         (character (type character) (description "Character to classify.")))
        (returns (type boolean) (description
          "Whether CHARACTER is whitespace."))
        (effects pure))
      (let ((code (char->integer character)))
        (cond
         ((< code #x09) #f)
         ((<= code #x0d) #t)
         ((< code #x20) #f)
         ((= code #x20) #t)
         ((< code #x80) #f)
         (else (consent-unicode-whitespace? code)))))

    (define (char-upcase character)
      "Return CHARACTER's owned simple uppercase mapping."
      #((parameters
         (character (type character) (description "Character to map.")))
        (returns (type character) (description "Simple uppercase character."))
        (effects pure))
      (simple-character-map consent-unicode-simple-uppercase
                            character #x61 #x7a -32))

    (define (char-downcase character)
      "Return CHARACTER's owned simple lowercase mapping."
      #((parameters
         (character (type character) (description "Character to map.")))
        (returns (type character) (description "Simple lowercase character."))
        (effects pure))
      (simple-character-map consent-unicode-simple-lowercase
                            character #x41 #x5a 32))

    (define (char-foldcase character)
      "Return CHARACTER's owned Unicode simple case-folding mapping."
      #((parameters
         (character (type character) (description "Character to fold.")))
        (returns (type character) (description "Simple foldcase character."))
        (effects pure))
      (simple-character-map consent-unicode-simple-foldcase
                            character #x41 #x5a 32))

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

    (define (full-mapping-characters mapper character lower upper offset)
      "Return CHARACTER's ASCII or generated full mapping list."
      (let ((code (char->integer character)))
        (cond
         ((< code lower) (list character))
         ((<= code upper) (list (integer->char (+ code offset))))
         ((< code #x80) (list character))
         (else (map integer->char (mapper code))))))

    (define (full-upcase-characters character)
      "Return CHARACTER's generated full uppercase mapping as a list."
      (full-mapping-characters
       consent-unicode-full-uppercase character #x61 #x7a -32))

    (define (full-downcase-characters character)
      "Return CHARACTER's generated full lowercase mapping as a list."
      (full-mapping-characters
       consent-unicode-full-lowercase character #x41 #x5a 32))

    (define (full-foldcase-characters character)
      "Return CHARACTER's generated full case-fold mapping as a list."
      (full-mapping-characters
       consent-unicode-full-foldcase character #x41 #x5a 32))

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
