;;; agent-scheme-diagnostics.el --- Diagnostic datums and Emacs backend adapters  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Canonical diagnostic datum constructors plus Emacs diagnostic backend
;; normalization.  The Scheme-facing record shape matches `(agent diagnostics)';
;; live Emacs backend objects never cross the Agent Scheme boundary.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'agent-scheme-runtime)
(require 'agent-scheme-result)

(defcustom agent-scheme-diagnostics-buffer-function
  #'agent-scheme-diagnostics-default-buffer-diagnostics
  "Function that returns raw diagnostic observations for a live buffer.
The function receives BUFFER and CONTEXT and returns plist diagnostic records
or already-normalized diagnostic datums.  This hook is called by the
read-only `(emacs diagnostics)' adapter after handle and policy checks."
  :type 'function
  :group 'agent-scheme)

(defcustom agent-scheme-diagnostics-project-function
  #'agent-scheme-diagnostics-default-project-diagnostics
  "Function that returns raw diagnostic observations for a project.
The function receives PROJECT-ROOT, OPTIONS, and CONTEXT.  A nil value means
project-wide diagnostics are unavailable in the current host state."
  :type '(choice function (const nil))
  :group 'agent-scheme)

(defun agent-scheme-diagnostics--symbol (name)
  "Return NAME as an Agent Scheme symbol datum."
  (agent-scheme--syntax-symbol
   (cond
    ((agent-scheme-symbol-p name)
     (agent-scheme-symbol-name name))
    ((keywordp name)
     (substring (symbol-name name) 1))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun agent-scheme-diagnostics--integer (value)
  "Return VALUE as an exact Agent Scheme integer datum, or #f."
  (if (integerp value)
      (agent-scheme--make-number
       (number-to-string value) 'exact 10 'integer value)
    agent-scheme-false))

(defun agent-scheme-diagnostics--maybe-string (value)
  "Return VALUE as a copied string datum, or #f when VALUE is nil."
  (if value (substring-no-properties (format "%s" value)) agent-scheme-false))

(defun agent-scheme-diagnostics--field (name &rest values)
  "Return a Scheme-readable diagnostics field NAME with VALUES."
  (cons (agent-scheme-diagnostics--symbol name) values))

(defun agent-scheme-diagnostics--field-name (value)
  "Return VALUE as a stable diagnostic field name."
  (cond
   ((agent-scheme-symbol-p value)
    (agent-scheme-symbol-name value))
   ((keywordp value)
    (substring (symbol-name value) 1))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t nil)))

(defun agent-scheme-diagnostics--field-named-p (field name)
  "Return non-nil when FIELD has Scheme-readable NAME."
  (and (consp field)
       (equal (agent-scheme-diagnostics--field-name (car field)) name)))

(defun agent-scheme-diagnostics--field-value (record name &optional default)
  "Return field NAME from RECORD, or DEFAULT when absent."
  (let ((entry
         (seq-find
          (lambda (field)
            (agent-scheme-diagnostics--field-named-p field name))
          (cdr-safe record))))
    (if entry
        (cadr entry)
      default)))

(defun agent-scheme-diagnostics-field-value (record name &optional default)
  "Return diagnostic RECORD field NAME, or DEFAULT when absent."
  (agent-scheme-diagnostics--field-value record name default))

(defun agent-scheme-diagnostics--datum-value (value)
  "Return VALUE normalized for Scheme-readable diagnostic metadata."
  (cond
   ((null value) agent-scheme-false)
   ((eq value t) agent-scheme-true)
   ((or (stringp value) (agent-scheme-symbol-p value)
        (agent-scheme-number-p value))
    value)
   ((integerp value)
    (agent-scheme-diagnostics--integer value))
   ((symbolp value)
    (agent-scheme-diagnostics--symbol value))
   ((and (listp value)
         (seq-every-p #'consp value))
    (mapcar
     (lambda (entry)
       (cons (agent-scheme-diagnostics--symbol (car entry))
             (mapcar #'agent-scheme-diagnostics--datum-value (cdr entry))))
     value))
   (t
    (format "%S" value))))

(defun agent-scheme-diagnostics--metadata (metadata)
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
           (list (agent-scheme-diagnostics--symbol key)
                 (agent-scheme-diagnostics--datum-value value))
           fields)))
      (nreverse fields)))
   ((listp metadata)
    (mapcar
     (lambda (entry)
       (if (consp entry)
           (cons (agent-scheme-diagnostics--symbol (car entry))
                 (mapcar #'agent-scheme-diagnostics--datum-value (cdr entry)))
         (list (agent-scheme-diagnostics--symbol "value")
               (agent-scheme-diagnostics--datum-value entry))))
     metadata))
   (t
    (list
     (list (agent-scheme-diagnostics--symbol "value")
           (agent-scheme-diagnostics--datum-value metadata))))))

(defun agent-scheme-diagnostics--position-line-column (buffer position)
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

(defun agent-scheme-diagnostics-make-range
    (start end line column end-line end-column)
  "Return a canonical diagnostic range datum."
  (list
   (agent-scheme-diagnostics--symbol "diagnostic-range")
   (agent-scheme-diagnostics--field
    "start" (agent-scheme-diagnostics--integer start))
   (agent-scheme-diagnostics--field
    "end" (agent-scheme-diagnostics--integer end))
   (agent-scheme-diagnostics--field
    "line" (agent-scheme-diagnostics--integer line))
   (agent-scheme-diagnostics--field
    "column" (agent-scheme-diagnostics--integer column))
   (agent-scheme-diagnostics--field
    "end-line" (agent-scheme-diagnostics--integer end-line))
   (agent-scheme-diagnostics--field
    "end-column" (agent-scheme-diagnostics--integer end-column))))

(defun agent-scheme-diagnostics-range-from-positions
    (buffer start end &optional line column end-line end-column)
  "Return a diagnostic range for BUFFER positions START and END."
  (let* ((start-location
          (agent-scheme-diagnostics--position-line-column buffer start))
         (end-location
          (agent-scheme-diagnostics--position-line-column buffer end)))
    (agent-scheme-diagnostics-make-range
     start
     end
     (or line (car start-location))
     (or column (cadr start-location))
     (or end-line (car end-location))
     (or end-column (cadr end-location)))))

(defun agent-scheme-diagnostics--normalize-severity (severity)
  "Return SEVERITY as a shared diagnostic severity symbol."
  (let ((name (agent-scheme-diagnostics--field-name severity)))
    (agent-scheme-diagnostics--symbol
     (cond
      ((member name '("error" "warning" "note" "info" "hint"))
       name)
      ((equal name "warn")
       "warning")
      ((equal name "information")
       "info")
      (t "unknown")))))

(cl-defun agent-scheme-diagnostics-make-diagnostic
    (&key severity message source file buffer range metadata)
  "Return one canonical diagnostic datum."
  (list
   (agent-scheme-diagnostics--symbol "diagnostic")
   (agent-scheme-diagnostics--field
    "severity" (agent-scheme-diagnostics--normalize-severity severity))
   (agent-scheme-diagnostics--field "message" (or message ""))
   (agent-scheme-diagnostics--field
    "source" (agent-scheme-diagnostics--maybe-string (or source "unknown")))
   (agent-scheme-diagnostics--field
    "file" (agent-scheme-diagnostics--maybe-string file))
   (agent-scheme-diagnostics--field
    "buffer" (agent-scheme-diagnostics--maybe-string buffer))
   (agent-scheme-diagnostics--field "range" range)
   (agent-scheme-diagnostics--field
    "metadata" (agent-scheme-diagnostics--metadata metadata))))

(defun agent-scheme-diagnostics-diagnostic-p (datum)
  "Return non-nil when DATUM is a diagnostic record."
  (and (consp datum)
       (equal (agent-scheme-diagnostics--field-name (car datum))
              "diagnostic")))

(defun agent-scheme-diagnostics-normalize-diagnostic (datum buffer)
  "Return DATUM as a canonical diagnostic record for BUFFER."
  (if (agent-scheme-diagnostics-diagnostic-p datum)
      datum
    (let* ((start (plist-get datum :beg))
           (end (plist-get datum :end))
           (range
            (or (plist-get datum :range)
                (agent-scheme-diagnostics-range-from-positions
                 buffer
                 start
                 end
                 (plist-get datum :line)
                 (plist-get datum :column)
                 (plist-get datum :end-line)
                 (plist-get datum :end-column)))))
      (agent-scheme-diagnostics-make-diagnostic
       :severity (plist-get datum :severity)
       :message (or (plist-get datum :message) "")
       :source (or (plist-get datum :source) "unknown")
       :file (plist-get datum :file)
       :buffer (or (plist-get datum :buffer)
                   (and (buffer-live-p buffer) (buffer-name buffer)))
       :range range
       :metadata (plist-get datum :metadata)))))

(cl-defun agent-scheme-diagnostics-make-snapshot
    (&key status scope buffer file diagnostics metadata reason)
  "Return a canonical diagnostics snapshot datum."
  (append
   (list
    (agent-scheme-diagnostics--symbol "diagnostics-snapshot")
    (agent-scheme-diagnostics--field
     "status" (agent-scheme-diagnostics--symbol status))
    (agent-scheme-diagnostics--field
     "scope" (agent-scheme-diagnostics--symbol scope))
    (agent-scheme-diagnostics--field
     "buffer" (agent-scheme-diagnostics--maybe-string buffer))
    (agent-scheme-diagnostics--field
     "file" (agent-scheme-diagnostics--maybe-string file)))
   (when reason
     (list (agent-scheme-diagnostics--field "reason" reason)))
   (list
    (agent-scheme-diagnostics--field "diagnostics" diagnostics)
    (agent-scheme-diagnostics--field
     "metadata" (agent-scheme-diagnostics--metadata metadata)))))

(defun agent-scheme-diagnostics--eglot-managed-p (buffer)
  "Return non-nil when BUFFER is managed by Eglot."
  (and (buffer-live-p buffer)
       (fboundp 'eglot-managed-p)
       (with-current-buffer buffer
         (condition-case nil
             (eglot-managed-p)
           (error nil)))))

(defun agent-scheme-diagnostics--buffer-metadata (buffer)
  "Return adapter metadata for diagnostic observations in BUFFER."
  (append
   (list (list (agent-scheme-diagnostics--symbol "adapter")
               (agent-scheme-diagnostics--symbol "emacs")))
   (when (agent-scheme-diagnostics--eglot-managed-p buffer)
     (list
      (list (agent-scheme-diagnostics--symbol "eglot-managed?")
            agent-scheme-true)
      (list (agent-scheme-diagnostics--symbol "code-actions")
            (agent-scheme-diagnostics--symbol "not-exposed"))))))

(defun agent-scheme-diagnostics--marker-position (value)
  "Return VALUE as an integer position when possible."
  (cond
   ((markerp value) (marker-position value))
   ((integerp value) value)
   (t nil)))

(defun agent-scheme-diagnostics--flymake-source (diagnostic)
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

(defun agent-scheme-diagnostics--flymake-metadata (diagnostic)
  "Return safe Flymake metadata fields for DIAGNOSTIC."
  (let ((data
         (and (fboundp 'flymake-diagnostic-data)
              (condition-case nil
                  (flymake-diagnostic-data diagnostic)
                (error nil)))))
    (if data
        (list (list 'data (format "%S" data)))
      nil)))

(defun agent-scheme-diagnostics--flymake-diagnostic-plist
    (diagnostic buffer)
  "Return a raw diagnostic plist from Flymake DIAGNOSTIC in BUFFER."
  (list
   :severity (flymake-diagnostic-type diagnostic)
   :message (flymake-diagnostic-text diagnostic)
   :source (agent-scheme-diagnostics--flymake-source diagnostic)
   :beg (agent-scheme-diagnostics--marker-position
         (flymake-diagnostic-beg diagnostic))
   :end (agent-scheme-diagnostics--marker-position
         (flymake-diagnostic-end diagnostic))
   :file (buffer-file-name buffer)
   :buffer (buffer-name buffer)
   :metadata (agent-scheme-diagnostics--flymake-metadata diagnostic)))

(defun agent-scheme-diagnostics--flymake-diagnostics (buffer)
  "Return raw Flymake diagnostic plists for BUFFER."
  (when (and (buffer-live-p buffer)
             (require 'flymake nil t)
             (fboundp 'flymake-diagnostics))
    (with-current-buffer buffer
      (condition-case nil
          (mapcar
           (lambda (diagnostic)
             (agent-scheme-diagnostics--flymake-diagnostic-plist
              diagnostic buffer))
           (flymake-diagnostics (point-min) (point-max)))
        (error nil)))))

(defun agent-scheme-diagnostics--safe-access (function object)
  "Call FUNCTION on OBJECT when FUNCTION exists, returning nil on errors."
  (and (fboundp function)
       (condition-case nil
           (funcall function object)
         (error nil))))

(defun agent-scheme-diagnostics--flycheck-position
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

(defun agent-scheme-diagnostics--flycheck-diagnostic-plist
    (error buffer)
  "Return a raw diagnostic plist from Flycheck ERROR in BUFFER."
  (let* ((line (agent-scheme-diagnostics--safe-access
                'flycheck-error-line error))
         (column (agent-scheme-diagnostics--safe-access
                  'flycheck-error-column error))
         (end-line (agent-scheme-diagnostics--safe-access
                    'flycheck-error-end-line error))
         (end-column (agent-scheme-diagnostics--safe-access
                      'flycheck-error-end-column error))
         (start (agent-scheme-diagnostics--flycheck-position
                 buffer line column))
         (end (agent-scheme-diagnostics--flycheck-position
               buffer (or end-line line) (or end-column column))))
    (list
     :severity (agent-scheme-diagnostics--safe-access
                'flycheck-error-level error)
     :message (agent-scheme-diagnostics--safe-access
               'flycheck-error-message error)
     :source (or (agent-scheme-diagnostics--safe-access
                  'flycheck-error-checker error)
                 "flycheck")
     :beg start
     :end end
     :line line
     :column column
     :end-line end-line
     :end-column end-column
     :file (or (agent-scheme-diagnostics--safe-access
                'flycheck-error-filename error)
               (buffer-file-name buffer))
     :buffer (buffer-name buffer)
     :metadata nil)))

(defun agent-scheme-diagnostics--flycheck-diagnostics (buffer)
  "Return raw Flycheck diagnostic plists for BUFFER when Flycheck is loaded."
  (when (and (buffer-live-p buffer)
             (boundp 'flycheck-current-errors))
    (with-current-buffer buffer
      (condition-case nil
          (mapcar
           (lambda (error)
             (agent-scheme-diagnostics--flycheck-diagnostic-plist
              error buffer))
           flycheck-current-errors)
        (error nil)))))

(defun agent-scheme-diagnostics-default-buffer-diagnostics
    (buffer _context)
  "Return raw diagnostics for BUFFER from active Emacs backends."
  (append
   (agent-scheme-diagnostics--flymake-diagnostics buffer)
   (agent-scheme-diagnostics--flycheck-diagnostics buffer)))

(defun agent-scheme-diagnostics-buffer-snapshot (buffer context)
  "Return a diagnostics snapshot for live BUFFER."
  (let* ((raw
          (if (functionp agent-scheme-diagnostics-buffer-function)
              (funcall agent-scheme-diagnostics-buffer-function
                       buffer context)
            nil))
         (diagnostics
          (mapcar
           (lambda (diagnostic)
             (agent-scheme-diagnostics-normalize-diagnostic
              diagnostic buffer))
           raw)))
    (agent-scheme-diagnostics-make-snapshot
     :status 'ok
     :scope 'buffer
     :buffer (buffer-name buffer)
     :file (buffer-file-name buffer)
     :diagnostics diagnostics
     :metadata (agent-scheme-diagnostics--buffer-metadata buffer))))

(defun agent-scheme-diagnostics-snapshot-diagnostics (snapshot)
  "Return SNAPSHOT's diagnostic records."
  (agent-scheme-diagnostics-field-value snapshot "diagnostics" nil))

(defun agent-scheme-diagnostics--project-buffer-p (buffer root)
  "Return non-nil when BUFFER belongs to project ROOT."
  (when-let ((file (and (buffer-live-p buffer) (buffer-file-name buffer))))
    (file-in-directory-p (expand-file-name file)
                         (file-name-as-directory (expand-file-name root)))))

(defun agent-scheme-diagnostics-default-project-diagnostics
    (root _options context)
  "Return raw diagnostics for live buffers under project ROOT."
  (let (diagnostics)
    (dolist (buffer (buffer-list))
      (when (agent-scheme-diagnostics--project-buffer-p buffer root)
        (dolist (diagnostic
                 (if (functionp agent-scheme-diagnostics-buffer-function)
                     (funcall agent-scheme-diagnostics-buffer-function
                              buffer context)
                   nil))
          (push diagnostic diagnostics))))
    (nreverse diagnostics)))

(defun agent-scheme-diagnostics-project-snapshot (options context)
  "Return a project diagnostics snapshot using OPTIONS and CONTEXT."
  (let ((project (project-current nil)))
    (cond
     ((not project)
      (agent-scheme-diagnostics-make-snapshot
       :status 'unavailable
       :scope 'project
       :diagnostics nil
       :metadata '()
       :reason "project diagnostics require a current project"))
     ((not (functionp agent-scheme-diagnostics-project-function))
      (agent-scheme-diagnostics-make-snapshot
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
             (raw (funcall agent-scheme-diagnostics-project-function
                           root options context))
             (diagnostics
              (mapcar
               (lambda (diagnostic)
                 (let* ((file (plist-get diagnostic :file))
                        (buffer (and file (get-file-buffer file))))
                   (agent-scheme-diagnostics-normalize-diagnostic
                    diagnostic buffer)))
               raw)))
        (agent-scheme-diagnostics-make-snapshot
         :status 'ok
         :scope 'project
         :file root
         :diagnostics diagnostics
         :metadata
         (list
          (list (agent-scheme-diagnostics--symbol "adapter")
                (agent-scheme-diagnostics--symbol "emacs")))))))))

(defun agent-scheme-diagnostics--number-value (datum)
  "Return DATUM's integer value, or nil."
  (cond
   ((agent-scheme-number-p datum)
    (agent-scheme-number-value datum))
   ((integerp datum)
    datum)
   (t nil)))

(defun agent-scheme-diagnostics--diagnostic-contains-position-p
    (diagnostic position)
  "Return non-nil when DIAGNOSTIC contains POSITION."
  (let* ((range (agent-scheme-diagnostics--field-value diagnostic "range"))
         (start (agent-scheme-diagnostics--number-value
                 (agent-scheme-diagnostics--field-value range "start")))
         (end (agent-scheme-diagnostics--number-value
               (agent-scheme-diagnostics--field-value range "end"))))
    (and start end
         (<= start position)
         (< position end))))

(defun agent-scheme-diagnostics-at (buffer position context)
  "Return the first diagnostic in BUFFER containing POSITION."
  (let* ((snapshot
          (agent-scheme-diagnostics-buffer-snapshot buffer context))
         (diagnostics
          (agent-scheme-diagnostics--field-value
           snapshot "diagnostics" nil)))
    (or (seq-find
         (lambda (diagnostic)
           (agent-scheme-diagnostics--diagnostic-contains-position-p
            diagnostic position))
         diagnostics)
        agent-scheme-false)))

(provide 'agent-scheme-diagnostics)

;;; agent-scheme-diagnostics.el ends here
