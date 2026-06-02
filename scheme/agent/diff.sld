;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;
;;; diff.sld --- Portable Agent Scheme diff datum library
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

    (define (diff-string-lines text)
      "Return TEXT split into logical lines without keeping newline characters."
      (let loop ((chars (string->list text))
                 (current '())
                 (lines '()))
        (cond
         ((null? chars)
          (reverse
           (if (null? current)
               lines
               (cons (list->string (reverse current)) lines))))
         ((char=? (car chars) #\newline)
          (loop (cdr chars)
                '()
                (cons (list->string (reverse current)) lines)))
         (else
          (loop (cdr chars)
                (cons (car chars) current)
                lines)))))

    (define (diff-list-length lines)
      "Return a guest numeric length for LINES without leaking host integers."
      (let loop ((rest lines) (count 0))
        (if (null? rest)
            count
            (loop (cdr rest) (+ count 1)))))

    (define (diff-string-line-count text)
      "Return the number of logical lines represented by TEXT."
      (diff-list-length (diff-string-lines text)))

    (define (diff-line kind text)
      "Return one line record for a hunk."
      #((parameters . ((kind . "Line role symbol, usually context, remove, or add.")
                       (text . "Line text without its trailing newline.")))
        (returns . "A `(line KIND TEXT)` record suitable for a diff hunk.")
        (effects . (pure)))
      (list 'line kind text))

    (define (make-diff-hunk old-start old-count new-start new-count lines)
      "Return one hunk record with explicit old and new ranges."
      #((parameters . ((old-start . "One-based starting line in the old text.")
                       (old-count . "Number of old-text lines covered.")
                       (new-start . "One-based starting line in the new text.")
                       (new-count . "Number of new-text lines covered.")
                       (lines . "List of line records returned by `diff-line`.")))
        (returns . "A `(hunk ...)` record that can be rendered by `diff-render-unified`.")
        (effects . (pure)))
      (list 'hunk
            (diff-field 'old-start old-start)
            (diff-field 'old-count old-count)
            (diff-field 'new-start new-start)
            (diff-field 'new-count new-count)
            (diff-field 'lines lines)))

    (define (make-diff source old-label new-label hunks)
      "Return a canonical diff datum from SOURCE labels and HUNKS."
      #((parameters . ((source . "Symbol, path, handle, or other datum naming what changed.")
                       (old-label . "Display label for the original side.")
                       (new-label . "Display label for the proposed or current side.")
                       (hunks . "List of hunk records; empty means no change.")))
        (returns . "A canonical `(diff ...)` datum with status `changed` or `no-change`.")
        (effects . (pure)))
      (list 'diff
            (diff-field 'source source)
            (diff-field 'old-label old-label)
            (diff-field 'new-label new-label)
            (diff-field 'status (if (null? hunks) 'no-change 'changed))
            (diff-field 'hunks hunks)))

    (define (no-change-diff source label)
      "Return an explicit no-change diff for SOURCE and LABEL."
      #((parameters . ((source . "Datum naming the unchanged resource.")
                       (label . "Display label used for both old and new sides.")))
        (returns . "A canonical diff datum whose status is `no-change`.")
        (effects . (pure)))
      (make-diff source label label '()))

    (define (diff? datum)
      "Return #t when DATUM is a portable diff record."
      #((parameters . ((datum . "Value to inspect.")))
        (returns . "#t when DATUM is tagged as a canonical diff record; otherwise #f.")
        (effects . (pure)))
      (and (pair? datum) (eq? (car datum) 'diff)))

    (define (diff-changed? diff)
      "Return #t when DIFF contains at least one changed hunk."
      #((parameters . ((diff . "Canonical diff datum.")))
        (returns . "#t when DIFF has changed status; otherwise #f.")
        (effects . (pure)))
      (eq? (diff-field-value diff 'status 'no-change) 'changed))

    (define (diff-source diff)
      "Return DIFF's source field."
      #((parameters . ((diff . "Canonical diff datum.")))
        (returns . "The source datum stored in DIFF, or #f when absent.")
        (effects . (pure)))
      (diff-field-value diff 'source #f))

    (define (diff-hunks diff)
      "Return DIFF's hunk list."
      #((parameters . ((diff . "Canonical diff datum.")))
        (returns . "The list of hunk records in DIFF, or the empty list.")
        (effects . (pure)))
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
      #((parameters . ((edit . "Association-list or record-like edit datum with source, labels, start, before, and after fields.")))
        (returns . "A canonical diff datum describing the proposed edit.")
        (effects . (pure)))
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
      #((parameters . ((diff . "Canonical diff datum.")))
        (returns . "Unified-diff text, or the empty string when DIFF has no changes.")
        (effects . (pure))
        (examples . (((source . "(diff-render-unified (no-change-diff 'buffer \"same\"))")
                      (result . "")))))
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
      "Yield DIFF through the portable Agent Scheme event channel."
      #((parameters . ((diff . "Canonical diff datum to publish as an agent event.")))
        (returns . "The host-specific result of `agent-yield`.")
        (effects . (agent-yield))
        (see-also . (diff-render-unified)))
      (agent-yield diff))))
