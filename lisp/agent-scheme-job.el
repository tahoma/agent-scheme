;;; agent-scheme-job.el --- Eval jobs, cancellation, and yields  -*- lexical-binding: t; -*-

;;; Commentary:

;; Agent Scheme jobs are host-managed work records exposed as Scheme-readable
;; datums.  This module owns background evaluation threads, cooperative
;; cancellation and interrupts, session locks, and the `(agent job)' primitive
;; bridge.  Raw thread objects and live contexts stay private to the Emacs
;; adapter.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'agent-scheme-audit)
(require 'agent-scheme-redaction)
(require 'agent-scheme-result)
(require 'agent-scheme-runtime)
(require 'agent-scheme-session)

(declare-function agent-scheme-session-eval-source "agent-scheme-eval")

(define-error 'agent-scheme-job-error
  "Agent Scheme job error"
  'agent-scheme-eval-error)

(cl-defstruct (agent-scheme-job
               (:conc-name agent-scheme-job--)
               (:constructor agent-scheme--make-job)
               (:copier nil))
  "Host-managed Agent Scheme job.
The public surface is `agent-scheme-job-datum'.  THREAD and CONTEXT are private
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

(defconst agent-scheme-job-states
  '(queued running yielding waiting-approval waiting-input cancel-requested
           cancelled completed failed)
  "Recognized Agent Scheme job states.")

(defvar agent-scheme--job-registry (make-hash-table :test #'equal)
  "Registry of known Agent Scheme jobs by string id.")

(defvar agent-scheme--next-job-number 0
  "Next numeric suffix used for generated job ids.")

(defun agent-scheme-job--symbol (name)
  "Return NAME as an Agent Scheme symbol datum."
  (agent-scheme--syntax-symbol
   (cond
    ((agent-scheme-symbol-p name)
     (agent-scheme-symbol-name name))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun agent-scheme-job--field (name value)
  "Return a Scheme-readable field named NAME with VALUE."
  (list (agent-scheme-job--symbol name) value))

(defun agent-scheme-job--name (value description)
  "Return VALUE as a stable string name for DESCRIPTION."
  (cond
   ((agent-scheme-symbol-p value)
    (agent-scheme-symbol-name value))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t
    (signal 'agent-scheme-job-error
            (list (format "%s must be a symbol or string" description))))))

(defun agent-scheme-job--generated-id ()
  "Return a fresh job id string."
  (format "j-%d" (cl-incf agent-scheme--next-job-number)))

(defun agent-scheme-job--timestamp ()
  "Return the current time as a public timestamp string."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun agent-scheme-job--integer (value)
  "Return VALUE as a Scheme exact integer datum."
  (agent-scheme--make-canonical-integer value))

(defun agent-scheme-job--integer-value (value description)
  "Return VALUE as an Emacs Lisp integer for DESCRIPTION."
  (cond
   ((integerp value)
    value)
   ((and (agent-scheme-number-p value)
         (eq (agent-scheme-number-kind value) 'integer)
         (eq (agent-scheme-number-exactness value) 'exact))
    (agent-scheme-number-value value))
   (t
    (signal 'agent-scheme-job-error
            (list (format "%s must be an exact integer" description))))))

(defun agent-scheme-job--option-key (key)
  "Return KEY normalized to an Emacs Lisp keyword."
  (intern
   (concat
    ":"
    (cond
     ((keywordp key)
      (substring (symbol-name key) 1))
     ((agent-scheme-symbol-p key)
      (agent-scheme-symbol-name key))
     ((symbolp key)
      (symbol-name key))
     ((stringp key)
      key)
     (t
      (format "%S" key))))))

(defun agent-scheme-job--primitive-options (options)
  "Return Scheme OPTIONS datum as an Emacs Lisp plist."
  (let (plist)
    (dolist (entry (agent-scheme--proper-list-elements options "job options")
                   plist)
      (let ((elements (agent-scheme--proper-list-elements-maybe entry)))
        (cond
         ((and elements (= (length elements) 2))
          (setq plist
                (plist-put plist
                           (agent-scheme-job--option-key (car elements))
                           (cadr elements))))
         ((consp entry)
          (setq plist
                (plist-put plist
                           (agent-scheme-job--option-key (car entry))
                           (cdr entry))))
         (t
          (signal 'agent-scheme-job-error
                  (list "job option entries must be pairs"))))))))

(defun agent-scheme-job--terminal-p (job)
  "Return non-nil if JOB has reached a terminal state."
  (memq (agent-scheme-job--status job) '(cancelled completed failed)))

(defun agent-scheme-job--require (id)
  "Return job ID or signal."
  (let* ((name (if (agent-scheme-job-p id)
                   (agent-scheme-job--id id)
                 (agent-scheme-job--name id "job id")))
         (job (gethash name agent-scheme--job-registry)))
    (unless job
      (signal 'agent-scheme-job-error
              (list (format "unknown job: %s" name))))
    job))

(defun agent-scheme-job--maybe (id)
  "Return job ID or nil."
  (gethash (agent-scheme-job--name id "job id") agent-scheme--job-registry))

(defun agent-scheme-job--budget-value (options key fallback)
  "Return integer budget OPTIONS value for KEY, falling back to FALLBACK."
  (if (plist-member options key)
      (agent-scheme-job--integer-value
       (plist-get options key)
       (format "job budget %s" key))
    fallback))

(defun agent-scheme-job--budget-from-context (context options)
  "Return a Scheme-readable budget datum for CONTEXT and OPTIONS."
  (list
   (agent-scheme-job--symbol "budget")
   (agent-scheme-job--field
    "max-steps"
    (agent-scheme-job--integer
     (if (plist-member options :max-steps)
         (agent-scheme-job--budget-value
          options :max-steps
          (agent-scheme--eval-context-maximum-steps context))
       (agent-scheme-job--budget-value
        options :max-non-tail-steps
        (agent-scheme--eval-context-maximum-steps context)))))
   (agent-scheme-job--field
    "max-host-callbacks"
    (agent-scheme-job--integer
     (agent-scheme-job--budget-value
      options
      :max-host-callbacks
      (agent-scheme--eval-context-maximum-host-callbacks context))))
   (agent-scheme-job--field
    "max-events"
    (agent-scheme-job--integer
     (agent-scheme-job--budget-value
      options
      :max-events
      (agent-scheme--eval-context-maximum-events context))))))

(defun agent-scheme-job--normalize-eval-options (options)
  "Return OPTIONS with Scheme numeric budget values converted for the host."
  (let ((normalized (copy-sequence options)))
    (dolist (key '(:max-steps :max-non-tail-steps :max-value-nodes
                   :max-host-callbacks :max-events :max-event-nodes)
                 normalized)
      (when (plist-member normalized key)
        (setq normalized
              (plist-put normalized
                         key
                         (agent-scheme-job--integer-value
                          (plist-get normalized key)
                          (format "job option %s" key))))))))

(defun agent-scheme-job--form-source (form)
  "Return FORM as source text for eval jobs."
  (if (stringp form)
      form
    (agent-scheme-value->external form)))

(defun agent-scheme-job--event-status (event)
  "Return a streaming status suggested by EVENT."
  (let ((name (and (consp event)
                   (agent-scheme-symbol-p (car event))
                   (agent-scheme-symbol-name (car event)))))
    (cond
     ((equal name "request")
      (let ((payload (cadr event)))
        (if (and (consp payload)
                 (agent-scheme-symbol-p (car payload))
                 (equal (agent-scheme-symbol-name (car payload))
                        "approval"))
            'waiting-approval
          'waiting-input)))
     ((member name '("yield" "progress" "warn" "log" "debugger"))
      'yielding)
     (t
      'running))))

(defun agent-scheme-job--capture-event (job event context)
  "Update JOB's stream fields for EVENT in CONTEXT."
  (setf (agent-scheme-job--yields job)
        (agent-scheme--context-events context))
  (unless (agent-scheme-job--terminal-p job)
    (setf (agent-scheme-job--status job)
          (agent-scheme-job--event-status event))))

(defun agent-scheme-job--audit (job operation decision &optional fields)
  "Record a job lifecycle audit entry for JOB."
  (agent-scheme-audit-record
   'job-lifecycle
   (append
    `((category . agent-job)
      (operation . ,operation)
      (job . ,(agent-scheme-job--symbol (agent-scheme-job--id job)))
      (session . ,(agent-scheme-job--symbol
                   (agent-scheme-job--session-id job)))
      (status . ,(agent-scheme-job--status job))
      (decision . ,decision))
    fields)))

(defun agent-scheme-job-datum (job)
  "Return JOB as a Scheme-readable datum."
  (append
   (list
    (agent-scheme-job--symbol "job")
    (agent-scheme-job--field
     "id" (agent-scheme-job--symbol (agent-scheme-job--id job)))
    (agent-scheme-job--field
     "session" (agent-scheme-job--symbol (agent-scheme-job--session-id job)))
    (agent-scheme-job--field
     "kind" (agent-scheme-job--symbol (agent-scheme-job--kind job)))
    (agent-scheme-job--field
     "status" (agent-scheme-job--symbol (agent-scheme-job--status job)))
    (agent-scheme-job--field
     "can-cancel"
     (if (agent-scheme-job--can-cancel job)
         agent-scheme-true
       agent-scheme-false))
    (agent-scheme-job--field "started-at" (agent-scheme-job--started-at job))
    (agent-scheme-job--budget job)
    (agent-scheme-job--field "yields" (agent-scheme-job--yields job)))
   (when (agent-scheme-job--completed-at job)
     (list (agent-scheme-job--field
            "completed-at" (agent-scheme-job--completed-at job))))
   (when (agent-scheme-job--result job)
     (list (agent-scheme-job--field "result" (agent-scheme-job--result job))))
   (when (agent-scheme-job--failure job)
     (list (agent-scheme-job--field "error" (agent-scheme-job--failure job))))))

(defun agent-scheme-job--set-running! (job)
  "Mark JOB running and audit the transition."
  (setf (agent-scheme-job--status job) 'running)
  (agent-scheme-job--audit job "job-running" 'started))

(defun agent-scheme-job--finish! (job status &optional value condition)
  "Finish JOB with STATUS and optional VALUE or CONDITION."
  (setf (agent-scheme-job--status job) status)
  (setf (agent-scheme-job--completed-at job) (agent-scheme-job--timestamp))
  (setf (agent-scheme-job--can-cancel job) nil)
  (when (agent-scheme-job--context job)
    (setf (agent-scheme-job--yields job)
          (agent-scheme--context-events (agent-scheme-job--context job))))
  (when (eq status 'completed)
    (setf (agent-scheme-job--result job)
          (agent-scheme-redact
           (agent-scheme-value->external value)
           'transcript)))
  (when condition
    (setf (agent-scheme-job--failure job)
          (agent-scheme-redact
           (error-message-string condition)
           'transcript)))
  (agent-scheme-job--audit
   job
   (pcase status
     ('completed "job-completed")
     ('cancelled "job-cancelled")
     (_ "job-failed"))
   status
   (append
    (when (eq status 'completed)
      `((result . ,(agent-scheme-job--result job))))
    (when condition
      `((error . ,(agent-scheme-job--failure job)))))))

(defun agent-scheme-job--run (job)
  "Run JOB in its background thread."
  (unless (agent-scheme-job--terminal-p job)
    (let* ((session (agent-scheme-session--require
                     (agent-scheme-job--session-id job)))
           (context (agent-scheme-session-context session))
           (job-id (agent-scheme-job--id job)))
      (setf (agent-scheme-job--context job) context)
      (setf (agent-scheme--eval-context-event-hook context)
            (lambda (event event-context)
              (agent-scheme-job--capture-event job event event-context)))
      (unwind-protect
          (let ((agent-scheme--session-current-job-id job-id))
            (condition-case condition
                (progn
                  (agent-scheme-job--set-running! job)
                  (when (agent-scheme-job--cancel-requested job)
                    (signal 'agent-scheme-cancelled-error
                            (list (format "job cancelled: %s" job-id))))
                  (when (agent-scheme-job--interrupt-reason job)
                    (signal
                     'agent-scheme-interrupt-error
                     (list
                      (format
                       "job interrupted: %s"
                       (agent-scheme--control-reason-string
                        (agent-scheme-job--interrupt-reason job))))))
                  (agent-scheme-job--finish!
                   job
                   'completed
                   (agent-scheme-session-eval-source
                    (agent-scheme-job--session-id job)
                    (agent-scheme-job--source job)
                    (agent-scheme-job--options job))))
              (agent-scheme-cancelled-error
               (agent-scheme-job--finish! job 'cancelled nil condition))
              (agent-scheme-interrupt-error
               (agent-scheme-job--finish! job 'failed nil condition))
              (error
               (agent-scheme-job--finish! job 'failed nil condition))))
        (agent-scheme-session--unlock! session job-id)
        (setf (agent-scheme--eval-context-event-hook context) nil)
        (setf (agent-scheme--eval-context-job-id context) nil)
        (setf (agent-scheme--eval-context-cancel-requested context) nil)
        (setf (agent-scheme--eval-context-interrupt-reason context) nil)))))

;;;###autoload
(defun agent-scheme-job-start! (session form &optional options)
  "Start evaluating FORM in SESSION and return the job datum.
FORM may be a source string or one Scheme datum.  OPTIONS is an evaluator plist
that may include budget keys such as `:max-steps'."
  (unless (fboundp 'make-thread)
    (signal 'agent-scheme-job-error
            (list "background jobs require Emacs thread support")))
  (condition-case condition
      (let* ((options (agent-scheme-job--normalize-eval-options options))
             (session-record (agent-scheme-session--require session))
             (session-id (agent-scheme-session-id session-record))
             (context (agent-scheme-session-context session-record))
             (id (agent-scheme-job--generated-id))
             (source (agent-scheme-job--form-source form))
             (job (agent-scheme--make-job
                   :id id
                   :session-id session-id
                   :kind 'eval
                   :status 'queued
                   :can-cancel t
                   :started-at (agent-scheme-job--timestamp)
                   :budget (agent-scheme-job--budget-from-context
                            context options)
                   :yields nil
                   :source source
                   :options options)))
        (agent-scheme-session--lock! session-record id)
        (puthash id job agent-scheme--job-registry)
        (agent-scheme-job--audit job "job-start!" 'queued)
        (setf (agent-scheme-job--thread job)
              (make-thread
               (lambda ()
                 (agent-scheme-job--run job))
               (format "agent-scheme-job-%s" id)))
        (agent-scheme-job-datum job))
    (agent-scheme-session-error
     (signal 'agent-scheme-job-error (cdr condition)))))

;;;###autoload
(defun agent-scheme-job-ref (id)
  "Return job ID datum, or nil when unknown."
  (when-let ((job (agent-scheme-job--maybe id)))
    (agent-scheme-job-datum job)))

;;;###autoload
(defun agent-scheme-job-list (&optional session)
  "Return known job datums, optionally filtered by SESSION."
  (let ((session-id (and session (agent-scheme-job--name session "session id")))
        jobs)
    (maphash
     (lambda (_id job)
       (when (or (not session-id)
                 (equal session-id (agent-scheme-job--session-id job)))
         (push job jobs)))
     agent-scheme--job-registry)
    (mapcar #'agent-scheme-job-datum
            (sort jobs
                  (lambda (left right)
                    (string< (agent-scheme-job--id left)
                             (agent-scheme-job--id right)))))))

;;;###autoload
(defun agent-scheme-job-status (id)
  "Return job ID status, or nil when unknown."
  (when-let ((job (agent-scheme-job--maybe id)))
    (agent-scheme-job--status job)))

(defun agent-scheme-job--request-stop! (job kind reason)
  "Request JOB stop using KIND and optional REASON."
  (unless (agent-scheme-job--terminal-p job)
    (setf (agent-scheme-job--can-cancel job) nil)
    (setf (agent-scheme-job--status job) 'cancel-requested)
    (pcase kind
      ('cancel
       (setf (agent-scheme-job--cancel-requested job) t)
       (when-let ((context (agent-scheme-job--context job)))
         (setf (agent-scheme--eval-context-cancel-requested context) t)))
      ('interrupt
       (setf (agent-scheme-job--interrupt-reason job) reason)
       (when-let ((context (agent-scheme-job--context job)))
         (setf (agent-scheme--eval-context-interrupt-reason context) reason)))))
  (agent-scheme-job-datum job))

;;;###autoload
(defun agent-scheme-job-cancel! (id)
  "Request cooperative cancellation of job ID and return its datum."
  (let ((job (agent-scheme-job--require id)))
    (if (eq (agent-scheme-job--status job) 'queued)
        (progn
          (setf (agent-scheme-job--cancel-requested job) t)
          (when-let ((session
                      (agent-scheme-session--maybe
                       (agent-scheme-job--session-id job))))
            (agent-scheme-session--unlock!
             session
             (agent-scheme-job--id job)))
          (agent-scheme-job--finish!
           job
           'cancelled
           nil
           (list 'agent-scheme-cancelled-error
                 (format "job cancelled: %s"
                         (agent-scheme-job--id job)))))
      (agent-scheme-job--request-stop! job 'cancel nil))
    (agent-scheme-job--audit job "job-cancel!" 'requested)
    (agent-scheme-job-datum job)))

;;;###autoload
(defun agent-scheme-job-interrupt! (id reason)
  "Request cooperative interrupt of job ID with REASON and return its datum."
  (let ((job (agent-scheme-job--require id)))
    (agent-scheme-job--request-stop! job 'interrupt reason)
    (agent-scheme-job--audit
     job
     "job-interrupt!"
     'requested
     `((reason . ,(agent-scheme-job--symbol reason))))
    (agent-scheme-job-datum job)))

;;;###autoload
(defun agent-scheme-job-yields (id &optional options)
  "Return streamed events for job ID.
OPTIONS may contain `:after' with the number of already-observed events."
  (let* ((job (agent-scheme-job--require id))
         (after (and (plist-member options :after)
                     (agent-scheme-job--integer-value
                      (plist-get options :after)
                      "job-yields :after")))
         (events (agent-scheme-job--yields job)))
    (if after
        (nthcdr (min after (length events)) events)
      events)))

;;;###autoload
(defun agent-scheme-job-clear! ()
  "Clear in-memory job records after requesting active job cancellation."
  (maphash
   (lambda (_id job)
     (unless (agent-scheme-job--terminal-p job)
       (ignore-errors
         (agent-scheme-job--request-stop! job 'cancel nil))))
   agent-scheme--job-registry)
  (clrhash agent-scheme--job-registry)
  (setq agent-scheme--next-job-number 0)
  agent-scheme-unspecified)

(defun agent-scheme-job--primitive-start (arguments _context)
  "Primitive job-start! over ARGUMENTS."
  (agent-scheme-job-start!
   (car arguments)
   (cadr arguments)
   (if (cddr arguments)
       (agent-scheme-job--primitive-options (caddr arguments))
     nil)))

(defun agent-scheme-job--primitive-ref (arguments _context)
  "Primitive job-ref over ARGUMENTS."
  (or (agent-scheme-job-ref (car arguments))
      agent-scheme-false))

(defun agent-scheme-job--primitive-list (arguments _context)
  "Primitive job-list over ARGUMENTS."
  (if arguments
      (agent-scheme-job-list (car arguments))
    (agent-scheme-job-list)))

(defun agent-scheme-job--primitive-cancel (arguments _context)
  "Primitive job-cancel! over ARGUMENTS."
  (agent-scheme-job-cancel! (car arguments)))

(defun agent-scheme-job--primitive-interrupt (arguments _context)
  "Primitive job-interrupt! over ARGUMENTS."
  (agent-scheme-job-interrupt! (car arguments) (cadr arguments)))

(defun agent-scheme-job--primitive-yields (arguments _context)
  "Primitive job-yields over ARGUMENTS."
  (agent-scheme-job-yields
   (car arguments)
   (if (cdr arguments)
       (agent-scheme-job--primitive-options (cadr arguments))
     nil)))

(defun agent-scheme-job--primitive-status (arguments _context)
  "Primitive job-status over ARGUMENTS."
  (if-let ((status (agent-scheme-job-status (car arguments))))
      (agent-scheme-job--symbol status)
    agent-scheme-false))

;;;###autoload
(defun agent-scheme-job-primitive-specs ()
  "Return primitive specs for the `(agent job)' library."
  `(("job-start!" ,#'agent-scheme-job--primitive-start 3 3)
    ("job-ref" ,#'agent-scheme-job--primitive-ref 1 1)
    ("job-list" ,#'agent-scheme-job--primitive-list 0 1)
    ("job-cancel!" ,#'agent-scheme-job--primitive-cancel 1 1)
    ("job-interrupt!" ,#'agent-scheme-job--primitive-interrupt 2 2)
    ("job-yields" ,#'agent-scheme-job--primitive-yields 1 2)
    ("job-status" ,#'agent-scheme-job--primitive-status 1 1)))

(provide 'agent-scheme-job)

;;; agent-scheme-job.el ends here
