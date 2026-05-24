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
    ;; Return a Scheme-readable record field named NAME with VALUES.
    (define (diff-field name . values)
      (cons name values))

    ;; Return FIELD's first value from RECORD, or DEFAULT when absent.
    (define (diff-field-value record field default)
      (let ((entry (assq field (cdr record))))
        (if entry
            (if (null? (cdr entry)) default (cadr entry))
            default)))

    ;; Return TEXT split into logical lines without keeping newline
    ;; characters.
    (define (diff-string-lines text)
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

    ;; Return a guest numeric length for LINES without leaking host integers.
    (define (diff-list-length lines)
      (let loop ((rest lines) (count 0))
        (if (null? rest)
            count
            (loop (cdr rest) (+ count 1)))))

    ;; Return the number of logical lines represented by TEXT.
    (define (diff-string-line-count text)
      (diff-list-length (diff-string-lines text)))

    ;; Return one line record for a hunk. KIND is context, remove, or add.
    (define (diff-line kind text)
      (list 'line kind text))

    ;; Return one hunk record with explicit old and new ranges.
    (define (make-diff-hunk old-start old-count new-start new-count lines)
      (list 'hunk
            (diff-field 'old-start old-start)
            (diff-field 'old-count old-count)
            (diff-field 'new-start new-start)
            (diff-field 'new-count new-count)
            (diff-field 'lines lines)))

    ;; Return a canonical diff datum from SOURCE labels and HUNKS.
    (define (make-diff source old-label new-label hunks)
      (list 'diff
            (diff-field 'source source)
            (diff-field 'old-label old-label)
            (diff-field 'new-label new-label)
            (diff-field 'status (if (null? hunks) 'no-change 'changed))
            (diff-field 'hunks hunks)))

    ;; Return an explicit no-change diff for SOURCE and LABEL.
    (define (no-change-diff source label)
      (make-diff source label label '()))

    ;; Report whether DATUM is a portable diff record.
    (define (diff? datum)
      (and (pair? datum) (eq? (car datum) 'diff)))

    ;; Report whether DIFF contains at least one changed hunk.
    (define (diff-changed? diff)
      (eq? (diff-field-value diff 'status 'no-change) 'changed))

    ;; Return DIFF's source field.
    (define (diff-source diff)
      (diff-field-value diff 'source #f))

    ;; Return DIFF's hunk list.
    (define (diff-hunks diff)
      (diff-field-value diff 'hunks '()))

    ;; Return a list of removal line records from TEXT.
    (define (diff-removal-lines text)
      (map (lambda (line) (diff-line 'remove line))
           (diff-string-lines text)))

    ;; Return a list of addition line records from TEXT.
    (define (diff-addition-lines text)
      (map (lambda (line) (diff-line 'add line))
           (diff-string-lines text)))

    ;; Return a one-hunk diff for a proposed edit datum.
    (define (proposed-edit-diff edit)
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

    ;; Return STRINGS appended in order.
    (define (diff-string-append-all strings)
      (let loop ((rest strings) (result ""))
        (if (null? rest)
            result
            (loop (cdr rest) (string-append result (car rest))))))

    ;; Return the unified-diff prefix for a line KIND.
    (define (diff-line-prefix kind)
      (cond
       ((eq? kind 'context) " ")
       ((eq? kind 'remove) "-")
       ((eq? kind 'add) "+")
       (else " ")))

    ;; Render one line record to unified-diff text.
    (define (diff-render-line line)
      (string-append
       (diff-line-prefix (cadr line))
       (caddr line)
       "\n"))

    ;; Render all hunk LINE records to unified-diff text.
    (define (diff-render-lines lines)
      (diff-string-append-all (map diff-render-line lines)))

    ;; Render one hunk record to unified-diff text.
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

    ;; Render all DIFF hunks to unified-diff text.
    (define (diff-render-hunks diff)
      (diff-string-append-all (map diff-render-hunk (diff-hunks diff))))

    ;; Render DIFF to deterministic unified-diff text for humans.
    (define (diff-render-unified diff)
      (if (diff-changed? diff)
          (string-append
           "--- "
           (diff-field-value diff 'old-label "before")
           "\n+++ "
           (diff-field-value diff 'new-label "after")
           "\n"
           (diff-render-hunks diff))
          ""))

    ;; Yield DIFF through the portable Agent Scheme event channel.
    (define (diff-yield diff)
      (agent-yield diff))))
