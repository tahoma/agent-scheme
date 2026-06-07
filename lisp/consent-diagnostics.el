;;; consent-diagnostics.el --- Diagnostic datums and Emacs backend adapters  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Canonical diagnostic datum constructors plus Emacs diagnostic backend
;; normalization.  The Scheme-facing record shape matches `(agent diagnostics)';
;; live Emacs backend objects never cross the Consent Scheme boundary.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'consent-runtime)
(require 'consent-result)

;; Flymake is an optional runtime dependency loaded lazily by
;; `consent-diagnostics--flymake-diagnostics'; declare its accessors so the
;; byte-compiler does not flag the guarded call sites.
(declare-function flymake-diagnostic-type "flymake")
(declare-function flymake-diagnostic-text "flymake")
(declare-function flymake-diagnostic-beg "flymake")
(declare-function flymake-diagnostic-end "flymake")

(defcustom consent-diagnostics-buffer-function
  #'consent-diagnostics-default-buffer-diagnostics
  "Function that returns raw diagnostic observations for a live buffer.
The function receives BUFFER and CONTEXT and returns plist diagnostic records
or already-normalized diagnostic datums.  This hook is called by the
read-only `(emacs diagnostics)' adapter after handle and policy checks."
  :type 'function
  :group 'consent)

(defcustom consent-diagnostics-project-function
  #'consent-diagnostics-default-project-diagnostics
  "Function that returns raw diagnostic observations for a project.
The function receives PROJECT-ROOT, OPTIONS, and CONTEXT.  A nil value means
project-wide diagnostics are unavailable in the current host state."
  :type '(choice function (const nil))
  :group 'consent)

(defun consent-diagnostics--symbol (name)
  "Return NAME as an Consent Scheme symbol datum."
  (consent--syntax-symbol
   (cond
    ((consent-symbol-p name)
     (consent-symbol-name name))
    ((keywordp name)
     (substring (symbol-name name) 1))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun consent-diagnostics--integer (value)
  "Return VALUE as an exact Consent Scheme integer datum, or #f."
  (if (integerp value)
      (consent--make-number
       (number-to-string value) 'exact 10 'integer value)
    consent-false))

(defun consent-diagnostics--maybe-string (value)
  "Return VALUE as a copied string datum, or #f when VALUE is nil."
  (if value (substring-no-properties (format "%s" value)) consent-false))

(defun consent-diagnostics--field (name &rest values)
  "Return a Scheme-readable diagnostics field NAME with VALUES."
  (cons (consent-diagnostics--symbol name) values))

(defun consent-diagnostics--field-name (value)
  "Return VALUE as a stable diagnostic field name."
  (cond
   ((consent-symbol-p value)
    (consent-symbol-name value))
   ((keywordp value)
    (substring (symbol-name value) 1))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t nil)))

(defun consent-diagnostics--field-named-p (field name)
  "Return non-nil when FIELD has Scheme-readable NAME."
  (and (consp field)
       (equal (consent-diagnostics--field-name (car field)) name)))

(defun consent-diagnostics--field-value (record name &optional default)
  "Return field NAME from RECORD, or DEFAULT when absent."
  (let ((entry
         (seq-find
          (lambda (field)
            (consent-diagnostics--field-named-p field name))
          (cdr-safe record))))
    (if entry
        (cadr entry)
      default)))

(defun consent-diagnostics-field-value (record name &optional default)
  "Return diagnostic RECORD field NAME, or DEFAULT when absent."
  (consent-diagnostics--field-value record name default))

(defun consent-diagnostics--datum-value (value)
  "Return VALUE normalized for Scheme-readable diagnostic metadata."
  (cond
   ((null value) consent-false)
   ((eq value t) consent-true)
   ((or (stringp value) (consent-symbol-p value)
        (consent-number-p value))
    value)
   ((integerp value)
    (consent-diagnostics--integer value))
   ((symbolp value)
    (consent-diagnostics--symbol value))
   ((and (listp value)
         (seq-every-p #'consp value))
    (mapcar
     (lambda (entry)
       (cons (consent-diagnostics--symbol (car entry))
             (mapcar #'consent-diagnostics--datum-value (cdr entry))))
     value))
   (t
    (format "%S" value))))

(defun consent-diagnostics--metadata (metadata)
  "Return METADATA as Scheme-readable diagnostic metadata fields."
  (cond
   ((null metadata)
    nil)
   ((and (listp metadata) (keywordp (car metadata)))
    (let (fields)
      (while metadata
        (let ((key (pop metadata))
              (value (pop metadata)))
          (push
           (list (consent-diagnostics--symbol key)
                 (consent-diagnostics--datum-value value))
           fields)))
      (nreverse fields)))
   ((listp metadata)
    (mapcar
     (lambda (entry)
       (if (consp entry)
           (cons (consent-diagnostics--symbol (car entry))
                 (mapcar #'consent-diagnostics--datum-value (cdr entry)))
         (list (consent-diagnostics--symbol "value")
               (consent-diagnostics--datum-value entry))))
     metadata))
   (t
    (list
     (list (consent-diagnostics--symbol "value")
           (consent-diagnostics--datum-value metadata))))))

(defun consent-diagnostics--position-line-column (buffer position)
  "Return one-based line and column for POSITION in BUFFER, or nil values."
  (if (and (buffer-live-p buffer)
           (integerp position)
           (<= (point-min) position)
           (<= position (point-max)))
      (with-current-buffer buffer
        (save-excursion
          (goto-char position)
          (list (line-number-at-pos position) (1+ (current-column)))))
    (list nil nil)))

(defun consent-diagnostics-make-range
    (start end line column end-line end-column)
  "Return a canonical diagnostic range datum."
  (list
   (consent-diagnostics--symbol "diagnostic-range")
   (consent-diagnostics--field
    "start" (consent-diagnostics--integer start))
   (consent-diagnostics--field
    "end" (consent-diagnostics--integer end))
   (consent-diagnostics--field
    "line" (consent-diagnostics--integer line))
   (consent-diagnostics--field
    "column" (consent-diagnostics--integer column))
   (consent-diagnostics--field
    "end-line" (consent-diagnostics--integer end-line))
   (consent-diagnostics--field
    "end-column" (consent-diagnostics--integer end-column))))

(defun consent-diagnostics-range-from-positions
    (buffer start end &optional line column end-line end-column)
  "Return a diagnostic range for BUFFER positions START and END."
  (let* ((start-location
          (consent-diagnostics--position-line-column buffer start))
         (end-location
          (consent-diagnostics--position-line-column buffer end)))
    (consent-diagnostics-make-range
     start
     end
     (or line (car start-location))
     (or column (cadr start-location))
     (or end-line (car end-location))
     (or end-column (cadr end-location)))))

(defun consent-diagnostics--normalize-severity (severity)
  "Return SEVERITY as a shared diagnostic severity symbol."
  (let ((name (consent-diagnostics--field-name severity)))
    (consent-diagnostics--symbol
     (cond
      ((member name '("error" "warning" "note" "info" "hint"))
       name)
      ((equal name "warn")
       "warning")
      ((equal name "information")
       "info")
      (t "unknown")))))

(cl-defun consent-diagnostics-make-diagnostic
    (&key severity message source file buffer range metadata)
  "Return one canonical diagnostic datum."
  (list
   (consent-diagnostics--symbol "diagnostic")
   (consent-diagnostics--field
    "severity" (consent-diagnostics--normalize-severity severity))
   (consent-diagnostics--field "message" (or message ""))
   (consent-diagnostics--field
    "source" (consent-diagnostics--maybe-string (or source "unknown")))
   (consent-diagnostics--field
    "file" (consent-diagnostics--maybe-string file))
   (consent-diagnostics--field
    "buffer" (consent-diagnostics--maybe-string buffer))
   (consent-diagnostics--field "range" range)
   (consent-diagnostics--field
    "metadata" (consent-diagnostics--metadata metadata))))

(defun consent-diagnostics-diagnostic-p (datum)
  "Return non-nil when DATUM is a diagnostic record."
  (and (consp datum)
       (equal (consent-diagnostics--field-name (car datum))
              "diagnostic")))

(defun consent-diagnostics-normalize-diagnostic (datum buffer)
  "Return DATUM as a canonical diagnostic record for BUFFER."
  (if (consent-diagnostics-diagnostic-p datum)
      datum
    (let* ((start (plist-get datum :beg))
           (end (plist-get datum :end))
           (range
            (or (plist-get datum :range)
                (consent-diagnostics-range-from-positions
                 buffer
                 start
                 end
                 (plist-get datum :line)
                 (plist-get datum :column)
                 (plist-get datum :end-line)
                 (plist-get datum :end-column)))))
      (consent-diagnostics-make-diagnostic
       :severity (plist-get datum :severity)
       :message (or (plist-get datum :message) "")
       :source (or (plist-get datum :source) "unknown")
       :file (plist-get datum :file)
       :buffer (or (plist-get datum :buffer)
                   (and (buffer-live-p buffer) (buffer-name buffer)))
       :range range
       :metadata (plist-get datum :metadata)))))

(cl-defun consent-diagnostics-make-snapshot
    (&key status scope buffer file diagnostics metadata reason)
  "Return a canonical diagnostics snapshot datum."
  (append
   (list
    (consent-diagnostics--symbol "diagnostics-snapshot")
    (consent-diagnostics--field
     "status" (consent-diagnostics--symbol status))
    (consent-diagnostics--field
     "scope" (consent-diagnostics--symbol scope))
    (consent-diagnostics--field
     "buffer" (consent-diagnostics--maybe-string buffer))
    (consent-diagnostics--field
     "file" (consent-diagnostics--maybe-string file)))
   (when reason
     (list (consent-diagnostics--field "reason" reason)))
   (list
    (consent-diagnostics--field "diagnostics" diagnostics)
    (consent-diagnostics--field
     "metadata" (consent-diagnostics--metadata metadata)))))

(defun consent-diagnostics--eglot-managed-p (buffer)
  "Return non-nil when BUFFER is managed by Eglot."
  (and (buffer-live-p buffer)
       (fboundp 'eglot-managed-p)
       (with-current-buffer buffer
         (condition-case nil
             (eglot-managed-p)
           (error nil)))))

(defun consent-diagnostics--buffer-metadata (buffer)
  "Return adapter metadata for diagnostic observations in BUFFER."
  (append
   (list (list (consent-diagnostics--symbol "adapter")
               (consent-diagnostics--symbol "emacs")))
   (when (consent-diagnostics--eglot-managed-p buffer)
     (list
      (list (consent-diagnostics--symbol "eglot-managed?")
            consent-true)
      (list (consent-diagnostics--symbol "code-actions")
            (consent-diagnostics--symbol "not-exposed"))))))

(defun consent-diagnostics--marker-position (value)
  "Return VALUE as an integer position when possible."
  (cond
   ((markerp value) (marker-position value))
   ((integerp value) value)
   (t nil)))

(defun consent-diagnostics--flymake-source (diagnostic)
  "Return a stable Flymake source string for DIAGNOSTIC."
  (let ((backend
         (and (fboundp 'flymake-diagnostic-backend)
              (condition-case nil
                  (flymake-diagnostic-backend diagnostic)
                (error nil)))))
    (cond
     ((symbolp backend) (symbol-name backend))
     ((functionp backend) "flymake")
     ((stringp backend) backend)
     (t "flymake"))))

(defun consent-diagnostics--flymake-metadata (diagnostic)
  "Return safe Flymake metadata fields for DIAGNOSTIC."
  (let ((data
         (and (fboundp 'flymake-diagnostic-data)
              (condition-case nil
                  (flymake-diagnostic-data diagnostic)
                (error nil)))))
    (if data
        (list (list 'data (format "%S" data)))
      nil)))

(defun consent-diagnostics--flymake-diagnostic-plist
    (diagnostic buffer)
  "Return a raw diagnostic plist from Flymake DIAGNOSTIC in BUFFER."
  (list
   :severity (flymake-diagnostic-type diagnostic)
   :message (flymake-diagnostic-text diagnostic)
   :source (consent-diagnostics--flymake-source diagnostic)
   :beg (consent-diagnostics--marker-position
         (flymake-diagnostic-beg diagnostic))
   :end (consent-diagnostics--marker-position
         (flymake-diagnostic-end diagnostic))
   :file (buffer-file-name buffer)
   :buffer (buffer-name buffer)
   :metadata (consent-diagnostics--flymake-metadata diagnostic)))

(defun consent-diagnostics--flymake-diagnostics (buffer)
  "Return raw Flymake diagnostic plists for BUFFER."
  (when (and (buffer-live-p buffer)
             (require 'flymake nil t)
             (fboundp 'flymake-diagnostics))
    (with-current-buffer buffer
      (condition-case nil
          (mapcar
           (lambda (diagnostic)
             (consent-diagnostics--flymake-diagnostic-plist
              diagnostic buffer))
           (flymake-diagnostics (point-min) (point-max)))
        (error nil)))))

(defun consent-diagnostics--safe-access (function object)
  "Call FUNCTION on OBJECT when FUNCTION exists, returning nil on errors."
  (and (fboundp function)
       (condition-case nil
           (funcall function object)
         (error nil))))

(defun consent-diagnostics--flycheck-position
    (buffer line column)
  "Return BUFFER position for one-based LINE and COLUMN, or nil."
  (when (and (buffer-live-p buffer) (integerp line))
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (condition-case nil
            (progn
              (forward-line (1- line))
              (when (integerp column)
                (forward-char (max 0 (1- column))))
              (point))
          (error nil))))))

(defun consent-diagnostics--flycheck-diagnostic-plist
    (error buffer)
  "Return a raw diagnostic plist from Flycheck ERROR in BUFFER."
  (let* ((line (consent-diagnostics--safe-access
                'flycheck-error-line error))
         (column (consent-diagnostics--safe-access
                  'flycheck-error-column error))
         (end-line (consent-diagnostics--safe-access
                    'flycheck-error-end-line error))
         (end-column (consent-diagnostics--safe-access
                      'flycheck-error-end-column error))
         (start (consent-diagnostics--flycheck-position
                 buffer line column))
         (end (consent-diagnostics--flycheck-position
               buffer (or end-line line) (or end-column column))))
    (list
     :severity (consent-diagnostics--safe-access
                'flycheck-error-level error)
     :message (consent-diagnostics--safe-access
               'flycheck-error-message error)
     :source (or (consent-diagnostics--safe-access
                  'flycheck-error-checker error)
                 "flycheck")
     :beg start
     :end end
     :line line
     :column column
     :end-line end-line
     :end-column end-column
     :file (or (consent-diagnostics--safe-access
                'flycheck-error-filename error)
               (buffer-file-name buffer))
     :buffer (buffer-name buffer)
     :metadata nil)))

(defun consent-diagnostics--flycheck-diagnostics (buffer)
  "Return raw Flycheck diagnostic plists for BUFFER when Flycheck is loaded."
  (when (and (buffer-live-p buffer)
             (boundp 'flycheck-current-errors))
    (with-current-buffer buffer
      (condition-case nil
          (mapcar
           (lambda (error)
             (consent-diagnostics--flycheck-diagnostic-plist
              error buffer))
           flycheck-current-errors)
        (error nil)))))

(defun consent-diagnostics-default-buffer-diagnostics
    (buffer _context)
  "Return raw diagnostics for BUFFER from active Emacs backends."
  (append
   (consent-diagnostics--flymake-diagnostics buffer)
   (consent-diagnostics--flycheck-diagnostics buffer)))

(defun consent-diagnostics-buffer-snapshot (buffer context)
  "Return a diagnostics snapshot for live BUFFER."
  (let* ((raw
          (if (functionp consent-diagnostics-buffer-function)
              (funcall consent-diagnostics-buffer-function
                       buffer context)
            nil))
         (diagnostics
          (mapcar
           (lambda (diagnostic)
             (consent-diagnostics-normalize-diagnostic
              diagnostic buffer))
           raw)))
    (consent-diagnostics-make-snapshot
     :status 'ok
     :scope 'buffer
     :buffer (buffer-name buffer)
     :file (buffer-file-name buffer)
     :diagnostics diagnostics
     :metadata (consent-diagnostics--buffer-metadata buffer))))

(defun consent-diagnostics-snapshot-diagnostics (snapshot)
  "Return SNAPSHOT's diagnostic records."
  (consent-diagnostics-field-value snapshot "diagnostics" nil))

(defun consent-diagnostics--project-buffer-p (buffer root)
  "Return non-nil when BUFFER belongs to project ROOT."
  (when-let ((file (and (buffer-live-p buffer) (buffer-file-name buffer))))
    (file-in-directory-p (expand-file-name file)
                         (file-name-as-directory (expand-file-name root)))))

(defun consent-diagnostics-default-project-diagnostics
    (root _options context)
  "Return raw diagnostics for live buffers under project ROOT."
  (let (diagnostics)
    (dolist (buffer (buffer-list))
      (when (consent-diagnostics--project-buffer-p buffer root)
        (dolist (diagnostic
                 (if (functionp consent-diagnostics-buffer-function)
                     (funcall consent-diagnostics-buffer-function
                              buffer context)
                   nil))
          (push diagnostic diagnostics))))
    (nreverse diagnostics)))

(defun consent-diagnostics-project-snapshot (options context)
  "Return a project diagnostics snapshot using OPTIONS and CONTEXT."
  (let ((project (project-current nil)))
    (cond
     ((not project)
      (consent-diagnostics-make-snapshot
       :status 'unavailable
       :scope 'project
       :diagnostics nil
       :metadata '()
       :reason "project diagnostics require a current project"))
     ((not (functionp consent-diagnostics-project-function))
      (consent-diagnostics-make-snapshot
       :status 'unavailable
       :scope 'project
       :file (file-name-as-directory
              (expand-file-name (project-root project)))
       :diagnostics nil
       :metadata '()
       :reason "project diagnostics backend is unavailable"))
     (t
      (let* ((root (file-name-as-directory
                    (expand-file-name (project-root project))))
             (raw (funcall consent-diagnostics-project-function
                           root options context))
             (diagnostics
              (mapcar
               (lambda (diagnostic)
                 (let* ((file (plist-get diagnostic :file))
                        (buffer (and file (get-file-buffer file))))
                   (consent-diagnostics-normalize-diagnostic
                    diagnostic buffer)))
               raw)))
        (consent-diagnostics-make-snapshot
         :status 'ok
         :scope 'project
         :file root
         :diagnostics diagnostics
         :metadata
         (list
          (list (consent-diagnostics--symbol "adapter")
                (consent-diagnostics--symbol "emacs")))))))))

(defun consent-diagnostics--number-value (datum)
  "Return DATUM's integer value, or nil."
  (cond
   ((consent-number-p datum)
    (consent-number-value datum))
   ((integerp datum)
    datum)
   (t nil)))

(defun consent-diagnostics--diagnostic-contains-position-p
    (diagnostic position)
  "Return non-nil when DIAGNOSTIC contains POSITION."
  (let* ((range (consent-diagnostics--field-value diagnostic "range"))
         (start (consent-diagnostics--number-value
                 (consent-diagnostics--field-value range "start")))
         (end (consent-diagnostics--number-value
               (consent-diagnostics--field-value range "end"))))
    (and start end
         (<= start position)
         (< position end))))

(defun consent-diagnostics-at (buffer position context)
  "Return the first diagnostic in BUFFER containing POSITION."
  (let* ((snapshot
          (consent-diagnostics-buffer-snapshot buffer context))
         (diagnostics
          (consent-diagnostics--field-value
           snapshot "diagnostics" nil)))
    (or (seq-find
         (lambda (diagnostic)
           (consent-diagnostics--diagnostic-contains-position-p
            diagnostic position))
         diagnostics)
        consent-false)))

(provide 'consent-diagnostics)

;;; consent-diagnostics.el ends here
