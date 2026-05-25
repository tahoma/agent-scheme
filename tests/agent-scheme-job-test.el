;;; agent-scheme-job-test.el --- Job lifecycle tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for Agent Scheme eval jobs, streaming event observation,
;; cooperative cancellation, interrupts, and per-session locking.

;;; Code:

(require 'ert)
(require 'seq)
(require 'agent-scheme-audit)
(require 'agent-scheme-eval)
(require 'agent-scheme-job)
(require 'agent-scheme-result)
(require 'agent-scheme-session)

(defun agent-scheme-job-test--external (datum)
  "Return DATUM as stable Scheme-readable text."
  (agent-scheme-result->external datum))

(defun agent-scheme-job-test--field (datum name)
  "Return field NAME from Scheme-readable DATUM."
  (cadr
   (seq-find
    (lambda (field)
      (and (consp field)
           (agent-scheme-symbol-p (car field))
           (equal (agent-scheme-symbol-name (car field)) name)))
    (cdr-safe datum))))

(defun agent-scheme-job-test--job-id (datum)
  "Return job id from DATUM."
  (agent-scheme-job-test--field datum "id"))

(defun agent-scheme-job-test--status (id)
  "Return job ID status as an Emacs Lisp symbol."
  (agent-scheme-job-status id))

(defun agent-scheme-job-test--wait-until (description predicate)
  "Wait up to ten seconds for PREDICATE to return non-nil."
  (let ((deadline (+ (float-time) 10.0))
        result)
    (while (and (not result) (< (float-time) deadline))
      (setq result (funcall predicate))
      (unless result
        (when (fboundp 'thread-yield)
          (thread-yield))
        (sleep-for 0.01)))
    (unless result
      (ert-fail (format "timed out waiting for %s" description)))
    result))

(defun agent-scheme-job-test--reset ()
  "Reset job, session, and audit state for a focused lifecycle test."
  (agent-scheme-job-clear!)
  (agent-scheme-session-clear!)
  (agent-scheme-audit-clear))

(defun agent-scheme-job-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'agent-scheme-result->external
          (agent-scheme-audit-recent-entries)))

(defun agent-scheme-job-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (agent-scheme-job-test--audit-strings)))

(defun agent-scheme-job-test--ready-yields (id)
  "Return job ID yields once its ready yield is visible."
  (let ((yields (agent-scheme-job-yields id)))
    (and yields
         (string-match-p
          (regexp-quote "(yield (phase ready))")
          (agent-scheme-job-test--external
           (list (agent-scheme--syntax-symbol "events")
                 yields)))
         yields)))

(defconst agent-scheme-job-test--looping-source
  "(import (scheme base) (agent io))
   (agent-yield '(phase ready))
   (letrec ((loop (lambda () (loop))))
     (loop))"
  "Source for a job that yields once and then runs until stopped.")

(ert-deftest agent-scheme-job-test-start-streams-yields-and-cancels ()
  "A long-running eval is inspectable, streamable, and cancellable."
  (agent-scheme-job-test--reset)
  (agent-scheme-session-create! 'named '(:id "job-main"))
  (let* ((job (agent-scheme-job-start!
               "job-main"
               agent-scheme-job-test--looping-source
               '(:max-steps 200000)))
         (id (agent-scheme-job-test--job-id job)))
    (unwind-protect
        (progn
          (agent-scheme-job-test--wait-until
           "job yield"
           (lambda ()
             (agent-scheme-job-test--ready-yields id)))
          (should (memq (agent-scheme-job-test--status id)
                        '(running yielding)))
          (should
           (string-match-p
            (regexp-quote "(can-cancel #t)")
            (agent-scheme-job-test--external (agent-scheme-job-ref id))))
          (agent-scheme-job-cancel! id)
          (agent-scheme-job-test--wait-until
           "job cancellation"
           (lambda ()
             (eq (agent-scheme-job-test--status id) 'cancelled)))
          (should
           (string-match-p
            (regexp-quote "(status cancelled)")
            (agent-scheme-job-test--external (agent-scheme-job-ref id))))
          (should
           (agent-scheme-job-test--audit-entry-matching
            "(event job-lifecycle)"
            "(operation \"job-cancelled\")"
            "(job ")))
      (when (memq (agent-scheme-job-test--status id)
                  '(queued running yielding cancel-requested))
        (ignore-errors (agent-scheme-job-cancel! id))))))

(ert-deftest agent-scheme-job-test-locks-session-while-running ()
  "A session rejects a second eval job while one job owns its lock."
  (agent-scheme-job-test--reset)
  (agent-scheme-session-create! 'named '(:id "locked-main"))
  (let* ((job (agent-scheme-job-start!
               "locked-main"
               agent-scheme-job-test--looping-source
               '(:max-steps 200000)))
         (id (agent-scheme-job-test--job-id job)))
    (unwind-protect
        (progn
          (should-error
           (agent-scheme-job-start! "locked-main" "'second" nil)
           :type 'agent-scheme-job-error)
          (agent-scheme-job-cancel! id)
          (agent-scheme-job-test--wait-until
           "job cancellation"
           (lambda ()
             (eq (agent-scheme-job-test--status id) 'cancelled))))
      (when (memq (agent-scheme-job-test--status id)
                  '(queued running yielding cancel-requested))
        (ignore-errors (agent-scheme-job-cancel! id))))))

(ert-deftest agent-scheme-job-test-interrupt-records-failed-job ()
  "Interrupting a running job records the reason and releases the session."
  (agent-scheme-job-test--reset)
  (agent-scheme-session-create! 'named '(:id "interrupt-main"))
  (let* ((job (agent-scheme-job-start!
               "interrupt-main"
               agent-scheme-job-test--looping-source
               '(:max-steps 200000)))
         (id (agent-scheme-job-test--job-id job)))
    (unwind-protect
        (progn
          (agent-scheme-job-test--wait-until
           "job yield"
           (lambda ()
             (agent-scheme-job-test--ready-yields id)))
          (agent-scheme-job-interrupt! id 'debug-break)
          (agent-scheme-job-test--wait-until
           "job interrupt"
           (lambda ()
             (eq (agent-scheme-job-test--status id) 'failed)))
          (should
           (string-match-p
            "job interrupted: debug-break"
            (agent-scheme-job-test--external (agent-scheme-job-ref id))))
          (should
           (agent-scheme-job-test--audit-entry-matching
            "(event job-lifecycle)"
            "(operation \"job-interrupt!\")"
            "(reason debug-break)"))
          (let* ((after-job (agent-scheme-job-start!
                             "interrupt-main" "'after" nil))
                 (after-id (agent-scheme-job-test--job-id after-job)))
            (agent-scheme-job-test--wait-until
             "post-interrupt job completion"
             (lambda ()
               (eq (agent-scheme-job-test--status after-id) 'completed)))))
      (when (memq (agent-scheme-job-test--status id)
                  '(queued running yielding cancel-requested))
        (ignore-errors (agent-scheme-job-cancel! id))))))

(ert-deftest agent-scheme-job-test-scheme-primitives-start-and-inspect-job ()
  "Scheme code can start, inspect, list, and read status for jobs."
  (agent-scheme-job-test--reset)
  (agent-scheme-session-create! 'named '(:id "scheme-job-main"))
  (let* ((started
          (agent-scheme-eval-source
           "(import (scheme base) (agent job))
            (job-start! 'scheme-job-main \"'done\" '())"))
         (id (agent-scheme-job-test--job-id started)))
    (agent-scheme-job-test--wait-until
     "scheme job completion"
     (lambda ()
       (eq (agent-scheme-job-test--status id) 'completed)))
    (should
     (string-match-p
      (regexp-quote "(status completed)")
      (agent-scheme-job-test--external
       (agent-scheme-eval-source
        (format "(import (scheme base) (agent job))
                 (job-ref '%s)"
                (agent-scheme-symbol-name id))))))
    (should
     (string-match-p
      (regexp-quote "completed")
      (agent-scheme-result->external
       (agent-scheme-eval-source
        (format "(import (scheme base) (agent job))
                 (job-status '%s)"
                (agent-scheme-symbol-name id))))))
    (should
     (string-match-p
      (regexp-quote "(session scheme-job-main)")
      (agent-scheme-job-test--external
       (agent-scheme-eval-source
        "(import (scheme base) (agent job))
         (job-list 'scheme-job-main)"))))))

;;; agent-scheme-job-test.el ends here
