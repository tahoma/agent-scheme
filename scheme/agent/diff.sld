;;; diff.sld --- Portable Consent Scheme diff datum library
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This host-neutral library owns canonical diff datums and unified rendering.
;;; Host adapters produce these records from live resources, but the record
;;; shape stays portable Scheme data.

(define-library (agent diff)
  (export make-diff
          make-diff-hunk
          diff-line
          no-change-diff
          proposed-edit-diff
          diff?
          diff-changed?
          diff-source
          diff-hunks
          diff-render-unified
          diff-yield)
  (import (scheme base)
          (scheme cxr)
          (prefix (stdlib generator) gen:)
          (agent io))
  (begin
    (define (diff-field name . values)
      "Return a Scheme-readable record field named NAME with VALUES."
      (cons name values))

    (define (diff-field-value record field default)
      "Return FIELD's first value from RECORD, or DEFAULT when absent."
      (let ((entry (assq field (cdr record))))
        (if entry
            (if (null? (cdr entry)) default (cadr entry))
            default)))

    (define (diff-string-line-generator text)
      "Return a generator over TEXT's logical lines without newline characters."
      (let ((characters (gen:string->generator text)))
        (gen:make-coroutine-generator
         (lambda (yield)
           (let loop ((current '()))
             (let ((char (characters)))
               (cond
                ((eof-object? char)
                 (if (not (null? current))
                     (yield (list->string (reverse current)))))
                ((char=? char #\newline)
                 (yield (list->string (reverse current)))
                 (loop '()))
                (else
                 (loop (cons char current))))))))))

    (define (diff-string-lines text)
      "Return TEXT split into logical lines without keeping newline characters."
      (gen:generator->list (diff-string-line-generator text)))

    (define (diff-string-line-count text)
      "Return the number of logical lines represented by TEXT."
      (gen:generator-count
       (lambda (line) line #t)
       (diff-string-line-generator text)))

    (define (diff-line kind text)
      "Return one line record for a hunk."
      #((parameters
         (kind (type symbol)
          (description "Line role symbol, usually context, remove, or add."))
         (text (type string)
          (description "Line text without its trailing newline.")))
        (returns (type pair)
         (description "A `(line KIND TEXT)` record suitable for a diff hunk."))
        (effects pure))
      (list 'line kind text))

    (define (make-diff-hunk old-start old-count new-start new-count lines)
      "Return one hunk record with explicit old and new ranges."
      #((parameters
         (old-start (type exact-integer)
          (description "One-based starting line in the old text."))
         (old-count (type exact-integer)
          (description "Number of old-text lines covered."))
         (new-start (type exact-integer)
          (description "One-based starting line in the new text."))
         (new-count (type exact-integer)
          (description "Number of new-text lines covered."))
         (lines (type (list-of pair))
          (description "List of line records returned by `diff-line`.")))
        (returns (type pair)
         (description
          ("A `(hunk ...)` record that can be rendered by"
            "`diff-render-unified`.")))
        (effects pure))
      (list 'hunk
            (diff-field 'old-start old-start)
            (diff-field 'old-count old-count)
            (diff-field 'new-start new-start)
            (diff-field 'new-count new-count)
            (diff-field 'lines lines)))

    (define (make-diff source old-label new-label hunks)
      "Return a canonical diff datum from SOURCE labels and HUNKS."
      #((parameters
         (source (type (or symbol string pair))
          (description ("Symbol, path, handle, or other datum naming what changed.")))
         (old-label (type string)
          (description "Display label for the original side."))
         (new-label (type string)
          (description "Display label for the proposed or current side."))
         (hunks (type (list-of pair))
          (description "List of hunk records; empty means no change.")))
        (returns (type diff)
         (description
          ("A canonical `(diff ...)` datum with status `changed` or"
            "`no-change`.")))
        (effects pure))
      (list 'diff
            (diff-field 'source source)
            (diff-field 'old-label old-label)
            (diff-field 'new-label new-label)
            (diff-field 'status (if (null? hunks) 'no-change 'changed))
            (diff-field 'hunks hunks)))

    (define (no-change-diff source label)
      "Return an explicit no-change diff for SOURCE and LABEL."
      #((parameters
         (source (type (or symbol string pair))
          (description "Datum naming the unchanged resource."))
         (label (type string)
          (description "Display label used for both old and new sides.")))
        (returns (type diff)
         (description "A canonical diff datum whose status is `no-change`."))
        (effects pure))
      (make-diff source label label '()))

    (define (diff? datum)
      "Return #t when DATUM is a portable diff record."
      #((parameters
         (datum . "Value to inspect."))
        (returns (type boolean)
         (description
          ("#t when DATUM is tagged as a canonical diff record;"
            "otherwise #f.")))
        (effects pure))
      (and (pair? datum) (eq? (car datum) 'diff)))

    (define (diff-changed? diff)
      "Return #t when DIFF contains at least one changed hunk."
      #((parameters
         (diff (type diff)
          (description "Canonical diff datum.")))
        (returns (type boolean)
         (description "#t when DIFF has changed status; otherwise #f."))
        (effects pure))
      (eq? (diff-field-value diff 'status 'no-change) 'changed))

    (define (diff-source diff)
      "Return DIFF's source field."
      #((parameters
         (diff (type diff)
          (description "Canonical diff datum.")))
        (returns (type (or symbol string pair boolean))
         (description "The source datum stored in DIFF, or #f when absent."))
        (effects pure))
      (diff-field-value diff 'source #f))

    (define (diff-hunks diff)
      "Return DIFF's hunk list."
      #((parameters
         (diff (type diff)
          (description "Canonical diff datum.")))
        (returns (type list)
         (description "The list of hunk records in DIFF, or the empty list."))
        (effects pure))
      (diff-field-value diff 'hunks '()))

    (define (diff-removal-lines text)
      "Return a list of removal line records from TEXT."
      (map (lambda (line) (diff-line 'remove line))
           (diff-string-lines text)))

    (define (diff-addition-lines text)
      "Return a list of addition line records from TEXT."
      (map (lambda (line) (diff-line 'add line))
           (diff-string-lines text)))

    (define (proposed-edit-diff edit)
      "Return a one-hunk diff for a proposed edit datum."
      #((parameters
         (edit (type list)
          (description
           ("Association-list or record-like edit datum with source,"
             "labels, start, before, and after fields."))))
        (returns (type diff)
         (description "A canonical diff datum describing the proposed edit."))
        (effects pure))
      (let ((source (diff-field-value edit 'source 'proposed-edit))
            (old-label (diff-field-value edit 'old-label "before"))
            (new-label (diff-field-value edit 'new-label "after"))
            (start (diff-field-value edit 'start 1))
            (before (diff-field-value edit 'before ""))
            (after (diff-field-value edit 'after "")))
        (if (string=? before after)
            (no-change-diff source old-label)
            (make-diff
             source
             old-label
             new-label
             (list
              (make-diff-hunk
               start
               (diff-string-line-count before)
               start
               (diff-string-line-count after)
               (append (diff-removal-lines before)
                       (diff-addition-lines after))))))))

    (define (diff-string-append-all strings)
      "Return STRINGS appended in order."
      (let loop ((rest strings) (result ""))
        (if (null? rest)
            result
            (loop (cdr rest) (string-append result (car rest))))))

    (define (diff-line-prefix kind)
      "Return the unified-diff prefix for a line KIND."
      (cond
       ((eq? kind 'context) " ")
       ((eq? kind 'remove) "-")
       ((eq? kind 'add) "+")
       (else " ")))

    (define (diff-render-line line)
      "Render one line record to unified-diff text."
      (string-append
       (diff-line-prefix (cadr line))
       (caddr line)
       "\n"))

    (define (diff-render-lines lines)
      "Render all hunk LINE records to unified-diff text."
      (diff-string-append-all (map diff-render-line lines)))

    (define (diff-render-hunk hunk)
      (string-append
       "@@ -"
       (number->string (diff-field-value hunk 'old-start 1))
       ","
       (number->string (diff-field-value hunk 'old-count 0))
       " +"
       (number->string (diff-field-value hunk 'new-start 1))
       ","
       (number->string (diff-field-value hunk 'new-count 0))
       " @@\n"
       (diff-render-lines (diff-field-value hunk 'lines '()))))

    (define (diff-render-hunks diff)
      "Render all DIFF hunks to unified-diff text."
      (diff-string-append-all (map diff-render-hunk (diff-hunks diff))))

    (define (diff-render-unified diff)
      "Render DIFF to deterministic unified-diff text for humans."
      #((parameters
         (diff (type diff)
          (description "Canonical diff datum.")))
        (returns (type string)
         (description
          ("Unified-diff text, or the empty string when DIFF has no"
            "changes.")))
	        (effects pure)
	        (examples
	         ((source . "(diff-render-unified (no-change-diff 'buffer \"same\"))")
	          (result . ""))))
      (if (diff-changed? diff)
          (string-append
           "--- "
           (diff-field-value diff 'old-label "before")
           "\n+++ "
           (diff-field-value diff 'new-label "after")
           "\n"
           (diff-render-hunks diff))
          ""))

    (define (diff-yield diff)
      "Yield DIFF through the portable Consent Scheme event channel."
      #((parameters
         (diff (type diff)
          (description "Canonical diff datum to publish as an agent event.")))
        (returns . "The host-specific result of `agent-yield`.")
        (effects agent-yield)
        (see-also diff-render-unified))
      (agent-yield diff))))
