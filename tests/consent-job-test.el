;;; consent-job-test.el --- Job lifecycle tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for Consent Scheme eval jobs, streaming event observation,
;; cooperative cancellation, interrupts, and per-session locking.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-audit)
(require 'consent-eval)
(require 'consent-job)
(require 'consent-result)
(require 'consent-session)

(defun consent-job-test--external (datum)
  "Return DATUM as stable Scheme-readable text."
  (consent-result->external datum))

(defun consent-job-test--field (datum name)
  "Return field NAME from Scheme-readable DATUM."
  (cadr
   (seq-find
    (lambda (field)
      (and (consp field)
           (consent-symbol-p (car field))
           (equal (consent-symbol-name (car field)) name)))
    (cdr-safe datum))))

(defun consent-job-test--job-id (datum)
  "Return job id from DATUM."
  (consent-job-test--field datum "id"))

(defun consent-job-test--status (id)
  "Return job ID status as an Emacs Lisp symbol."
  (consent-job-status id))

(defun consent-job-test--wait-until (description predicate)
  "Wait up to thirty seconds for PREDICATE to return non-nil."
  (let ((deadline (+ (float-time) 30.0))
        result)
    (while (and (not result) (< (float-time) deadline))
      (setq result (funcall predicate))
      (unless result
        (if (fboundp 'thread-yield)
            (thread-yield)
          (sleep-for 0.01))))
    (unless result
      (ert-fail (format "timed out waiting for %s" description)))
    result))

(defun consent-job-test--reset ()
  "Reset job, session, and audit state for a focused lifecycle test."
  (consent-job-clear!)
  (consent-session-clear!)
  (consent-audit-clear))

(defun consent-job-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'consent-result->external
          (consent-audit-recent-entries)))

(defun consent-job-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (consent-job-test--audit-strings)))

(defun consent-job-test--ready-yields (id)
  "Return job ID yields once its ready yield is visible."
  (let ((yields (consent-job-yields id)))
    (and yields
         (string-match-p
          (regexp-quote "(yield (phase ready))")
          (consent-job-test--external
           (list (consent--syntax-symbol "events")
                 yields)))
         yields)))

(defconst consent-job-test--looping-source
  "(import (scheme base) (agent io))
   (agent-yield '(phase ready))
   (letrec ((loop (lambda () (loop))))
     (loop))"
  "Source for a job that yields once and then runs until stopped.")

(defconst consent-job-test--yielding-source
  "(import (scheme base) (agent io))
   (agent-yield '(phase ready))
   'done"
  "Source for a job that yields once and completes.")

(ert-deftest consent-job-test-start-streams-yields-and-completes ()
  "An eval job is inspectable while queued and retains streamed yields."
  (consent-job-test--reset)
  (consent-session-create! 'named '(:id "job-main"))
  (let* ((job (consent-job-start!
               "job-main"
               consent-job-test--yielding-source
               '(:max-steps 200000)))
         (id (consent-job-test--job-id job)))
    (unwind-protect
        (progn
          (should
           (string-match-p
            (regexp-quote "(can-cancel #t)")
            (consent-job-test--external job)))
          (consent-job-test--wait-until
           "job completion"
           (lambda ()
             (eq (consent-job-test--status id) 'completed)))
          (consent-job-test--wait-until
           "job yield"
           (lambda ()
             (consent-job-test--ready-yields id)))
          (should
           (string-match-p
            (regexp-quote "(status completed)")
            (consent-job-test--external (consent-job-ref id))))
          (should
           (consent-job-test--audit-entry-matching
            "(event job-lifecycle)"
            "(operation \"job-completed\")"
            "(job ")))
      (when (memq (consent-job-test--status id)
                  '(queued running yielding cancel-requested))
        (ignore-errors (consent-job-cancel! id))))))

(ert-deftest consent-job-test-locks-session-while-running ()
  "A session rejects a second eval job while one job owns its lock."
  (consent-job-test--reset)
  (consent-session-create! 'named '(:id "locked-main"))
  (let* ((job (consent-job-start!
               "locked-main"
               consent-job-test--looping-source
               '(:max-steps 200000)))
         (id (consent-job-test--job-id job)))
    (unwind-protect
        (progn
          (should-error
           (consent-job-start! "locked-main" "'second" nil)
           :type 'consent-job-error)
          (consent-job-cancel! id)
          (consent-job-test--wait-until
           "job cancellation"
           (lambda ()
             (eq (consent-job-test--status id) 'cancelled))))
      (when (memq (consent-job-test--status id)
                  '(queued running yielding cancel-requested))
        (ignore-errors (consent-job-cancel! id))))))

(ert-deftest consent-job-test-interrupt-records-failed-job ()
  "Interrupting a job records the reason and releases the session."
  (consent-job-test--reset)
  (consent-session-create! 'named '(:id "interrupt-main"))
  (let* ((job (consent-job-start!
               "interrupt-main"
               consent-job-test--looping-source
               '(:max-steps 200000)))
         (id (consent-job-test--job-id job)))
    (unwind-protect
        (progn
          (consent-job-interrupt! id 'debug-break)
          (consent-job-test--wait-until
           "job interrupt"
           (lambda ()
             (eq (consent-job-test--status id) 'failed)))
          (should
           (string-match-p
            "job interrupted: debug-break"
            (consent-job-test--external (consent-job-ref id))))
          (should
           (consent-job-test--audit-entry-matching
            "(event job-lifecycle)"
            "(operation \"job-interrupt!\")"
            "(reason debug-break)"))
          (let* ((after-job (consent-job-start!
                             "interrupt-main" "'after" nil))
                 (after-id (consent-job-test--job-id after-job)))
            (consent-job-test--wait-until
             "post-interrupt job completion"
             (lambda ()
               (eq (consent-job-test--status after-id) 'completed)))))
      (when (memq (consent-job-test--status id)
                  '(queued running yielding cancel-requested))
        (ignore-errors (consent-job-cancel! id))))))

(ert-deftest consent-job-test-scheme-primitives-start-and-inspect-job ()
  "Scheme code can start, inspect, list, and read status for jobs."
  (consent-job-test--reset)
  (consent-session-create! 'named '(:id "scheme-job-main"))
  (let* ((started
          (consent-eval-source
           "(import (scheme base) (agent job))
            (job-start! 'scheme-job-main \"'done\" '())"))
         (id (consent-job-test--job-id started)))
    (consent-job-test--wait-until
     "scheme job completion"
     (lambda ()
       (eq (consent-job-test--status id) 'completed)))
    (should
     (string-match-p
      (regexp-quote "(status completed)")
      (consent-job-test--external
       (consent-eval-source
        (format "(import (scheme base) (agent job))
                 (job-ref '%s)"
                (consent-symbol-name id))))))
    (should
     (string-match-p
      (regexp-quote "completed")
      (consent-result->external
       (consent-eval-source
        (format "(import (scheme base) (agent job))
                 (job-status '%s)"
                (consent-symbol-name id))))))
    (should
     (string-match-p
      (regexp-quote "(session scheme-job-main)")
      (consent-job-test--external
       (consent-eval-source
        "(import (scheme base) (agent job))
         (job-list 'scheme-job-main)"))))))

;;; consent-job-test.el ends here
