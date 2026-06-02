;;; agent-scheme-transcript.el --- Replayable transcript datums  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Transcript events are canonical Scheme-readable datums.  Host adapters may
;; store, rotate, summarize, or export these records, but replay decisions stay
;; explicit in the datum so host effects are never silently re-executed.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'agent-scheme-reader)
(require 'agent-scheme-redaction)
(require 'agent-scheme-result)
(require 'agent-scheme-runtime)

(defgroup agent-scheme-transcript nil
  "Replayable transcript settings for Agent Scheme."
  :group 'agent-scheme)

(defcustom agent-scheme-transcript-maximum-events 200
  "Default number of newest transcript events retained by rotation helpers."
  :type 'integer
  :group 'agent-scheme-transcript)

(defconst agent-scheme-transcript-event-kinds
  '(session-start session-end session-snapshot session-fork
    eval-start eval-end eval-error macro-expansion import definition
    agent-yield agent-log agent-progress agent-warn agent-request
    approval-request approval-decision capability-call
    skill-discovery skill-activation skill-resource-access
    memory-write memory-summary model-route)
  "Public transcript event kind vocabulary.")

(defconst agent-scheme-transcript-replay-modes
  '(audit-only deterministic-pure fixture-generation recorded-observation)
  "Public replay modes for transcript events.")

(defconst agent-scheme-transcript-export-formats
  '(scheme-datum text-summary fixture-cases)
  "Supported transcript export view names.")

(defvar agent-scheme--transcript-next-id 0
  "Next transcript event sequence number.")

(defun agent-scheme-transcript--name (value)
  "Return VALUE as a plain symbolic name string, or nil."
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

(defun agent-scheme-transcript--symbol (name)
  "Return NAME as an Agent Scheme symbol datum."
  (agent-scheme--syntax-symbol
   (or (agent-scheme-transcript--name name)
       (format "%S" name))))

(defun agent-scheme-transcript--integer (value)
  "Return VALUE as an exact integer datum."
  (agent-scheme--make-canonical-integer value))

(defun agent-scheme-transcript--datumize (value)
  "Return VALUE converted to a Scheme-readable transcript datum."
  (cond
   ((or (eq value agent-scheme-true)
        (eq value agent-scheme-false)
        (agent-scheme-symbol-p value)
        (agent-scheme-character-p value)
        (agent-scheme-number-p value)
        (agent-scheme-bytevector-p value)
        (agent-scheme-record-p value)
        (agent-scheme-record-type-p value)
        (agent-scheme-handle-p value))
    value)
   ((eq value t)
    agent-scheme-true)
   ((null value)
    nil)
   ((symbolp value)
    (agent-scheme-transcript--symbol value))
   ((stringp value)
    value)
   ((integerp value)
    (agent-scheme-transcript--integer value))
   ((floatp value)
    (number-to-string value))
   ((vectorp value)
    (vconcat (mapcar #'agent-scheme-transcript--datumize
                     (append value nil))))
   ((consp value)
    (cons (agent-scheme-transcript--datumize (car value))
          (agent-scheme-transcript--datumize (cdr value))))
   (t
    (format "%S" value))))

(defun agent-scheme-transcript--field (name value)
  "Return a Scheme-readable transcript field named NAME with VALUE."
  (list (agent-scheme-transcript--symbol name)
        (agent-scheme-transcript--datumize value)))

(defun agent-scheme-transcript--field-raw-value (field)
  "Return FIELD's raw value from either field-list or alist spelling."
  (cond
   ((and (consp field)
         (consp (cdr field))
         (null (cddr field)))
    (cadr field))
   ((consp field)
    (cdr field))
   (t nil)))

(defun agent-scheme-transcript--field-value-from-fields
    (fields name &optional default)
  "Return field NAME from FIELDS, or DEFAULT when absent."
  (let ((target (agent-scheme-transcript--name name))
        (value default))
    (dolist (field fields value)
      (when (and (consp field)
                 (equal (agent-scheme-transcript--name (car field))
                        target))
        (setq value (agent-scheme-transcript--field-raw-value field))))))

;;;###autoload
(defun agent-scheme-transcript-field-value (datum name &optional default)
  "Return field NAME from transcript DATUM, or DEFAULT when absent."
  (agent-scheme-transcript--field-value-from-fields
   (cdr-safe datum) name default))

;;;###autoload
(defun agent-scheme-transcript-event-p (datum)
  "Return non-nil when DATUM is a transcript event."
  (and (consp datum)
       (equal (agent-scheme-transcript--name (car datum))
              "transcript-event")))

(defun agent-scheme-transcript--generated-id ()
  "Return a fresh transcript event id symbol."
  (agent-scheme-transcript--symbol
   (format "e-%d" (cl-incf agent-scheme--transcript-next-id))))

(defun agent-scheme-transcript--timestamp ()
  "Return the current public transcript timestamp string."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun agent-scheme-transcript--intern-name (value)
  "Return VALUE's symbolic name as an interned Emacs Lisp symbol."
  (when-let ((name (agent-scheme-transcript--name value)))
    (intern name)))

(defun agent-scheme-transcript--host-effect-kind-p (kind)
  "Return non-nil when KIND describes a non-replayable host effect."
  (memq kind
        '(approval-request approval-decision capability-call
          skill-discovery skill-activation skill-resource-access
          memory-write memory-summary model-route)))

(defun agent-scheme-transcript--replay-mode-from-record (record)
  "Return replay mode from RECORD, or nil when absent."
  (let ((mode
         (and (consp record)
              (agent-scheme-transcript--field-value-from-fields
               (cdr record) "mode"))))
    (agent-scheme-transcript--intern-name mode)))

(defun agent-scheme-transcript--classify-event (event)
  "Return replay mode for transcript EVENT."
  (or (agent-scheme-transcript--replay-mode-from-record
       (agent-scheme-transcript-field-value event "replay"))
      (let* ((kind (agent-scheme-transcript--intern-name
                    (agent-scheme-transcript-field-value event "kind")))
             (form (agent-scheme-transcript-field-value event "form"))
             (result (agent-scheme-transcript-field-value event "result"))
             (error (agent-scheme-transcript-field-value event "error"))
             (effect (agent-scheme-transcript-field-value event "effect"))
             (capability
              (agent-scheme-transcript-field-value event "capability")))
        (cond
         ((or effect capability
              (agent-scheme-transcript--host-effect-kind-p kind))
          'recorded-observation)
         ((and (eq kind 'eval-end) form result)
          'deterministic-pure)
         ((and (eq kind 'eval-error) form error)
          'fixture-generation)
         (t
          'audit-only)))))

(defun agent-scheme-transcript--replay-reason (mode)
  "Return a short public replay reason for MODE."
  (pcase mode
    ('deterministic-pure
     "pure Scheme evaluation can be replayed")
    ('fixture-generation
     "event can seed a test fixture")
    ('recorded-observation
     "host effect is replayed only as an observation")
    (_
     "event is retained for audit only")))

(defun agent-scheme-transcript--replay-effect (mode)
  "Return the effect replay class for MODE."
  (pcase mode
    ('deterministic-pure 'pure-evaluation)
    ('fixture-generation 'pure-fixture)
    ('recorded-observation 'recorded-observation)
    (_ 'audit-only)))

(defun agent-scheme-transcript--replay-record (event explicit)
  "Return a replay field for EVENT, respecting EXPLICIT replay data."
  (if explicit
      (agent-scheme-transcript--datumize explicit)
    (let ((mode (agent-scheme-transcript--classify-event event)))
      (list
       (agent-scheme-transcript--symbol "replay")
       (agent-scheme-transcript--field "mode" mode)
       (agent-scheme-transcript--field
        "effect" (agent-scheme-transcript--replay-effect mode))
       (agent-scheme-transcript--field
        "reason" (agent-scheme-transcript--replay-reason mode))))))

(defun agent-scheme-transcript--reserved-field-p (field)
  "Return non-nil when FIELD is managed by transcript event creation."
  (member (agent-scheme-transcript--name (car-safe field))
          '("id" "session" "kind" "time" "replay")))

;;;###autoload
(cl-defun agent-scheme-transcript-event (kind fields
                                               &key id session time replay)
  "Return a redacted Scheme-readable transcript event.
KIND is a public transcript event kind.  FIELDS may be alist cells or
`(name value)' lists.  Missing ids and timestamps are supplied by the host."
  (let* ((event-id
          (or id
              (agent-scheme-transcript--field-value-from-fields fields "id")
              (agent-scheme-transcript--generated-id)))
         (event-session
          (or session
              (agent-scheme-transcript--field-value-from-fields
               fields "session")))
         (event-time
          (or time
              (agent-scheme-transcript--field-value-from-fields fields "time")
              (agent-scheme-transcript--timestamp)))
         (explicit-replay
          (or replay
              (agent-scheme-transcript--field-value-from-fields
               fields "replay")))
         (body-fields
          (cl-loop for field in fields
                   unless (agent-scheme-transcript--reserved-field-p field)
                   collect
                   (agent-scheme-transcript--field
                    (car field)
                    (agent-scheme-transcript--field-raw-value field))))
         (base
          (append
           (list (agent-scheme-transcript--symbol "transcript-event")
                 (agent-scheme-transcript--field "id" event-id))
           (when event-session
             (list (agent-scheme-transcript--field
                    "session" event-session)))
           (list (agent-scheme-transcript--field "kind" kind))
           body-fields
           (list (agent-scheme-transcript--field "time" event-time)))))
    (agent-scheme-redact
     (append base
             (list (agent-scheme-transcript--replay-record
                    base explicit-replay)))
     'transcript)))

;;;###autoload
(defun agent-scheme-transcript-event-replay-mode (event)
  "Return EVENT's replay mode as an Emacs Lisp symbol."
  (agent-scheme-transcript--classify-event event))

;;;###autoload
(defun agent-scheme-transcript-replayable-p (event)
  "Return non-nil when EVENT can drive deterministic replay or fixtures."
  (memq (agent-scheme-transcript-event-replay-mode event)
        '(deterministic-pure fixture-generation)))

;;;###autoload
(defun agent-scheme-transcript-recorded-observation-p (event)
  "Return non-nil when EVENT represents a recorded host observation."
  (eq (agent-scheme-transcript-event-replay-mode event)
      'recorded-observation))

(defun agent-scheme-transcript--summary-value (value)
  "Return a compact summary string for VALUE."
  (cond
   ((null value) "")
   ((stringp value) value)
   ((agent-scheme-symbol-p value) (agent-scheme-symbol-name value))
   ((symbolp value) (symbol-name value))
   (t (agent-scheme-result->external value))))

;;;###autoload
(defun agent-scheme-transcript-event-summary (event)
  "Return a human-readable one-line summary for EVENT."
  (let* ((id (agent-scheme-transcript--summary-value
              (agent-scheme-transcript-field-value event "id")))
         (kind (agent-scheme-transcript--summary-value
                (agent-scheme-transcript-field-value event "kind")))
         (session (agent-scheme-transcript--summary-value
                   (agent-scheme-transcript-field-value event "session")))
         (mode (agent-scheme-transcript-event-replay-mode event))
         (result (agent-scheme-transcript-field-value event "result"))
         (error (agent-scheme-transcript-field-value event "error"))
         (base (string-trim
                (format "%s %s%s"
                        id
                        kind
                        (if (string-empty-p session)
                            ""
                          (format " in %s" session))))))
    (cond
     ((eq mode 'recorded-observation)
      (format "%s recorded observation" base))
     (result
      (format "%s => %s"
              base (agent-scheme-transcript--summary-value result)))
     (error
      (format "%s ! %s"
              base (agent-scheme-transcript--summary-value error)))
     (t base))))

;;;###autoload
(defun agent-scheme-transcript-raw-view (events)
  "Return EVENTS as raw Scheme-readable transcript datums."
  events)

;;;###autoload
(defun agent-scheme-transcript-summary-view (events)
  "Return human-readable summaries for transcript EVENTS."
  (mapcar #'agent-scheme-transcript-event-summary events))

(defun agent-scheme-transcript--fixture-id (id)
  "Return a generated fixture id symbol for transcript ID."
  (agent-scheme-transcript--symbol
   (format "transcript-%s"
           (agent-scheme-transcript--summary-value id))))

(defun agent-scheme-transcript--fixture-source (form)
  "Return FORM as a fixture source string."
  (if (stringp form)
      form
    (agent-scheme-result->external form)))

(defun agent-scheme-transcript--fixture-result (result)
  "Return RESULT as a fixture expected value string."
  (if (stringp result)
      result
    (agent-scheme-result->external result)))

;;;###autoload
(defun agent-scheme-transcript-event->fixture-case (event)
  "Return an Agent Scheme fixture case generated from EVENT, or nil."
  (let* ((mode (agent-scheme-transcript-event-replay-mode event))
         (id (agent-scheme-transcript-field-value event "id"))
         (form (agent-scheme-transcript-field-value event "form"))
         (result (agent-scheme-transcript-field-value event "result"))
         (error (agent-scheme-transcript-field-value event "error")))
    (cond
     ((and (eq mode 'deterministic-pure) form result)
      (list
       (agent-scheme-transcript--field
        "id" (agent-scheme-transcript--fixture-id id))
       (agent-scheme-transcript--field "kind" 'agent-specific)
       (agent-scheme-transcript--field "phase" 'eval)
       (agent-scheme-transcript--field "category" 'transcript-replay)
       (agent-scheme-transcript--field "section" "agent transcript")
       (agent-scheme-transcript--field "status" 'implemented)
       (agent-scheme-transcript--field "oracle" 'shared)
       (agent-scheme-transcript--field "options" nil)
       (agent-scheme-transcript--field
        "description"
        (format "Generated from transcript event %s."
                (agent-scheme-transcript--summary-value id)))
       (agent-scheme-transcript--field
        "source" (agent-scheme-transcript--fixture-source form))
       (list (agent-scheme-transcript--symbol "expect")
             (list (agent-scheme-transcript--symbol "value")
                   (agent-scheme-transcript--fixture-result result)))))
     ((and (eq mode 'fixture-generation) form error)
      (list
       (agent-scheme-transcript--field
        "id" (agent-scheme-transcript--fixture-id id))
       (agent-scheme-transcript--field "kind" 'agent-specific)
       (agent-scheme-transcript--field "phase" 'error)
       (agent-scheme-transcript--field "category" 'transcript-replay)
       (agent-scheme-transcript--field "section" "agent transcript")
       (agent-scheme-transcript--field "status" 'implemented)
       (agent-scheme-transcript--field "oracle" 'shared)
       (agent-scheme-transcript--field "options" nil)
       (agent-scheme-transcript--field
        "description"
        (format "Generated from transcript event %s."
                (agent-scheme-transcript--summary-value id)))
       (agent-scheme-transcript--field
        "source" (agent-scheme-transcript--fixture-source form))
       (list (agent-scheme-transcript--symbol "expect")
             (list (agent-scheme-transcript--symbol "error")))))
     (t nil))))

;;;###autoload
(defun agent-scheme-transcript-rotate (events &optional keep)
  "Return the newest KEEP transcript EVENTS from chronological EVENTS."
  (let* ((limit (or keep agent-scheme-transcript-maximum-events))
         (count (length events)))
    (cond
     ((not (and (integerp limit) (> limit 0))) events)
     ((<= count limit) events)
     (t (nthcdr (- count limit) events)))))

;;;###autoload
(defun agent-scheme-transcript-export (events format)
  "Return a transcript view for EVENTS in FORMAT."
  (pcase (agent-scheme-transcript--intern-name format)
    ('scheme-datum
     (agent-scheme-transcript-raw-view events))
    ('text-summary
     (agent-scheme-transcript-summary-view events))
    ('fixture-cases
     (delq nil (mapcar #'agent-scheme-transcript-event->fixture-case
                       events)))
    (_
     (signal 'agent-scheme-eval-error
             (list (format "unknown transcript export format: %S"
                           format))))))

;;;###autoload
(defun agent-scheme-transcript-clear! ()
  "Reset transient transcript counters used by tests."
  (setq agent-scheme--transcript-next-id 0)
  agent-scheme-unspecified)

(provide 'agent-scheme-transcript)

;;; agent-scheme-transcript.el ends here
