;;; Portable source for the derived R7RS `(scheme char)' comparisons.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Unicode character classification and case mapping remain host primitives.
;;; The case-insensitive comparison procedures are pure derivations over those
;;; foldcase primitives plus `(scheme base)' character and string comparison.

(define-library (scheme char)
  (export char-ci<=? char-ci<? char-ci=? char-ci>=? char-ci>?
          string-ci<=? string-ci<? string-ci=? string-ci>=? string-ci>?)
  (import (scheme base)
          (rename
           (only (scheme char primitive) char-foldcase string-foldcase)
           (char-foldcase primitive-char-foldcase)
           (string-foldcase primitive-string-foldcase)))
  (begin
    (define (folded-char-compare predicate first second rest)
      "Compare FIRST, SECOND, and REST after Unicode character foldcase."
      (let loop ((left (primitive-char-foldcase first))
                 (right (primitive-char-foldcase second))
                 (tail rest))
        (and (predicate left right)
             (or (null? tail)
                 (loop right
                       (primitive-char-foldcase (car tail))
                       (cdr tail))))))

    (define (char-ci=? first second . rest)
      "Report whether FIRST, SECOND, and REST are character-ci equal."
      #((parameters
         (first (type character)
          (description "First character to compare."))
         (second (type character)
          (description "Second character to compare."))
         (rest (type list)
          (description "Additional characters to compare.")))
        (returns (type boolean)
         (description "True when the foldcased characters are equal."))
        (effects pure))
      (folded-char-compare char=? first second rest))

    (define (char-ci<? first second . rest)
      "Report whether FIRST, SECOND, and REST are character-ci increasing."
      #((parameters
         (first (type character)
          (description "First character to compare."))
         (second (type character)
          (description "Second character to compare."))
         (rest (type list)
          (description "Additional characters to compare.")))
        (returns (type boolean)
         (description "True when the foldcased characters are increasing."))
        (effects pure))
      (folded-char-compare char<? first second rest))

    (define (char-ci>? first second . rest)
      "Report whether FIRST, SECOND, and REST are character-ci decreasing."
      #((parameters
         (first (type character)
          (description "First character to compare."))
         (second (type character)
          (description "Second character to compare."))
         (rest (type list)
          (description "Additional characters to compare.")))
        (returns (type boolean)
         (description "True when the foldcased characters are decreasing."))
        (effects pure))
      (folded-char-compare char>? first second rest))

    (define (char-ci<=? first second . rest)
      "Report whether FIRST, SECOND, and REST are character-ci nondecreasing."
      #((parameters
         (first (type character)
          (description "First character to compare."))
         (second (type character)
          (description "Second character to compare."))
         (rest (type list)
          (description "Additional characters to compare.")))
        (returns (type boolean)
         (description
          "True when the foldcased characters are nondecreasing."))
        (effects pure))
      (folded-char-compare char<=? first second rest))

    (define (char-ci>=? first second . rest)
      "Report whether FIRST, SECOND, and REST are character-ci nonincreasing."
      #((parameters
         (first (type character)
          (description "First character to compare."))
         (second (type character)
          (description "Second character to compare."))
         (rest (type list)
          (description "Additional characters to compare.")))
        (returns (type boolean)
         (description
          "True when the foldcased characters are nonincreasing."))
        (effects pure))
      (folded-char-compare char>=? first second rest))

    (define (folded-string-compare predicate first second rest)
      "Compare FIRST, SECOND, and REST after Unicode string foldcase."
      (let loop ((left (primitive-string-foldcase first))
                 (right (primitive-string-foldcase second))
                 (tail rest))
        (and (predicate left right)
             (or (null? tail)
                 (loop right
                       (primitive-string-foldcase (car tail))
                       (cdr tail))))))

    (define (string-ci=? first second . rest)
      "Report whether FIRST, SECOND, and REST are string-ci equal."
      #((parameters
         (first (type string)
          (description "First string to compare."))
         (second (type string)
          (description "Second string to compare."))
         (rest (type list)
          (description "Additional strings to compare.")))
        (returns (type boolean)
         (description "True when the foldcased strings are equal."))
        (effects pure))
      (folded-string-compare string=? first second rest))

    (define (string-ci<? first second . rest)
      "Report whether FIRST, SECOND, and REST are string-ci increasing."
      #((parameters
         (first (type string)
          (description "First string to compare."))
         (second (type string)
          (description "Second string to compare."))
         (rest (type list)
          (description "Additional strings to compare.")))
        (returns (type boolean)
         (description "True when the foldcased strings are increasing."))
        (effects pure))
      (folded-string-compare string<? first second rest))

    (define (string-ci>? first second . rest)
      "Report whether FIRST, SECOND, and REST are string-ci decreasing."
      #((parameters
         (first (type string)
          (description "First string to compare."))
         (second (type string)
          (description "Second string to compare."))
         (rest (type list)
          (description "Additional strings to compare.")))
        (returns (type boolean)
         (description "True when the foldcased strings are decreasing."))
        (effects pure))
      (folded-string-compare string>? first second rest))

    (define (string-ci<=? first second . rest)
      "Report whether FIRST, SECOND, and REST are string-ci nondecreasing."
      #((parameters
         (first (type string)
          (description "First string to compare."))
         (second (type string)
          (description "Second string to compare."))
         (rest (type list)
          (description "Additional strings to compare.")))
        (returns (type boolean)
         (description
          "True when the foldcased strings are nondecreasing."))
        (effects pure))
      (folded-string-compare string<=? first second rest))

    (define (string-ci>=? first second . rest)
      "Report whether FIRST, SECOND, and REST are string-ci nonincreasing."
      #((parameters
         (first (type string)
          (description "First string to compare."))
         (second (type string)
          (description "Second string to compare."))
         (rest (type list)
          (description "Additional strings to compare.")))
        (returns (type boolean)
         (description
          "True when the foldcased strings are nonincreasing."))
        (effects pure))
      (folded-string-compare string>=? first second rest))))
