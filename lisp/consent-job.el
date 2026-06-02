;;; consent-job.el --- Eval jobs, cancellation, and yields  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Consent Scheme jobs are host-managed work records exposed as Scheme-readable
;; datums.  This module owns background evaluation threads, cooperative
;; cancellation and interrupts, session locks, and the `(agent job)' primitive
;; bridge.  Raw thread objects and live contexts stay private to the Emacs
;; adapter.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'consent-audit)
(require 'consent-redaction)
(require 'consent-result)
(require 'consent-runtime)
(require 'consent-session)

(declare-function consent-session-eval-source "consent-eval")

(define-error 'consent-job-error
  "Consent Scheme job error"
  'consent-eval-error)

(cl-defstruct (consent-job
               (:conc-name consent-job--)
               (:constructor consent--make-job)
               (:copier nil))
  "Host-managed Consent Scheme job.
The public surface is `consent-job-datum'.  THREAD and CONTEXT are private
host state used to run and stop the job without exposing raw Emacs objects to
Scheme code."
  id
  session-id
  kind
  status
  can-cancel
  started-at
  completed-at
  budget
  yields
  result
  failure
  source
  options
  thread
  context
  cancel-requested
  interrupt-reason)

(defconst consent-job-states
  '(queued running yielding waiting-approval waiting-input cancel-requested
           cancelled completed failed)
  "Recognized Consent Scheme job states.")

(defvar consent--job-registry (make-hash-table :test #'equal)
  "Registry of known Consent Scheme jobs by string id.")

(defvar consent--next-job-number 0
  "Next numeric suffix used for generated job ids.")

(defun consent-job--symbol (name)
  "Return NAME as an Consent Scheme symbol datum."
  (consent--syntax-symbol
   (cond
    ((consent-symbol-p name)
     (consent-symbol-name name))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun consent-job--field (name value)
  "Return a Scheme-readable field named NAME with VALUE."
  (list (consent-job--symbol name) value))

(defun consent-job--name (value description)
  "Return VALUE as a stable string name for DESCRIPTION."
  (cond
   ((consent-symbol-p value)
    (consent-symbol-name value))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t
    (signal 'consent-job-error
            (list (format "%s must be a symbol or string" description))))))

(defun consent-job--generated-id ()
  "Return a fresh job id string."
  (format "j-%d" (cl-incf consent--next-job-number)))

(defun consent-job--timestamp ()
  "Return the current time as a public timestamp string."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun consent-job--integer (value)
  "Return VALUE as a Scheme exact integer datum."
  (consent--make-canonical-integer value))

(defun consent-job--integer-value (value description)
  "Return VALUE as an Emacs Lisp integer for DESCRIPTION."
  (cond
   ((integerp value)
    value)
   ((and (consent-number-p value)
         (eq (consent-number-kind value) 'integer)
         (eq (consent-number-exactness value) 'exact))
    (consent-number-value value))
   (t
    (signal 'consent-job-error
            (list (format "%s must be an exact integer" description))))))

(defun consent-job--option-key (key)
  "Return KEY normalized to an Emacs Lisp keyword."
  (intern
   (concat
    ":"
    (cond
     ((keywordp key)
      (substring (symbol-name key) 1))
     ((consent-symbol-p key)
      (consent-symbol-name key))
     ((symbolp key)
      (symbol-name key))
     ((stringp key)
      key)
     (t
      (format "%S" key))))))

(defun consent-job--primitive-options (options)
  "Return Scheme OPTIONS datum as an Emacs Lisp plist."
  (let (plist)
    (dolist (entry (consent--proper-list-elements options "job options")
                   plist)
      (let ((elements (consent--proper-list-elements-maybe entry)))
        (cond
         ((and elements (= (length elements) 2))
          (setq plist
                (plist-put plist
                           (consent-job--option-key (car elements))
                           (cadr elements))))
         ((consp entry)
          (setq plist
                (plist-put plist
                           (consent-job--option-key (car entry))
                           (cdr entry))))
         (t
          (signal 'consent-job-error
                  (list "job option entries must be pairs"))))))))

(defun consent-job--terminal-p (job)
  "Return non-nil if JOB has reached a terminal state."
  (memq (consent-job--status job) '(cancelled completed failed)))

(defun consent-job--require (id)
  "Return job ID or signal."
  (let* ((name (if (consent-job-p id)
                   (consent-job--id id)
                 (consent-job--name id "job id")))
         (job (gethash name consent--job-registry)))
    (unless job
      (signal 'consent-job-error
              (list (format "unknown job: %s" name))))
    job))

(defun consent-job--maybe (id)
  "Return job ID or nil."
  (gethash (consent-job--name id "job id") consent--job-registry))

(defun consent-job--budget-value (options key fallback)
  "Return integer budget OPTIONS value for KEY, falling back to FALLBACK."
  (if (plist-member options key)
      (consent-job--integer-value
       (plist-get options key)
       (format "job budget %s" key))
    fallback))

(defun consent-job--budget-from-context (context options)
  "Return a Scheme-readable budget datum for CONTEXT and OPTIONS."
  (list
   (consent-job--symbol "budget")
   (consent-job--field
    "max-steps"
    (consent-job--integer
     (if (plist-member options :max-steps)
         (consent-job--budget-value
          options :max-steps
          (consent--eval-context-maximum-steps context))
       (consent-job--budget-value
        options :max-non-tail-steps
        (consent--eval-context-maximum-steps context)))))
   (consent-job--field
    "max-host-callbacks"
    (consent-job--integer
     (consent-job--budget-value
      options
      :max-host-callbacks
      (consent--eval-context-maximum-host-callbacks context))))
   (consent-job--field
    "max-events"
    (consent-job--integer
     (consent-job--budget-value
      options
      :max-events
      (consent--eval-context-maximum-events context))))))

(defun consent-job--normalize-eval-options (options)
  "Return OPTIONS with Scheme numeric budget values converted for the host."
  (let ((normalized (copy-sequence options)))
    (dolist (key '(:max-steps :max-non-tail-steps :max-value-nodes
                   :max-host-callbacks :max-events :max-event-nodes)
                 normalized)
      (when (plist-member normalized key)
        (setq normalized
              (plist-put normalized
                         key
                         (consent-job--integer-value
                          (plist-get normalized key)
                          (format "job option %s" key))))))))

(defun consent-job--form-source (form)
  "Return FORM as source text for eval jobs."
  (if (stringp form)
      form
    (consent-value->external form)))

(defun consent-job--event-status (event)
  "Return a streaming status suggested by EVENT."
  (let ((name (and (consp event)
                   (consent-symbol-p (car event))
                   (consent-symbol-name (car event)))))
    (cond
     ((equal name "request")
      (let ((payload (cadr event)))
        (if (and (consp payload)
                 (consent-symbol-p (car payload))
                 (equal (consent-symbol-name (car payload))
                        "approval"))
            'waiting-approval
          'waiting-input)))
     ((member name '("yield" "progress" "warn" "log" "debugger"))
      'yielding)
     (t
      'running))))

(defun consent-job--capture-event (job event context)
  "Update JOB's stream fields for EVENT in CONTEXT."
  (setf (consent-job--yields job)
        (consent--context-events context))
  (unless (consent-job--terminal-p job)
    (setf (consent-job--status job)
          (consent-job--event-status event))))

(defun consent-job--audit (job operation decision &optional fields)
  "Record a job lifecycle audit entry for JOB."
  (consent-audit-record
   'job-lifecycle
   (append
    `((category . agent-job)
      (operation . ,operation)
      (job . ,(consent-job--symbol (consent-job--id job)))
      (session . ,(consent-job--symbol
                   (consent-job--session-id job)))
      (status . ,(consent-job--status job))
      (decision . ,decision))
    fields)))

(defun consent-job-datum (job)
  "Return JOB as a Scheme-readable datum."
  (append
   (list
    (consent-job--symbol "job")
    (consent-job--field
     "id" (consent-job--symbol (consent-job--id job)))
    (consent-job--field
     "session" (consent-job--symbol (consent-job--session-id job)))
    (consent-job--field
     "kind" (consent-job--symbol (consent-job--kind job)))
    (consent-job--field
     "status" (consent-job--symbol (consent-job--status job)))
    (consent-job--field
     "can-cancel"
     (if (consent-job--can-cancel job)
         consent-true
       consent-false))
    (consent-job--field "started-at" (consent-job--started-at job))
    (consent-job--budget job)
    (consent-job--field "yields" (consent-job--yields job)))
   (when (consent-job--completed-at job)
     (list (consent-job--field
            "completed-at" (consent-job--completed-at job))))
   (when (consent-job--result job)
     (list (consent-job--field "result" (consent-job--result job))))
   (when (consent-job--failure job)
     (list (consent-job--field "error" (consent-job--failure job))))))

(defun consent-job--set-running! (job)
  "Mark JOB running and audit the transition."
  (setf (consent-job--status job) 'running)
  (consent-job--audit job "job-running" 'started))

(defun consent-job--finish! (job status &optional value condition)
  "Finish JOB with STATUS and optional VALUE or CONDITION."
  (setf (consent-job--status job) status)
  (setf (consent-job--completed-at job) (consent-job--timestamp))
  (setf (consent-job--can-cancel job) nil)
  (when (consent-job--context job)
    (setf (consent-job--yields job)
          (consent--context-events (consent-job--context job))))
  (when (eq status 'completed)
    (setf (consent-job--result job)
          (consent-redact
           (consent-value->external value)
           'transcript)))
  (when condition
    (setf (consent-job--failure job)
          (consent-redact
           (error-message-string condition)
           'transcript)))
  (consent-job--audit
   job
   (pcase status
     ('completed "job-completed")
     ('cancelled "job-cancelled")
     (_ "job-failed"))
   status
   (append
    (when (eq status 'completed)
      `((result . ,(consent-job--result job))))
    (when condition
      `((error . ,(consent-job--failure job)))))))

(defun consent-job--run (job)
  "Run JOB in its background thread."
  (unless (consent-job--terminal-p job)
    (let* ((session (consent-session--require
                     (consent-job--session-id job)))
           (context (consent-session-context session))
           (job-id (consent-job--id job)))
      (setf (consent-job--context job) context)
      (setf (consent--eval-context-event-hook context)
            (lambda (event event-context)
              (consent-job--capture-event job event event-context)))
      (unwind-protect
          (let ((consent--session-current-job-id job-id))
            (condition-case condition
                (progn
                  (consent-job--set-running! job)
                  (when (consent-job--cancel-requested job)
                    (signal 'consent-cancelled-error
                            (list (format "job cancelled: %s" job-id))))
                  (when (consent-job--interrupt-reason job)
                    (signal
                     'consent-interrupt-error
                     (list
                      (format
                       "job interrupted: %s"
                       (consent--control-reason-string
                        (consent-job--interrupt-reason job))))))
                  (consent-job--finish!
                   job
                   'completed
                   (consent-session-eval-source
                    (consent-job--session-id job)
                    (consent-job--source job)
                    (consent-job--options job))))
              (consent-cancelled-error
               (consent-job--finish! job 'cancelled nil condition))
              (consent-interrupt-error
               (consent-job--finish! job 'failed nil condition))
              (error
               (consent-job--finish! job 'failed nil condition))))
        (consent-session--unlock! session job-id)
        (setf (consent--eval-context-event-hook context) nil)
        (setf (consent--eval-context-job-id context) nil)
        (setf (consent--eval-context-cancel-requested context) nil)
        (setf (consent--eval-context-interrupt-reason context) nil)))))

;;;###autoload
(defun consent-job-start! (session form &optional options)
  "Start evaluating FORM in SESSION and return the job datum.
FORM may be a source string or one Scheme datum.  OPTIONS is an evaluator plist
that may include budget keys such as `:max-steps'."
  (unless (fboundp 'make-thread)
    (signal 'consent-job-error
            (list "background jobs require Emacs thread support")))
  (condition-case condition
      (let* ((options (consent-job--normalize-eval-options options))
             (session-record (consent-session--require session))
             (session-id (consent-session-id session-record))
             (context (consent-session-context session-record))
             (id (consent-job--generated-id))
             (source (consent-job--form-source form))
             (job (consent--make-job
                   :id id
                   :session-id session-id
                   :kind 'eval
                   :status 'queued
                   :can-cancel t
                   :started-at (consent-job--timestamp)
                   :budget (consent-job--budget-from-context
                            context options)
                   :yields nil
                   :source source
                   :options options)))
        (consent-session--lock! session-record id)
        (puthash id job consent--job-registry)
        (consent-job--audit job "job-start!" 'queued)
        (setf (consent-job--thread job)
              (make-thread
               (lambda ()
                 (consent-job--run job))
               (format "consent-job-%s" id)))
        (consent-job-datum job))
    (consent-session-error
     (signal 'consent-job-error (cdr condition)))))

;;;###autoload
(defun consent-job-ref (id)
  "Return job ID datum, or nil when unknown."
  (when-let ((job (consent-job--maybe id)))
    (consent-job-datum job)))

;;;###autoload
(defun consent-job-list (&optional session)
  "Return known job datums, optionally filtered by SESSION."
  (let ((session-id (and session (consent-job--name session "session id")))
        jobs)
    (maphash
     (lambda (_id job)
       (when (or (not session-id)
                 (equal session-id (consent-job--session-id job)))
         (push job jobs)))
     consent--job-registry)
    (mapcar #'consent-job-datum
            (sort jobs
                  (lambda (left right)
                    (string< (consent-job--id left)
                             (consent-job--id right)))))))

;;;###autoload
(defun consent-job-status (id)
  "Return job ID status, or nil when unknown."
  (when-let ((job (consent-job--maybe id)))
    (consent-job--status job)))

(defun consent-job--request-stop! (job kind reason)
  "Request JOB stop using KIND and optional REASON."
  (unless (consent-job--terminal-p job)
    (setf (consent-job--can-cancel job) nil)
    (setf (consent-job--status job) 'cancel-requested)
    (pcase kind
      ('cancel
       (setf (consent-job--cancel-requested job) t)
       (when-let ((context (consent-job--context job)))
         (setf (consent--eval-context-cancel-requested context) t)))
      ('interrupt
       (setf (consent-job--interrupt-reason job) reason)
       (when-let ((context (consent-job--context job)))
         (setf (consent--eval-context-interrupt-reason context) reason)))))
  (consent-job-datum job))

;;;###autoload
(defun consent-job-cancel! (id)
  "Request cooperative cancellation of job ID and return its datum."
  (let ((job (consent-job--require id)))
    (if (eq (consent-job--status job) 'queued)
        (progn
          (setf (consent-job--cancel-requested job) t)
          (when-let ((session
                      (consent-session--maybe
                       (consent-job--session-id job))))
            (consent-session--unlock!
             session
             (consent-job--id job)))
          (consent-job--finish!
           job
           'cancelled
           nil
           (list 'consent-cancelled-error
                 (format "job cancelled: %s"
                         (consent-job--id job)))))
      (consent-job--request-stop! job 'cancel nil))
    (consent-job--audit job "job-cancel!" 'requested)
    (consent-job-datum job)))

;;;###autoload
(defun consent-job-interrupt! (id reason)
  "Request cooperative interrupt of job ID with REASON and return its datum."
  (let ((job (consent-job--require id)))
    (consent-job--request-stop! job 'interrupt reason)
    (consent-job--audit
     job
     "job-interrupt!"
     'requested
     `((reason . ,(consent-job--symbol reason))))
    (consent-job-datum job)))

;;;###autoload
(defun consent-job-yields (id &optional options)
  "Return streamed events for job ID.
OPTIONS may contain `:after' with the number of already-observed events."
  (let* ((job (consent-job--require id))
         (after (and (plist-member options :after)
                     (consent-job--integer-value
                      (plist-get options :after)
                      "job-yields :after")))
         (events (consent-job--yields job)))
    (if after
        (nthcdr (min after (length events)) events)
      events)))

;;;###autoload
(defun consent-job-clear! ()
  "Clear in-memory job records after requesting active job cancellation."
  (maphash
   (lambda (_id job)
     (unless (consent-job--terminal-p job)
       (ignore-errors
         (consent-job--request-stop! job 'cancel nil))))
   consent--job-registry)
  (clrhash consent--job-registry)
  (setq consent--next-job-number 0)
  consent-unspecified)

(defun consent-job--primitive-start (arguments _context)
  "Primitive job-start! over ARGUMENTS."
  (consent-job-start!
   (car arguments)
   (cadr arguments)
   (if (cddr arguments)
       (consent-job--primitive-options (caddr arguments))
     nil)))

(defun consent-job--primitive-ref (arguments _context)
  "Primitive job-ref over ARGUMENTS."
  (or (consent-job-ref (car arguments))
      consent-false))

(defun consent-job--primitive-list (arguments _context)
  "Primitive job-list over ARGUMENTS."
  (if arguments
      (consent-job-list (car arguments))
    (consent-job-list)))

(defun consent-job--primitive-cancel (arguments _context)
  "Primitive job-cancel! over ARGUMENTS."
  (consent-job-cancel! (car arguments)))

(defun consent-job--primitive-interrupt (arguments _context)
  "Primitive job-interrupt! over ARGUMENTS."
  (consent-job-interrupt! (car arguments) (cadr arguments)))

(defun consent-job--primitive-yields (arguments _context)
  "Primitive job-yields over ARGUMENTS."
  (consent-job-yields
   (car arguments)
   (if (cdr arguments)
       (consent-job--primitive-options (cadr arguments))
     nil)))

(defun consent-job--primitive-status (arguments _context)
  "Primitive job-status over ARGUMENTS."
  (if-let ((status (consent-job-status (car arguments))))
      (consent-job--symbol status)
    consent-false))

;;;###autoload
(defun consent-job-primitive-specs ()
  "Return primitive specs for the `(agent job)' library."
  `(("job-start!" ,#'consent-job--primitive-start 3 3)
    ("job-ref" ,#'consent-job--primitive-ref 1 1)
    ("job-list" ,#'consent-job--primitive-list 0 1)
    ("job-cancel!" ,#'consent-job--primitive-cancel 1 1)
    ("job-interrupt!" ,#'consent-job--primitive-interrupt 2 2)
    ("job-yields" ,#'consent-job--primitive-yields 1 2)
    ("job-status" ,#'consent-job--primitive-status 1 1)))

(provide 'consent-job)

;;; consent-job.el ends here
