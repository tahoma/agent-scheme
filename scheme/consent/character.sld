;;; Portable owned character values and host-character adapter conversions.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Consent Scheme character identity is the Unicode scalar value stored in an
;;; owned record.  Host characters are used only at source-text and host-string
;;; adapter boundaries; they are not user-visible runtime character values.

(define-library (consent character)
  (export consent-character?
          consent-character-code
          consent-character-equivalent?
          consent-scalar-value?
          consent-make-character
          consent-host-character->character
          consent-character->host-character)
  (import (scheme base))
  (begin
    ;; Owned character datum containing exactly one Unicode scalar value.
    (define-record-type <consent-character>
      (make-consent-character-record code)
      consent-character?
      (code raw-consent-character-code))

    (define (consent-scalar-value? value)
      "Return #t when VALUE is a Unicode scalar value."
      #((parameters
         (value (type any) (description "Candidate scalar value.")))
        (returns (type boolean)
         (description "Whether VALUE is in the Unicode scalar range."))
        (effects pure))
      (and (integer? value)
           (exact? value)
           (<= 0 value)
           (<= value #x10ffff)
           (not (<= #xd800 value #xdfff))))

    (define (consent-make-character code)
      "Return an owned character for Unicode scalar CODE."
      #((parameters
         (code (type exact-integer) (description "Unicode scalar value.")))
        (returns (type consent-character)
         (description "Owned character containing CODE."))
        (effects allocation error))
      (if (not (consent-scalar-value? code))
          (error "consent-make-character: expected Unicode scalar value" code))
      (make-consent-character-record code))

    (define (consent-character-code character)
      "Return owned CHARACTER's Unicode scalar value."
      #((parameters
         (character (type consent-character)
          (description "Owned character to inspect.")))
        (returns (type exact-integer)
         (description "Unicode scalar value."))
        (effects error))
      (if (not (consent-character? character))
          (error "consent-character-code: expected owned character" character))
      (raw-consent-character-code character))

    (define (consent-character-equivalent? left right)
      "Return #t when LEFT and RIGHT are owned characters with equal scalars."
      #((parameters
         (left (type any) (description "First candidate value."))
         (right (type any) (description "Second candidate value.")))
        (returns (type boolean)
         (description "Whether both values are the same character."))
        (effects pure))
      (and (consent-character? left)
           (consent-character? right)
           (= (raw-consent-character-code left)
              (raw-consent-character-code right))))

    (define (consent-host-character->character character)
      "Convert a host CHARACTER to an owned Consent Scheme character."
      #((parameters
         (character (type character)
          (description "Host character at a source or string boundary.")))
        (returns (type consent-character)
         (description "Owned character with the same Unicode scalar."))
        (effects allocation error))
      (if (not (char? character))
          (error "consent-host-character->character: expected host character"
                 character))
      (consent-make-character (char->integer character)))

    (define (consent-character->host-character character)
      "Convert owned CHARACTER at a source-text or host-string boundary."
      #((parameters
         (character (type consent-character)
          (description "Owned character to adapt.")))
        (returns (type character)
         (description "Host character with the same Unicode scalar."))
        (effects error))
      (integer->char (consent-character-code character)))))
