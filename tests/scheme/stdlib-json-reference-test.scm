;;; Portable SRFI 180 reference-corpus tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme file)
        (scheme write)
        (stdlib generator)
        (stdlib json)
        (stdlib testing))

;; Repository-relative root for the vendored SRFI 180 fixture files.
(define fixture-root "fixtures/srfi-180/files/")

;; This inventory is deliberately explicit: R7RS-small has no portable
;; directory enumeration API, and a checked-in list makes corpus membership
;; reviewable without moving discovery back into the ERT bridge.
(define valid-fixtures
  '("y_array_arraysWithSpaces.json" "y_array_empty-string.json"
    "y_array_empty.json" "y_array_ending_with_newline.json"
    "y_array_false.json" "y_array_heterogeneous.json" "y_array_null.json"
    "y_array_with_1_and_newline.json" "y_array_with_leading_space.json"
    "y_array_with_several_null.json" "y_array_with_trailing_space.json"
    "y_foundationdb_status.json" "y_number.json" "y_number_0e+1.json"
    "y_number_0e1.json" "y_number_after_space.json"
    "y_number_double_close_to_zero.json" "y_number_int_with_exp.json"
    "y_number_minus_zero.json" "y_number_negative_int.json"
    "y_number_negative_one.json" "y_number_negative_zero.json"
    "y_number_real_capital_e.json" "y_number_real_capital_e_neg_exp.json"
    "y_number_real_capital_e_pos_exp.json" "y_number_real_exponent.json"
    "y_number_real_fraction_exponent.json" "y_number_real_neg_exp.json"
    "y_number_real_pos_exponent.json" "y_number_simple_int.json"
    "y_number_simple_real.json" "y_object.json" "y_object_basic.json"
    "y_object_duplicated_key.json" "y_object_duplicated_key_and_value.json"
    "y_object_empty.json" "y_object_empty_key.json"
    "y_object_escaped_null_in_key.json" "y_object_extreme_numbers.json"
    "y_object_long_strings.json" "y_object_nested.json"
    "y_object_simple.json" "y_object_string_unicode.json"
    "y_object_with_newlines.json" "y_string_1_2_3_bytes_UTF-8_sequences.json"
    "y_string_accepted_surrogate_pair.json"
    "y_string_accepted_surrogate_pairs.json" "y_string_allowed_escapes.json"
    "y_string_backslash_and_u_escaped_zero.json"
    "y_string_backslash_doublequotes.json" "y_string_comments.json"
    "y_string_double_escape_a.json" "y_string_double_escape_n.json"
    "y_string_escaped_control_character.json"
    "y_string_escaped_noncharacter.json" "y_string_in_array.json"
    "y_string_in_array_with_leading_space.json"
    "y_string_last_surrogates_1_and_2.json" "y_string_nbsp_uescaped.json"
    "y_string_nonCharacterInUTF-8_U+10FFFF.json"
    "y_string_nonCharacterInUTF-8_U+FFFF.json" "y_string_null_escape.json"
    "y_string_one-byte-utf-8.json" "y_string_pi.json"
    "y_string_reservedCharacterInUTF-8_U+1BFFF.json"
    "y_string_simple_ascii.json" "y_string_space.json"
    "y_string_surrogates_U+1D11E_MUSICAL_SYMBOL_G_CLEF.json"
    "y_string_three-byte-utf-8.json" "y_string_two-byte-utf-8.json"
    "y_string_u+2028_line_sep.json" "y_string_u+2029_par_sep.json"
    "y_string_uEscape.json" "y_string_uescaped_newline.json"
    "y_string_unescaped_char_delete.json" "y_string_unicode.json"
    "y_string_unicodeEscapedBackslash.json" "y_string_unicode_2.json"
    "y_string_unicode_U+10FFFE_nonchar.json"
    "y_string_unicode_U+1FFFE_nonchar.json"
    "y_string_unicode_U+200B_ZERO_WIDTH_SPACE.json"
    "y_string_unicode_U+2064_invisible_plus.json"
    "y_string_unicode_U+FDD0_nonchar.json"
    "y_string_unicode_U+FFFE_nonchar.json"
    "y_string_unicode_escaped_double_quote.json" "y_string_utf8.json"
    "y_string_with_del_character.json" "y_structure_lonely_false.json"
    "y_structure_lonely_int.json" "y_structure_lonely_negative_real.json"
    "y_structure_lonely_null.json" "y_structure_lonely_string.json"
    "y_structure_lonely_true.json" "y_structure_string_empty.json"
    "y_structure_trailing_newline.json" "y_structure_true_in_array.json"
    "y_structure_whitespace_array.json"))

(define (fixture-path name)
  "Return the repository-relative fixture path for NAME."
  (string-append fixture-root name))

(define (valid-json? name)
  "Return true when fixture NAME parses as one JSON text."
  (guard (condition (else #f))
    (call-with-input-file (fixture-path name)
      (lambda (port) (json-read port)))
    #t))

(define (last-item items)
  "Return the final item in non-empty ITEMS."
  (if (null? (cdr items))
      (car items)
      (last-item (cdr items))))

;; Null runner inspected below so every fixture runs before failure is raised.
(define runner (test-runner-null))
(test-with-runner runner
  (test-begin "SRFI 180 valid reference corpus" (length valid-fixtures))
  (for-each
   (lambda (name)
     (test-assert name (valid-json? name)))
   valid-fixtures)
  (test-end "SRFI 180 valid reference corpus"))

(test-with-runner runner
  (test-begin "SRFI 180 streaming reference corpus" 5)
  (for-each
   (lambda (name)
     (test-equal
      name
      '(2 1 2)
      (call-with-input-file
       (fixture-path name)
       (lambda (port)
         (let ((items (generator->list (json-lines-read port))))
           (list (length items)
                 (cdr (assq 'a (car items)))
                 (cdr (assq 'b (cadr items)))))))))
   '("sample-crlf-line-separators.jsonl"
     "sample-no-eol-at-eof.jsonl"
     "sample.jsonl"))
  (test-equal
   "json-sequence.log"
   '(10 0 9)
   (call-with-input-file
    (fixture-path "json-sequence.log")
    (lambda (port)
      (let ((items (generator->list (json-sequence-read port))))
        (list (length items)
              (cdr (assq 'count (car items)))
              (cdr (assq 'count (last-item items))))))))
  (test-assert
   "json-sequence-with-one-broken-json.log"
   (guard (condition ((json-error? condition) #t) (else #f))
     (call-with-input-file
      (fixture-path "json-sequence-with-one-broken-json.log")
      (lambda (port)
        (generator->list (json-sequence-read port))))
     #f))
  (test-end "SRFI 180 streaming reference corpus"))

(if (= (test-runner-fail-count runner) 0)
    (begin
      (display "SRFI 180 portable reference corpus passed")
      (newline))
    (error "SRFI 180 portable reference corpus failed"
           (test-runner-fail-count runner)))
