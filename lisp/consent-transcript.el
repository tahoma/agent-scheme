;;; consent-transcript.el --- Replayable transcript datums  -*- lexical-binding: t; -*-
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
(require 'consent-reader)
(require 'consent-redaction)
(require 'consent-result)
(require 'consent-runtime)

(defgroup consent-transcript nil
  "Replayable transcript settings for Consent Scheme."
  :group 'consent)

(defcustom consent-transcript-maximum-events 200
  "Default number of newest transcript events retained by rotation helpers."
  :type 'integer
  :group 'consent-transcript)

(defconst consent-transcript-event-kinds
  '(session-start session-end session-snapshot session-fork
    eval-start eval-end eval-error macro-expansion import definition
    agent-yield agent-log agent-progress agent-warn agent-request
    approval-request approval-decision capability-call
    skill-discovery skill-activation skill-resource-access
    memory-write memory-summary model-route)
  "Public transcript event kind vocabulary.")

(defconst consent-transcript-replay-modes
  '(audit-only deterministic-pure fixture-generation recorded-observation)
  "Public replay modes for transcript events.")

(defconst consent-transcript-export-formats
  '(scheme-datum text-summary fixture-cases)
  "Supported transcript export view names.")

(defvar consent--transcript-next-id 0
  "Next transcript event sequence number.")

(defun consent-transcript--name (value)
  "Return VALUE as a plain symbolic name string, or nil."
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

(defun consent-transcript--symbol (name)
  "Return NAME as an Consent Scheme symbol datum."
  (consent--syntax-symbol
   (or (consent-transcript--name name)
       (format "%S" name))))

(defun consent-transcript--integer (value)
  "Return VALUE as an exact integer datum."
  (consent--make-canonical-integer value))

(defun consent-transcript--datumize (value)
  "Return VALUE converted to a Scheme-readable transcript datum."
  (cond
   ((or (eq value consent-true)
        (eq value consent-false)
        (consent-symbol-p value)
        (consent-character-p value)
        (consent-number-p value)
        (consent-bytevector-p value)
        (consent-record-p value)
        (consent-record-type-p value)
        (consent-handle-p value))
    value)
   ((eq value t)
    consent-true)
   ((null value)
    nil)
   ((symbolp value)
    (consent-transcript--symbol value))
   ((stringp value)
    value)
   ((integerp value)
    (consent-transcript--integer value))
   ((floatp value)
    (number-to-string value))
   ((vectorp value)
    (vconcat (mapcar #'consent-transcript--datumize
                     (append value nil))))
   ((consp value)
    (cons (consent-transcript--datumize (car value))
          (consent-transcript--datumize (cdr value))))
   (t
    (format "%S" value))))

(defun consent-transcript--field (name value)
  "Return a Scheme-readable transcript field named NAME with VALUE."
  (list (consent-transcript--symbol name)
        (consent-transcript--datumize value)))

(defun consent-transcript--field-raw-value (field)
  "Return FIELD's raw value from either field-list or alist spelling."
  (cond
   ((and (consp field)
         (consp (cdr field))
         (null (cddr field)))
    (cadr field))
   ((consp field)
    (cdr field))
   (t nil)))

(defun consent-transcript--field-value-from-fields
    (fields name &optional default)
  "Return field NAME from FIELDS, or DEFAULT when absent."
  (let ((target (consent-transcript--name name))
        (value default))
    (dolist (field fields value)
      (when (and (consp field)
                 (equal (consent-transcript--name (car field))
                        target))
        (setq value (consent-transcript--field-raw-value field))))))

;;;###autoload
(defun consent-transcript-field-value (datum name &optional default)
  "Return field NAME from transcript DATUM, or DEFAULT when absent."
  (consent-transcript--field-value-from-fields
   (cdr-safe datum) name default))

;;;###autoload
(defun consent-transcript-event-p (datum)
  "Return non-nil when DATUM is a transcript event."
  (and (consp datum)
       (equal (consent-transcript--name (car datum))
              "transcript-event")))

(defun consent-transcript--generated-id ()
  "Return a fresh transcript event id symbol."
  (consent-transcript--symbol
   (format "e-%d" (cl-incf consent--transcript-next-id))))

(defun consent-transcript--timestamp ()
  "Return the current public transcript timestamp string."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun consent-transcript--intern-name (value)
  "Return VALUE's symbolic name as an interned Emacs Lisp symbol."
  (when-let ((name (consent-transcript--name value)))
    (intern name)))

(defun consent-transcript--host-effect-kind-p (kind)
  "Return non-nil when KIND describes a non-replayable host effect."
  (memq kind
        '(approval-request approval-decision capability-call
          skill-discovery skill-activation skill-resource-access
          memory-write memory-summary model-route)))

(defun consent-transcript--replay-mode-from-record (record)
  "Return replay mode from RECORD, or nil when absent."
  (let ((mode
         (and (consp record)
              (consent-transcript--field-value-from-fields
               (cdr record) "mode"))))
    (consent-transcript--intern-name mode)))

(defun consent-transcript--classify-event (event)
  "Return replay mode for transcript EVENT."
  (or (consent-transcript--replay-mode-from-record
       (consent-transcript-field-value event "replay"))
      (let* ((kind (consent-transcript--intern-name
                    (consent-transcript-field-value event "kind")))
             (form (consent-transcript-field-value event "form"))
             (result (consent-transcript-field-value event "result"))
             (error (consent-transcript-field-value event "error"))
             (effect (consent-transcript-field-value event "effect"))
             (capability
              (consent-transcript-field-value event "capability")))
        (cond
         ((or effect capability
              (consent-transcript--host-effect-kind-p kind))
          'recorded-observation)
         ((and (eq kind 'eval-end) form result)
          'deterministic-pure)
         ((and (eq kind 'eval-error) form error)
          'fixture-generation)
         (t
          'audit-only)))))

(defun consent-transcript--replay-reason (mode)
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

(defun consent-transcript--replay-effect (mode)
  "Return the effect replay class for MODE."
  (pcase mode
    ('deterministic-pure 'pure-evaluation)
    ('fixture-generation 'pure-fixture)
    ('recorded-observation 'recorded-observation)
    (_ 'audit-only)))

(defun consent-transcript--replay-record (event explicit)
  "Return a replay field for EVENT, respecting EXPLICIT replay data."
  (if explicit
      (consent-transcript--datumize explicit)
    (let ((mode (consent-transcript--classify-event event)))
      (list
       (consent-transcript--symbol "replay")
       (consent-transcript--field "mode" mode)
       (consent-transcript--field
        "effect" (consent-transcript--replay-effect mode))
       (consent-transcript--field
        "reason" (consent-transcript--replay-reason mode))))))

(defun consent-transcript--reserved-field-p (field)
  "Return non-nil when FIELD is managed by transcript event creation."
  (member (consent-transcript--name (car-safe field))
          '("id" "session" "kind" "time" "replay")))

;;;###autoload
(cl-defun consent-transcript-event (kind fields
                                               &key id session time replay)
  "Return a redacted Scheme-readable transcript event.
KIND is a public transcript event kind.  FIELDS may be alist cells or
`(name value)' lists.  Missing ids and timestamps are supplied by the host."
  (let* ((event-id
          (or id
              (consent-transcript--field-value-from-fields fields "id")
              (consent-transcript--generated-id)))
         (event-session
          (or session
              (consent-transcript--field-value-from-fields
               fields "session")))
         (event-time
          (or time
              (consent-transcript--field-value-from-fields fields "time")
              (consent-transcript--timestamp)))
         (explicit-replay
          (or replay
              (consent-transcript--field-value-from-fields
               fields "replay")))
         (body-fields
          (cl-loop for field in fields
                   unless (consent-transcript--reserved-field-p field)
                   collect
                   (consent-transcript--field
                    (car field)
                    (consent-transcript--field-raw-value field))))
         (base
          (append
           (list (consent-transcript--symbol "transcript-event")
                 (consent-transcript--field "id" event-id))
           (when event-session
             (list (consent-transcript--field
                    "session" event-session)))
           (list (consent-transcript--field "kind" kind))
           body-fields
           (list (consent-transcript--field "time" event-time)))))
    (consent-redact
     (append base
             (list (consent-transcript--replay-record
                    base explicit-replay)))
     'transcript)))

;;;###autoload
(defun consent-transcript-event-replay-mode (event)
  "Return EVENT's replay mode as an Emacs Lisp symbol."
  (consent-transcript--classify-event event))

;;;###autoload
(defun consent-transcript-replayable-p (event)
  "Return non-nil when EVENT can drive deterministic replay or fixtures."
  (memq (consent-transcript-event-replay-mode event)
        '(deterministic-pure fixture-generation)))

;;;###autoload
(defun consent-transcript-recorded-observation-p (event)
  "Return non-nil when EVENT represents a recorded host observation."
  (eq (consent-transcript-event-replay-mode event)
      'recorded-observation))

(defun consent-transcript--summary-value (value)
  "Return a compact summary string for VALUE."
  (cond
   ((null value) "")
   ((stringp value) value)
   ((consent-symbol-p value) (consent-symbol-name value))
   ((symbolp value) (symbol-name value))
   (t (consent-result->external value))))

;;;###autoload
(defun consent-transcript-event-summary (event)
  "Return a human-readable one-line summary for EVENT."
  (let* ((id (consent-transcript--summary-value
              (consent-transcript-field-value event "id")))
         (kind (consent-transcript--summary-value
                (consent-transcript-field-value event "kind")))
         (session (consent-transcript--summary-value
                   (consent-transcript-field-value event "session")))
         (mode (consent-transcript-event-replay-mode event))
         (result (consent-transcript-field-value event "result"))
         (error (consent-transcript-field-value event "error"))
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
              base (consent-transcript--summary-value result)))
     (error
      (format "%s ! %s"
              base (consent-transcript--summary-value error)))
     (t base))))

;;;###autoload
(defun consent-transcript-raw-view (events)
  "Return EVENTS as raw Scheme-readable transcript datums."
  events)

;;;###autoload
(defun consent-transcript-summary-view (events)
  "Return human-readable summaries for transcript EVENTS."
  (mapcar #'consent-transcript-event-summary events))

(defun consent-transcript--fixture-id (id)
  "Return a generated fixture id symbol for transcript ID."
  (consent-transcript--symbol
   (format "transcript-%s"
           (consent-transcript--summary-value id))))

(defun consent-transcript--fixture-source (form)
  "Return FORM as a fixture source string."
  (if (stringp form)
      form
    (consent-result->external form)))

(defun consent-transcript--fixture-result (result)
  "Return RESULT as a fixture expected value string."
  (if (stringp result)
      result
    (consent-result->external result)))

;;;###autoload
(defun consent-transcript-event->fixture-case (event)
  "Return an Consent Scheme fixture case generated from EVENT, or nil."
  (let* ((mode (consent-transcript-event-replay-mode event))
         (id (consent-transcript-field-value event "id"))
         (form (consent-transcript-field-value event "form"))
         (result (consent-transcript-field-value event "result"))
         (error (consent-transcript-field-value event "error")))
    (cond
     ((and (eq mode 'deterministic-pure) form result)
      (list
       (consent-transcript--field
        "id" (consent-transcript--fixture-id id))
       (consent-transcript--field "kind" 'agent-specific)
       (consent-transcript--field "phase" 'eval)
       (consent-transcript--field "category" 'transcript-replay)
       (consent-transcript--field "section" "agent transcript")
       (consent-transcript--field "status" 'implemented)
       (consent-transcript--field "oracle" 'shared)
       (consent-transcript--field "options" nil)
       (consent-transcript--field
        "description"
        (format "Generated from transcript event %s."
                (consent-transcript--summary-value id)))
       (consent-transcript--field
        "source" (consent-transcript--fixture-source form))
       (list (consent-transcript--symbol "expect")
             (list (consent-transcript--symbol "value")
                   (consent-transcript--fixture-result result)))))
     ((and (eq mode 'fixture-generation) form error)
      (list
       (consent-transcript--field
        "id" (consent-transcript--fixture-id id))
       (consent-transcript--field "kind" 'agent-specific)
       (consent-transcript--field "phase" 'error)
       (consent-transcript--field "category" 'transcript-replay)
       (consent-transcript--field "section" "agent transcript")
       (consent-transcript--field "status" 'implemented)
       (consent-transcript--field "oracle" 'shared)
       (consent-transcript--field "options" nil)
       (consent-transcript--field
        "description"
        (format "Generated from transcript event %s."
                (consent-transcript--summary-value id)))
       (consent-transcript--field
        "source" (consent-transcript--fixture-source form))
       (list (consent-transcript--symbol "expect")
             (list (consent-transcript--symbol "error")))))
     (t nil))))

;;;###autoload
(defun consent-transcript-rotate (events &optional keep)
  "Return the newest KEEP transcript EVENTS from chronological EVENTS."
  (let* ((limit (or keep consent-transcript-maximum-events))
         (count (length events)))
    (cond
     ((not (and (integerp limit) (> limit 0))) events)
     ((<= count limit) events)
     (t (nthcdr (- count limit) events)))))

;;;###autoload
(defun consent-transcript-export (events format)
  "Return a transcript view for EVENTS in FORMAT."
  (pcase (consent-transcript--intern-name format)
    ('scheme-datum
     (consent-transcript-raw-view events))
    ('text-summary
     (consent-transcript-summary-view events))
    ('fixture-cases
     (delq nil (mapcar #'consent-transcript-event->fixture-case
                       events)))
    (_
     (signal 'consent-eval-error
             (list (format "unknown transcript export format: %S"
                           format))))))

;;;###autoload
(defun consent-transcript-clear! ()
  "Reset transient transcript counters used by tests."
  (setq consent--transcript-next-id 0)
  consent-unspecified)

(provide 'consent-transcript)

;;; consent-transcript.el ends here
