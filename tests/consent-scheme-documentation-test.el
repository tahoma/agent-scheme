;;; consent-scheme-documentation-test.el --- Scheme documentation checks  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Enforces the portable Scheme documentation rules documented in
;; docs/development.md.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'consent-reader)

(defun consent--scheme-documentation-files ()
  "Return portable Scheme source and fixture files that carry source comments.
The white-box suites' scratch directory holds gitignored runtime
artifacts, not source, so it is excluded."
  (cl-loop for directory in '("scheme" "tests/scheme" "fixtures/r7rs")
           append
           (cl-remove-if
            (lambda (file)
              (string-match-p "/tests/scheme/scratch/" file))
            (directory-files-recursively
             (expand-file-name directory consent--test-root)
             "\\.s\\(?:cm\\|ld\\)\\'"))))

(defun consent--scheme-documentation-source-files ()
  "Return portable Scheme source files in the runtime/library tree."
  (directory-files-recursively
   (expand-file-name "scheme" consent--test-root)
   "\\.s\\(?:cm\\|ld\\)\\'"))

(defconst consent--scheme-documentation-soft-line-limit 79
  "Soft source line length for Scheme documentation metadata style.")

(defun consent--scheme-documentation-top-level-binding-p (file line)
  "Return non-nil when LINE is a top-level binding form in FILE."
  (let ((maximum-indent (if (string-suffix-p ".sld" file) 4 0)))
    (and (string-match
          "\\`\\([[:space:]]*\\)(define\\(?:-record-type\\|-syntax\\)?\\_>"
          line)
         (<= (length (match-string 1 line)) maximum-indent)
         (not (string-match "\\`[[:space:]]*(define-library\\_>" line)))))

(defun consent--scheme-documentation-top-level-procedure-p (file line)
  "Return non-nil when LINE is a top-level procedure definition in FILE."
  (let ((maximum-indent (if (string-suffix-p ".sld" file) 4 0)))
    (and (string-match "\\`\\([[:space:]]*\\)(define[[:space:]]+("
         line)
         (<= (length (match-string 1 line)) maximum-indent))))

(defun consent--scheme-documentation-procedure-definition-line-p (line)
  "Return non-nil when LINE starts a procedure definition."
  (string-match-p "\\`[[:space:]]*(define[[:space:]]+(" line))

(defun consent--scheme-documentation-comment-line-p (line)
  "Return non-nil when LINE is a Scheme source comment."
  (string-match-p "\\`[[:space:]]*;;" line))

(defun consent--scheme-documentation-string-line-p (line)
  "Return non-nil when LINE is a standalone Scheme string literal."
  (string-match-p
   "\\`[[:space:]]*\"\\(?:[^\"\\]\\|\\\\.\\)*\"[[:space:]]*\\'"
   line))

(defun consent--scheme-documentation-string-open-line-p (line)
  "Return non-nil when LINE opens a multi-line Scheme string literal.
A multi-line docstring -- common on indented internal defines and on
defines whose argument list wraps -- starts a string that the closing
quote completes on a later line, so the opening line never satisfies the
standalone-string predicate.  Crediting the opening line lets the
documentation rule recognize such docstrings the same as single-line
ones."
  (string-match-p
   "\\`[[:space:]]*\"\\(?:[^\"\\]\\|\\\\.\\)*\\'"
   line))

(defun consent--scheme-documentation-definition-end-index
    (file lines index)
  "Return index after the top-level definition at INDEX in LINES."
  (let ((cursor (1+ index)))
    (while (and (< cursor (length lines))
                (not (consent--scheme-documentation-top-level-binding-p
                      file
                      (nth cursor lines))))
      (setq cursor (1+ cursor)))
    cursor))

(defun consent--scheme-documentation-procedure-docstring-p
    (file lines index)
  "Return non-nil when top-level procedure at INDEX carries a docstring."
  (and
   (consent--scheme-documentation-top-level-procedure-p
    file
    (nth index lines))
   (let ((cursor (1+ index))
         (end (consent--scheme-documentation-definition-end-index
               file
               lines
               index))
         found)
     (while (and (not found) (< cursor end))
       (when (or (consent--scheme-documentation-string-line-p
                  (nth cursor lines))
                 (consent--scheme-documentation-string-open-line-p
                  (nth cursor lines)))
         (setq found t))
       (setq cursor (1+ cursor)))
     found)))

(defun consent--scheme-documentation-previous-content-line (lines index)
  "Return the previous nonblank line before INDEX in LINES."
  (let ((cursor (1- index))
        previous)
    (while (and (not previous) (>= cursor 0))
      (let ((line (nth cursor lines)))
        (unless (string-match-p "\\`[[:space:]]*\\'" line)
          (setq previous line)))
      (setq cursor (1- cursor)))
    previous))

(defun consent--scheme-documentation-procedure-leading-comment-errors
    (file)
  "Return errors for procedures in FILE documented only by a leading comment.
A leading ;; comment block before a procedure definition is allowed -- it can
carry section or mechanism context -- so long as the procedure still carries a
body docstring. The rule only fires when a procedure is preceded by a comment
AND has no docstring, i.e. the comment is standing in for the docstring."
  (let* ((text (with-temp-buffer
                 (insert-file-contents file)
                 (buffer-string)))
         (lines (split-string text "\n"))
         (relative-file (file-relative-name file consent--test-root))
         errors)
    (cl-loop for line in lines
             for index from 0
             when (and (> index 0)
                       (consent--scheme-documentation-procedure-definition-line-p
                        line)
                       (consent--scheme-documentation-comment-line-p
                        (nth (1- index) lines))
                       (not (consent--scheme-documentation-procedure-docstring-p
                             file lines index)))
             do
             (push (format "%s:%d document with a procedure docstring, not only a leading ;; comment before %s"
                           relative-file
                           index
                           (string-trim line))
                   errors))
    (nreverse errors)))

(defun consent--scheme-documentation-docstring-before-definition-errors
    (file)
  "Return errors for body docstrings that precede internal definitions."
  (let* ((text (with-temp-buffer
                 (insert-file-contents file)
                 (buffer-string)))
         (lines (split-string text "\n"))
         (relative-file (file-relative-name file consent--test-root))
         errors)
    (cl-loop for line in lines
             for next-line in (cdr lines)
             for index from 0
             when (and (consent--scheme-documentation-string-line-p line)
                       (consent--scheme-documentation-procedure-definition-line-p
                        next-line))
             do
             (push (format "%s:%d move procedure docstring after leading internal definitions before %s"
                           relative-file
                           (1+ index)
                           (string-trim next-line))
                   errors))
    (nreverse errors)))

(defun consent--scheme-documentation-file-errors (file)
  "Return documentation-rule errors for portable Scheme FILE."
  (let* ((text (with-temp-buffer
                 (insert-file-contents file)
                 (buffer-string)))
         (lines (split-string text "\n"))
         (relative-file (file-relative-name file consent--test-root))
         errors)
    (unless (and lines
                 (consent--scheme-documentation-comment-line-p
                  (car lines))
                 (string-prefix-p ";;;" (car lines)))
      (push (format "%s:1 missing ;;; source responsibility header"
                    relative-file)
            errors))
    (cl-loop for line in lines
             for index from 0
             when (consent--scheme-documentation-top-level-binding-p
                   file line)
             do
             (let ((previous
                    (consent--scheme-documentation-previous-content-line
                     lines index)))
               (unless (or (and previous
                                (consent--scheme-documentation-comment-line-p
                                 previous))
                           (consent--scheme-documentation-procedure-docstring-p
                            file
                            lines
                            index))
                 (push (format "%s:%d missing leading ;; comment or procedure docstring before %s"
                               relative-file
                               (1+ index)
                               (string-trim line))
                       errors))))
    (nreverse errors)))

(ert-deftest consent-scheme-documentation-test-source-comments ()
  "Ensure portable Scheme files follow the documented source-comment standard."
  (let ((errors
         (cl-loop for file in (consent--scheme-documentation-files)
                 append
                 (consent--scheme-documentation-file-errors file))))
    (when errors
      (ert-fail (mapconcat #'identity errors "\n")))))

(ert-deftest consent-scheme-documentation-test-procedure-leading-comments ()
  "Ensure Scheme procedure comments are represented as body docstrings."
  (let ((errors
         (cl-loop for file in (consent--scheme-documentation-source-files)
                  append
                  (consent--scheme-documentation-procedure-leading-comment-errors
                   file))))
    (when errors
      (ert-fail (mapconcat #'identity errors "\n")))))

(ert-deftest consent-scheme-documentation-test-body-docstrings-follow-definitions ()
  "Ensure body docstrings do not break leading internal definition blocks."
  (let ((errors
         (cl-loop for file in (consent--scheme-documentation-source-files)
                  append
                  (consent--scheme-documentation-docstring-before-definition-errors
                   file))))
    (when errors
      (ert-fail (mapconcat #'identity errors "\n")))))

(defconst consent--scheme-documentation-representative-docstrings
  '(("scheme/consent/base-prelude.scm"
     "length"
     "Return the number of pairs in LIST.")
    ("scheme/consent/lazy.sld"
     "force"
     "Return PROMISE's value, evaluating and memoizing delayed thunks once.")
    ("scheme/agent/diff.sld"
     "diff-render-unified"
     "Render DIFF to deterministic unified-diff text for humans.")
    ("scheme/agent/network.sld"
     "make-network-request"
     "Return a host-adapter request datum for one network operation.")
    ("scheme/agent/vcs.sld"
     "vcs-authorize-capability-request"
     "Return a fail-closed authorization decision for REQUEST.")
    ("scheme/agent/transcript.sld"
     "transcript-event->fixture-case"
     "Generate a shared fixture case from EVENT when replay permits it.")
    ("scheme/agent/memory.sld"
     "memory-store-put!"
     "Store DATUM under KEY in SCOPE and return its memory record.")
    ("scheme/agent/plan.sld"
     "plan-store-create!"
     "Create or replace a plan from DATUM and return its canonical record.")
    ("scheme/agent/session.sld"
     "session-store-create!"
     "Create a session in STORE for SCOPE using OPTIONS.")
    ("scheme/agent/job.sld"
     "job-store-start!"
     "Create a queued eval job in STORE for SESSION and FORM.")
    ("scheme/agent/redaction.sld"
     "redact"
     "Return DATUM with secret and local-only content redacted.")
    ("scheme/consent/result.sld"
     "ok-result-datum"
     "Build a successful evaluation-result datum for VALUE."))
  "Representative public Scheme bindings that should carry docstrings.")

(defun consent--scheme-documentation-docstring-present-p
    (relative-file name docstring)
  "Return non-nil when NAME in RELATIVE-FILE starts with DOCSTRING."
  (let ((file (expand-file-name relative-file consent--test-root))
        start
        end)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (when (re-search-forward
             (concat "^[[:space:]]*(define[[:space:]]+("
                     (regexp-quote name)
                     "\\(?:[[:space:]]\\|)\\)")
             nil
             t)
        (setq start (match-beginning 0))
        (forward-line 1)
        (while (and (not end) (not (eobp)))
          (when (consent--scheme-documentation-top-level-binding-p
                 file
                 (buffer-substring-no-properties
                  (line-beginning-position)
                  (line-end-position)))
            (setq end (line-beginning-position)))
          (unless end
            (forward-line 1)))
        (goto-char start)
        (search-forward (prin1-to-string docstring) end t)))))

(defun consent--scheme-documentation-symbol-name (value)
  "Return VALUE's Consent Scheme symbol name, or nil."
  (and (consent-symbol-p value) (consent-symbol-name value)))

(defun consent--scheme-documentation-form-head-name (form)
  "Return FORM's leading symbol name, or nil."
  (and (consp form)
       (consent--scheme-documentation-symbol-name (car form))))

(defun consent--scheme-documentation-form-head-named-p (form name)
  "Return non-nil when FORM's leading symbol is NAME."
  (string= (or (consent--scheme-documentation-form-head-name form) "")
           name))

(defun consent--scheme-documentation-export-spec-names (spec)
  "Return internal binding names exported by export SPEC."
  (cond
   ((consent-symbol-p spec)
    (list (consent-symbol-name spec)))
   ((and (consent--scheme-documentation-form-head-named-p spec "rename")
         (consp (cdr spec))
         (consent-symbol-p (cadr spec)))
    (list (consent-symbol-name (cadr spec))))
   (t nil)))

(defun consent--scheme-documentation-source-line (source offset)
  "Return the one-based line number for OFFSET in SOURCE."
  (1+ (cl-count ?\n source :end offset)))

(defun consent--scheme-documentation-delimiter-p (char)
  "Return non-nil when CHAR delimits a Scheme token."
  (or (null char)
      (memq char '(?\s ?\t ?\n ?\r ?\( ?\) ?\" ?\;))))

(defun consent--scheme-documentation-skip-string (source index limit)
  "Return the index after the string in SOURCE at INDEX before LIMIT."
  (let ((cursor (1+ index)))
    (while (and (< cursor limit)
                (not (eq (aref source cursor) ?\")))
      (setq cursor
            (if (eq (aref source cursor) ?\\)
                (min limit (+ cursor 2))
              (1+ cursor))))
    (if (< cursor limit) (1+ cursor) cursor)))

(defun consent--scheme-documentation-skip-bar-symbol (source index limit)
  "Return the index after the vertical-bar symbol at INDEX before LIMIT."
  (let ((cursor (1+ index)))
    (while (and (< cursor limit)
                (not (eq (aref source cursor) ?|)))
      (setq cursor
            (if (eq (aref source cursor) ?\\)
                (min limit (+ cursor 2))
              (1+ cursor))))
    (if (< cursor limit) (1+ cursor) cursor)))

(defun consent--scheme-documentation-skip-block-comment (source index limit)
  "Return the index after the block comment at INDEX before LIMIT."
  (let ((cursor (+ index 2))
        (depth 1))
    (while (and (> depth 0) (< cursor (1- limit)))
      (cond
       ((and (eq (aref source cursor) ?#)
             (eq (aref source (1+ cursor)) ?|))
        (setq depth (1+ depth)
              cursor (+ cursor 2)))
       ((and (eq (aref source cursor) ?|)
             (eq (aref source (1+ cursor)) ?#))
        (setq depth (1- depth)
              cursor (+ cursor 2)))
       (t
        (setq cursor (1+ cursor)))))
    cursor))

(defun consent--scheme-documentation-skip-line-comment (source index limit)
  "Return the index after the line comment at INDEX before LIMIT."
  (let ((newline (string-match "\n" source index)))
    (if (and newline (< newline limit))
        (1+ newline)
      limit)))

(defun consent--scheme-documentation-skip-space-comments
    (source index limit)
  "Return the next non-whitespace/comment index in SOURCE."
  (let ((cursor index)
        moved)
    (while
        (progn
          (setq moved nil)
          (while (and (< cursor limit)
                      (memq (aref source cursor) '(?\s ?\t ?\n ?\r)))
            (setq cursor (1+ cursor)
                  moved t))
          (cond
           ((and (< cursor limit)
                 (eq (aref source cursor) ?\;))
            (setq cursor
                  (consent--scheme-documentation-skip-line-comment
                   source cursor limit)
                  moved t))
           ((and (< (1+ cursor) limit)
                 (eq (aref source cursor) ?#)
                 (eq (aref source (1+ cursor)) ?|))
            (setq cursor
                  (consent--scheme-documentation-skip-block-comment
                   source cursor limit)
                  moved t)))
          moved))
    cursor))

(defun consent--scheme-documentation-skip-token (source index limit)
  "Return the index after the token at INDEX before LIMIT."
  (let ((cursor index))
    (while (and (< cursor limit)
                (not
                 (consent--scheme-documentation-delimiter-p
                  (aref source cursor))))
      (setq cursor (1+ cursor)))
    cursor))

(defun consent--scheme-documentation-skip-list (source index limit)
  "Return the index after the list in SOURCE at INDEX before LIMIT."
  (let ((cursor (1+ index))
        (end (1- limit)))
    (while (progn
             (setq cursor
                   (consent--scheme-documentation-skip-space-comments
                    source cursor limit))
             (and (< cursor limit)
                  (not (eq (aref source cursor) ?\)))))
      (setq cursor
            (consent--scheme-documentation-skip-datum
             source cursor limit)))
    (if (and (< cursor limit)
             (eq (aref source cursor) ?\)))
        (1+ cursor)
      (max cursor end))))

(defun consent--scheme-documentation-skip-datum (source index limit)
  "Return the index after the datum in SOURCE at INDEX before LIMIT."
  (let ((cursor
         (consent--scheme-documentation-skip-space-comments
          source index limit)))
    (if (>= cursor limit)
        cursor
      (let ((char (aref source cursor)))
        (cond
         ((eq char ?\()
          (consent--scheme-documentation-skip-list source cursor limit))
         ((eq char ?\")
          (consent--scheme-documentation-skip-string source cursor limit))
         ((eq char ?|)
          (consent--scheme-documentation-skip-bar-symbol source cursor limit))
         ((and (< (1+ cursor) limit)
               (eq char ?#)
               (eq (aref source (1+ cursor)) ?\;))
          (consent--scheme-documentation-skip-datum
           source
           (+ cursor 2)
           limit))
         ((and (< (1+ cursor) limit)
               (eq char ?#)
               (eq (aref source (1+ cursor)) ?|))
          (consent--scheme-documentation-skip-datum
           source
           (consent--scheme-documentation-skip-block-comment
            source cursor limit)
           limit))
         ((and (< (1+ cursor) limit)
               (eq char ?#)
               (eq (aref source (1+ cursor)) ?\())
          (consent--scheme-documentation-skip-list
           source (1+ cursor) limit))
         ((and (< (+ cursor 3) limit)
               (eq char ?#)
               (eq (aref source (1+ cursor)) ?u)
               (eq (aref source (+ cursor 2)) ?8)
               (eq (aref source (+ cursor 3)) ?\())
          (consent--scheme-documentation-skip-list
           source (+ cursor 3) limit))
         ((and (< (1+ cursor) limit)
               (eq char ?#)
               (eq (aref source (1+ cursor)) ?\\))
          (consent--scheme-documentation-skip-token
           source cursor limit))
         ((memq char '(?' ?` ?,))
          (consent--scheme-documentation-skip-datum
           source
           (if (and (eq char ?,)
                    (< (1+ cursor) limit)
                    (eq (aref source (1+ cursor)) ?@))
               (+ cursor 2)
             (1+ cursor))
           limit))
         (t
          (consent--scheme-documentation-skip-token
           source cursor limit)))))))

(defun consent--scheme-documentation-list-elements
    (source start end &optional count)
  "Return top-level element slices for the list SOURCE[START, END).
When COUNT is non-nil, return at most COUNT element slices."
  (let ((cursor (1+ start))
        (limit (1- end))
        elements)
    (while (progn
             (setq cursor
                   (consent--scheme-documentation-skip-space-comments
                    source cursor limit))
             (and (< cursor limit)
                  (or (null count) (< (length elements) count))))
      (let* ((element-start cursor)
             (element-end
              (consent--scheme-documentation-skip-datum
               source cursor limit)))
        (push (cons element-start element-end) elements)
        (setq cursor (max element-end (1+ cursor)))))
    (nreverse elements)))

(defun consent--scheme-documentation-slice-token (source slice)
  "Return the token represented by SLICE in SOURCE, or nil."
  (let* ((start
          (consent--scheme-documentation-skip-space-comments
           source (car slice) (cdr slice)))
         (end
          (and (< start (cdr slice))
               (not (eq (aref source start) ?\())
               (not (eq (aref source start) ?\"))
               (consent--scheme-documentation-skip-token
                source start (cdr slice)))))
    (and end (> end start) (substring source start end))))

(defun consent--scheme-documentation-list-head-name (source start end)
  "Return the head symbol name for the list SOURCE[START, END), or nil."
  (let ((elements
         (consent--scheme-documentation-list-elements source start end 1)))
    (and elements
         (consent--scheme-documentation-slice-token
          source
          (car elements)))))

(defun consent--scheme-documentation-slice-list-p (source slice)
  "Return non-nil when SLICE in SOURCE starts with a list."
  (let ((start
         (consent--scheme-documentation-skip-space-comments
          source (car slice) (cdr slice))))
    (and (< start (cdr slice))
         (eq (aref source start) ?\())))

(defun consent--scheme-documentation-slice-head-named-p
    (source slice name)
  "Return non-nil when SLICE is a list whose head is NAME."
  (and (consent--scheme-documentation-slice-list-p source slice)
       (string=
        (or (consent--scheme-documentation-list-head-name
             source (car slice) (cdr slice))
            "")
        name)))

(defun consent--scheme-documentation-define-procedure-name-from-slice
    (source slice)
  "Return the procedure name defined by DEFINE SLICE in SOURCE, or nil."
  (let ((elements
         (consent--scheme-documentation-list-elements
          source
          (car slice)
          (cdr slice)
          3)))
    (when (and (>= (length elements) 2)
               (string=
                (or (consent--scheme-documentation-slice-token
                     source (car elements))
                    "")
                "define"))
      (let ((target (nth 1 elements))
            (value (nth 2 elements)))
        (cond
         ((consent--scheme-documentation-slice-list-p source target)
          (consent--scheme-documentation-list-head-name
           source (car target) (cdr target)))
         ((and value
               (or (consent--scheme-documentation-slice-head-named-p
                    source value "lambda")
                   (consent--scheme-documentation-slice-head-named-p
                    source value "case-lambda")))
          (consent--scheme-documentation-slice-token source target))
         (t nil))))))

(defun consent--scheme-documentation-top-level-list-slices (source)
  "Return top-level list slices from SOURCE."
  (let ((cursor 0)
        (limit (length source))
        slices)
    (while (progn
             (setq cursor
                   (consent--scheme-documentation-skip-space-comments
                    source cursor limit))
             (< cursor limit))
      (let* ((start cursor)
             (end
              (consent--scheme-documentation-skip-datum
               source cursor limit)))
        (when (and (< start limit)
                   (eq (aref source start) ?\())
          (push (cons start end) slices))
        (setq cursor (max end (1+ cursor)))))
    (nreverse slices)))

(defun consent--scheme-documentation-exported-symbols-from-slice
    (source slice)
  "Return exported internal binding names from export SLICE in SOURCE."
  (condition-case nil
      (let ((form (consent-read (substring source (car slice) (cdr slice))))
            names)
        (when (consent--scheme-documentation-form-head-named-p form "export")
          (dolist (spec (cdr form))
            (dolist (name
                     (consent--scheme-documentation-export-spec-names spec))
              (push name names))))
        names)
    (error nil)))

(defun consent--scheme-documentation-public-procedure-slices (source)
  "Return exported procedure definition slices from Scheme library SOURCE.
Each result has the form (NAME START END)."
  (let (procedures)
    (dolist (library (consent--scheme-documentation-top-level-list-slices
                      source))
      (when (string=
             (or (consent--scheme-documentation-list-head-name
                  source (car library) (cdr library))
                 "")
             "define-library")
        (let* ((declarations
                (nthcdr
                 2
                 (consent--scheme-documentation-list-elements
                  source (car library) (cdr library))))
               (exports (make-hash-table :test #'equal)))
          (dolist (declaration declarations)
            (when (consent--scheme-documentation-slice-head-named-p
                   source declaration "export")
              (dolist (name
                       (consent--scheme-documentation-exported-symbols-from-slice
                        source declaration))
                (puthash name t exports))))
          (dolist (declaration declarations)
            (when (consent--scheme-documentation-slice-head-named-p
                   source declaration "begin")
              (dolist (body-form
                       (cdr
                        (consent--scheme-documentation-list-elements
                         source (car declaration) (cdr declaration))))
                (when (consent--scheme-documentation-slice-head-named-p
                       source body-form "define")
                  (let ((name
                         (consent--scheme-documentation-define-procedure-name-from-slice
                          source body-form)))
                    (when (and name (gethash name exports))
                      (push
                       (list
                        name
                        (car body-form)
                        (cdr body-form))
                       procedures))))))))))
    (nreverse procedures)))

(defun consent--scheme-documentation-proper-list-p (value)
  "Return non-nil when VALUE is a proper list."
  (let ((cursor value))
    (while (consp cursor)
      (setq cursor (cdr cursor)))
    (null cursor)))

(defun consent--scheme-documentation-symbol-named-p (value name)
  "Return non-nil when VALUE is the Consent Scheme symbol NAME."
  (and (consent-symbol-p value)
       (string= (consent-symbol-name value) name)))

(defun consent--scheme-documentation-string-fragments (value)
  "Return string fragments represented by VALUE, or nil."
  (cond
   ((stringp value) (list value))
   ((and (consp value)
         (consent--scheme-documentation-proper-list-p value)
         (cl-every #'stringp value))
    value)
   (t nil)))

(defun consent--scheme-documentation-obvious-type-prose-p (strings)
  "Return non-nil when STRINGS name a primitive non-any type."
  (let ((case-fold-search t)
        (text (mapconcat #'identity strings " ")))
    (string-match-p
     (rx word-start
         (or "boolean" "symbol" "string" "number" "integer"
             "pair" "list" "vector" "bytevector" "procedure"
             "port" "character")
         (? "s")
         word-end)
     text)))

(defun consent--scheme-documentation-rich-vectors (definition-text)
  "Return rich metadata vectors parsed from DEFINITION-TEXT."
  (let (vectors)
    (with-temp-buffer
      (insert definition-text)
      (goto-char (point-min))
      (while (search-forward "#(" nil t)
        (let ((start (match-beginning 0)))
          (goto-char start)
          (condition-case nil
              (let* ((end (scan-sexps start 1))
                     (datum
                      (consent-read
                       (buffer-substring-no-properties start end))))
                (when (vectorp datum)
                  (push datum vectors))
                (goto-char end))
            (error
             (goto-char (1+ start)))))))
    (nreverse vectors)))

(defun consent--scheme-documentation-description-fragments (descriptor)
  "Return DESCRIPTION string fragments from DESCRIPTOR, or nil."
  (when (consent--scheme-documentation-proper-list-p descriptor)
    (catch 'found
      (dolist (entry descriptor)
        (when (and (consp entry)
                   (consent--scheme-documentation-symbol-named-p
                    (car entry)
                    "description")
                   (consp (cdr entry))
                   (null (cddr entry)))
          (throw
           'found
           (consent--scheme-documentation-string-fragments (cadr entry)))))
      nil)))

(defun consent--scheme-documentation-type-any-entry-p (entry)
  "Return non-nil when ENTRY is exactly `(type any)'."
  (and (consp entry)
       (consent--scheme-documentation-symbol-named-p (car entry) "type")
       (consp (cdr entry))
       (null (cddr entry))
       (consent--scheme-documentation-symbol-named-p (cadr entry) "any")))

(defun consent--scheme-documentation-vector-field (vector name)
  "Return `(present . value)' for VECTOR field NAME, or nil when absent."
  (catch 'found
    (dotimes (index (length vector))
      (let ((entry (aref vector index)))
	(when (and (consp entry)
	           (consent--scheme-documentation-symbol-named-p
	            (car entry)
	            name))
	  (throw 'found (cons t (cdr entry))))))
    nil))

(defun consent--scheme-documentation-descriptor-has-type-p (descriptor)
  "Return non-nil when DESCRIPTOR explicitly includes a type entry."
  (let ((shorthand
         (consent--scheme-documentation-string-fragments descriptor)))
    (if shorthand
        (not (consent--scheme-documentation-obvious-type-prose-p
              shorthand))
      (and (consent--scheme-documentation-proper-list-p descriptor)
           (let ((type-entry
                  (cl-find-if
                   (lambda (entry)
                     (and (consp entry)
                          (consent--scheme-documentation-symbol-named-p
                           (car entry)
                           "type")
                          (consp (cdr entry))
                          (null (cddr entry))))
                   descriptor))
                 (description
                  (consent--scheme-documentation-description-fragments
                   descriptor)))
             (and type-entry
                  (not
                   (and
                    (consent--scheme-documentation-type-any-entry-p
                     type-entry)
                    description
                    (consent--scheme-documentation-obvious-type-prose-p
                     description)))))))))

(defun consent--scheme-documentation-typed-parameters-p (parameters)
  "Return non-nil when PARAMETERS carries explicit descriptor types."
  (and (consent--scheme-documentation-proper-list-p parameters)
       (cl-every
        (lambda (entry)
          (and (consp entry)
               (consent-symbol-p (car entry))
               (consent--scheme-documentation-descriptor-has-type-p
                (cdr entry))))
        parameters)))

(defun consent--scheme-documentation-rich-vector-p (definition-text)
  "Return non-nil when DEFINITION-TEXT has typed rich procedure metadata."
  (cl-some
   (lambda (vector)
     (let ((parameters
            (consent--scheme-documentation-vector-field vector "parameters"))
           (returns
            (consent--scheme-documentation-vector-field vector "returns")))
       (and parameters
            returns
            (consent--scheme-documentation-typed-parameters-p
             (cdr parameters))
            (consent--scheme-documentation-descriptor-has-type-p
             (cdr returns)))))
   (consent--scheme-documentation-rich-vectors definition-text)))

(defun consent--scheme-documentation-public-rich-errors (file)
  "Return rich-docstring errors for exported procedures in FILE."
  (let* ((text (with-temp-buffer
                 (insert-file-contents file)
                 (buffer-string)))
         (relative-file (file-relative-name file consent--test-root))
         errors)
    (dolist (procedure
             (consent--scheme-documentation-public-procedure-slices text))
      (let ((name (nth 0 procedure))
            (start (nth 1 procedure))
            (end (nth 2 procedure)))
        (unless (consent--scheme-documentation-rich-vector-p
                 (substring text start end))
          (push
           (format "%s:%d exported procedure %s missing rich metadata vector with typed parameters and returns"
                   relative-file
                   (consent--scheme-documentation-source-line text start)
                   name)
           errors))))
    (nreverse errors)))

(defun consent--scheme-documentation-repository-text-files ()
  "Return repository text files that can carry Scheme examples."
  (cl-loop for directory in '("scheme" "tests" "fixtures" "docs")
           append
           (directory-files-recursively
            (expand-file-name directory consent--test-root)
            "\\.\\(?:el\\|s\\(?:cm\\|ld\\)\\|md\\)\\'")))

(defun consent--scheme-documentation-scheme-style-files ()
  "Return Scheme source and fixture files checked for define layout."
  (cl-loop for directory in '("scheme" "tests/scheme" "fixtures/r7rs")
           append
           (directory-files-recursively
            (expand-file-name directory consent--test-root)
            "\\.s\\(?:cm\\|ld\\)\\'")))

(defun consent--scheme-documentation-value-procedure-define-errors
    (file)
  "Return errors for value `lambda' or `case-lambda' definitions."
  (let* ((text (with-temp-buffer
                 (insert-file-contents file)
                 (buffer-string)))
         (relative-file (file-relative-name file consent--test-root))
         errors)
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (while (re-search-forward
              (rx line-start
                  (* (any " \t"))
                  "(define"
                  (+ (any " \t\n"))
                  (+ (not (any " \t\n(" ")")))
                  (+ (any " \t\n"))
                  "(" (or "lambda" "case-lambda")
                  symbol-end)
              nil
              t)
        (push (format "%s:%d use named procedure definition syntax instead of defining a lambda value"
                      relative-file
                      (line-number-at-pos (match-beginning 0)))
              errors)))
    (nreverse errors)))

(defun consent--scheme-documentation-simple-datum-rhs-p (rhs)
  "Return non-nil when RHS starts with a simple datum literal."
  (string-match-p
   (rx string-start
       (* space)
       (or "#t" "#f" "#\\" digit "\"" "'" "`" "#(" "#u8("
           (: (? (or "+" "-")) digit)))
   rhs))

(defun consent--scheme-documentation-same-line-complex-define-errors
    (file)
  "Return errors for same-line non-datum value definitions in FILE."
  (let* ((text (with-temp-buffer
                 (insert-file-contents file)
                 (buffer-string)))
         (lines (split-string text "\n"))
         (relative-file (file-relative-name file consent--test-root))
         errors)
    (cl-loop for line in lines
             for index from 0
             when (string-match
                   (rx string-start
                       (* space)
                       "(define" (+ space)
                       (+ (not (any space "(" ")")))
                       (+ space)
                       (group (+ not-newline)))
                   line)
             do
             (let ((rhs (match-string 1 line)))
               (unless (consent--scheme-documentation-simple-datum-rhs-p
                        rhs)
                 (push (format "%s:%d place non-datum define value on a following line after the definition name"
                               relative-file
                               (1+ index))
                       errors))))
    (nreverse errors)))

(defun consent--scheme-documentation-compact-type-style-errors (file)
  "Return errors for expanded metadata types that should be compact."
  (let* ((text (with-temp-buffer
                 (insert-file-contents file)
                 (buffer-string)))
         (lines (split-string text "\n"))
         (relative-file (file-relative-name file consent--test-root))
         errors)
    (cl-loop for line in lines
             for next in (cdr lines)
             for index from 0
             for head = (and
                         (string-match
                          "\\`\\([[:space:]]*\\)(\\([^[:space:]()]+\\)[[:space:]]*\\'"
                          line)
                         (list (match-string 1 line)
                               (match-string 2 line)))
             for type = (and
                         (string-match
                          "\\`[[:space:]]*\\((type[[:space:]]+.*)\\)[[:space:]]*\\'"
                          next)
                         (match-string 1 next))
             when (and head type)
             do
             (let ((combined
                    (format "%s(%s %s"
                            (car head)
                            (cadr head)
                            type)))
               (when (<= (length combined)
                         consent--scheme-documentation-soft-line-limit)
                 (push (format "%s:%d compact `(type ...)' metadata onto the descriptor head line"
                               relative-file
                               (1+ index))
                       errors))))
    (nreverse errors)))

(ert-deftest consent-scheme-documentation-test-rich-type-shorthand ()
  "Treat dotted descriptor shorthand as intentional `any' metadata."
  (let ((shorthand
         "(define (example name values)
            \"Return a diagnostic field pair.\"
            #((parameters
               . ((name . \"Opaque field key supplied by the caller.\")
                  (values . \"Opaque field payloads.\")))
              (returns . \"Opaque field representation.\")
              (effects . (pure)))
            (cons name values))")
        (expanded-missing
         "(define (example name values)
            \"Return a diagnostic field pair.\"
            #((parameters
               . ((name
                   (description \"Symbol naming the diagnostic field.\"))
                  (values
                   (description \"Zero or more field values.\"))))
              (returns . ((description \"A field pair.\")))
              (effects . (pure)))
            (cons name values))"))
    (should (consent--scheme-documentation-rich-vector-p shorthand))
    (should-not
     (consent--scheme-documentation-rich-vector-p expanded-missing))))

(ert-deftest consent-scheme-documentation-test-obvious-types-need-expansion ()
  "Reject shorthand when descriptor prose names an obvious non-any type."
  (let ((obvious-shorthand
         "(define (example field)
            \"Return FIELD.\"
            #((parameters . ((field . \"Symbol naming the field.\")))
              (returns . \"The field symbol.\")
              (effects . (pure)))
            field)")
        (explicit-type
         "(define (example field)
            \"Return FIELD.\"
            #((parameters
               . ((field
                   (type symbol)
                   (description \"Symbol naming the field.\"))))
              (returns
               . ((type symbol)
                  (description \"The field symbol.\")))
              (effects . (pure)))
            field)"))
    (should-not
     (consent--scheme-documentation-rich-vector-p obvious-shorthand))
    (should (consent--scheme-documentation-rich-vector-p explicit-type))))

(ert-deftest consent-scheme-documentation-test-public-rich-detects-value-lambdas ()
  "Treat exported lambda-valued definitions as public procedures."
  (let ((file
         (make-temp-file
          "consent-doc-value-lambda" nil ".sld"
          (concat
           ";;; scratch.sld --- documentation fixture\n"
           "(define-library\n"
           "  (scratch docs)\n"
           "  (export\n"
           "    value-lambda\n"
           "    value-case-lambda)\n"
           "  (import (scheme base)\n"
           "          (scheme case-lambda))\n"
           "  (begin\n"
           "    (define\n"
           "      value-lambda\n"
           "      (" "lambda\n"
           "        (item)\n"
           "        item))\n"
           "    (define value-case-lambda\n"
           "      (" "case-lambda\n"
           "        (() #f)\n"
           "        ((item) item)))))"))))
    (unwind-protect
        (let ((errors
               (consent--scheme-documentation-public-rich-errors file)))
          (should
           (cl-some
            (lambda (error)
              (string-match-p
               "value-lambda missing rich metadata"
               error))
            errors))
          (should
           (cl-some
            (lambda (error)
              (string-match-p
               "value-case-lambda missing rich metadata"
               error))
            errors)))
      (delete-file file))))

(ert-deftest consent-scheme-documentation-test-value-procedure-define-style ()
  "Require procedure definitions to use named procedure syntax."
  (let ((file
         (make-temp-file
          "consent-doc-define-style" nil ".scm"
          (concat
           ";;; scratch.scm --- documentation fixture\n"
           "(define (good-lambda item) item)\n"
           "(define (good-case-lambda . args)\n"
           "  (apply (case-lambda ((item) item)) args))\n"
           "(define good-datum 42)\n"
           "(define bad-lambda " "(lambda (item) item))\n"
           "(define bad-wrapped-lambda\n"
           "  " "(lambda (item) item))\n"
           "(define bad-case-lambda " "(case-lambda ((item) item)))\n"
           "(define bad-wrapped-case-lambda\n"
           "  " "(case-lambda ((item) item)))\n"))))
    (unwind-protect
        (let ((errors
               (consent--scheme-documentation-value-procedure-define-errors
                file)))
          (should
           (cl-some
            (lambda (error)
              (string-match-p
               "named procedure definition syntax"
               error))
            errors))
          (should (= (length errors) 4)))
      (delete-file file))))

(ert-deftest consent-scheme-documentation-test-value-define-style ()
  "Allow same-line define values only for simple datum literals."
  (let ((file
         (make-temp-file
          "consent-doc-value-define-style" nil ".scm"
          (concat
           ";;; scratch.scm --- documentation fixture\n"
           "(define good-number 42)\n"
           "(define good-string \"value\")\n"
           "(define good-quoted '(a b))\n"
           "(define bad-call " "(list 'a))\n"
           "(define bad-alias " "other-name)\n"))))
    (unwind-protect
        (let ((errors
               (consent--scheme-documentation-same-line-complex-define-errors
                file)))
          (should
           (cl-some
            (lambda (error)
              (string-match-p "non-datum define value" error))
            errors))
          (should (= (length errors) 2)))
      (delete-file file))))

(ert-deftest consent-scheme-documentation-test-compact-type-style ()
  "Require compact expanded type metadata when the head line fits."
  (let ((errors
         (cl-loop for file in (consent--scheme-documentation-source-files)
                  append
                  (consent--scheme-documentation-compact-type-style-errors
                   file))))
    (when errors
      (ert-fail (mapconcat #'identity errors "\n")))))

(ert-deftest consent-scheme-documentation-test-value-procedure-define-style-corpus ()
  "Reject value lambda and case-lambda definitions in Scheme source."
  (let ((errors
         (cl-loop for file in (consent--scheme-documentation-scheme-style-files)
                  append
                  (consent--scheme-documentation-value-procedure-define-errors
                   file))))
    (when errors
      (ert-fail (mapconcat #'identity errors "\n")))))

(ert-deftest consent-scheme-documentation-test-value-define-style-corpus ()
  "Reject same-line non-datum value definitions in Scheme source."
  (let ((errors
         (cl-loop for file in (consent--scheme-documentation-scheme-style-files)
                  append
                  (consent--scheme-documentation-same-line-complex-define-errors
                   file))))
    (when errors
      (ert-fail (mapconcat #'identity errors "\n")))))

(ert-deftest consent-scheme-documentation-test-runtime-docstrings ()
  "Ensure representative public Scheme bindings carry runtime docstrings."
  (let (missing)
    (dolist (entry consent--scheme-documentation-representative-docstrings)
      (unless (apply #'consent--scheme-documentation-docstring-present-p
                     entry)
        (push (format "%s missing docstring for %s"
                      (nth 0 entry)
                      (nth 1 entry))
              missing)))
    (when missing
      (ert-fail (mapconcat #'identity (nreverse missing) "\n")))))

(ert-deftest consent-scheme-documentation-test-public-rich-docstrings ()
  "Ensure every exported Scheme procedure carries rich parameter and return metadata.
Runs fail-closed over every runtime `scheme/' source file, so a new file is
covered automatically. A file with no exported procedures produces no errors."
  (let ((errors
         (cl-loop for file in (consent--scheme-documentation-source-files)
                  append
                  (consent--scheme-documentation-public-rich-errors file))))
    (when errors
      (ert-fail (mapconcat #'identity errors "\n")))))

;;; consent-scheme-documentation-test.el ends here
