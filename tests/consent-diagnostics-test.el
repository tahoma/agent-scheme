;;; consent-diagnostics-test.el --- Diagnostic datum and adapter tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the host-neutral `(agent diagnostics)' datum library
;; and the Emacs `(emacs diagnostics)' adapter that produces those datums from
;; current diagnostic backends.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-audit)
(require 'consent-capability)
(require 'consent-eval)
(require 'consent-result)

(defun consent-diagnostics-test--external (source)
  "Evaluate SOURCE and return its stable external value representation."
  (consent-value->external
   (consent-eval-source source)))

(defun consent-diagnostics-test--result-external (source)
  "Evaluate SOURCE and return its stable evaluation-result text."
  (consent-result->external
   (consent-eval-source-result source)))

(defun consent-diagnostics-test--contains-p (text needle)
  "Return non-nil when TEXT contains NEEDLE."
  (string-match-p (regexp-quote needle) text))

(defun consent-diagnostics-test--manifest-spec (library name)
  "Return Emacs capability metadata for binding NAME in LIBRARY."
  (seq-find
   (lambda (spec)
     (and (equal (plist-get spec :library) library)
          (equal (plist-get spec :name) name)))
   (consent-emacs-capability-binding-specs)))

(defun consent-diagnostics-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'consent-result->external
          (consent-audit-recent-entries)))

(defun consent-diagnostics-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (consent-diagnostics-test--audit-strings)))

(ert-deftest consent-diagnostics-test-agent-diagnostics-constructs-records ()
  "The portable `(agent diagnostics)' library constructs diagnostic datums."
  (should
   (equal
    (consent-diagnostics-test--external
     "(import (scheme base) (agent diagnostics))
      (define range (make-diagnostic-range 3 9 1 3 1 9))
      (define diagnostic
        (make-diagnostic
         'error
         \"Unbound identifier\"
         'flymake
         \"src/main.scm\"
         \"main.scm\"
         range
         '((code \"E1\"))))
      (define snapshot
        (make-diagnostics-snapshot
         'ok
         'buffer
         \"main.scm\"
         \"src/main.scm\"
         (list diagnostic)
         '()))
      (list
       (diagnostic? diagnostic)
       (diagnostics-snapshot? snapshot)
       (diagnostic-severity diagnostic)
       (diagnostic-message diagnostic)
       (diagnostic-range diagnostic)
       (diagnostics-snapshot-status snapshot)
       (length (diagnostics-snapshot-diagnostics snapshot)))")
    "(#t #t error \"Unbound identifier\" (diagnostic-range (start 3) (end 9) (line 1) (column 3) (end-line 1) (end-column 9)) ok 1)")))

(ert-deftest consent-diagnostics-test-agent-diagnostics-yields-events ()
  "Portable diagnostic snapshots can be yielded as Scheme-readable event data."
  (consent-audit-clear)
  (let ((result
         (consent-diagnostics-test--result-external
          "(import (scheme base) (agent diagnostics))
           (diagnostics-yield
            (make-diagnostics-snapshot
             'ok
             'buffer
             \"main.scm\"
             \"src/main.scm\"
             (list
              (make-diagnostic
               'warning
               \"Unused binding\"
               'mock-lsp
               \"src/main.scm\"
               \"main.scm\"
               (make-diagnostic-range 12 17 2 1 2 6)
               '()))
             '()))
           'ok")))
    (should (consent-diagnostics-test--contains-p result "(status ok)"))
    (should
     (consent-diagnostics-test--contains-p
      result
      "(events ((yield (diagnostics-snapshot"))
    (should
     (consent-diagnostics-test--contains-p
      result
      "(message \"Unused binding\")"))))

(ert-deftest consent-diagnostics-test-request-result-datums-are-host-neutral ()
  "Diagnostic request and result datums describe any host adapter."
  (should
   (equal
    (consent-diagnostics-test--external
     "(import (scheme base) (agent diagnostics))
      (define request
        (make-diagnostics-capability-request
         'req-1
         'buffer-diagnostics
         'read-only-observation
         '((buffer h-1))))
      (define result
        (make-diagnostics-capability-result
         'req-1
         'ok
         (make-diagnostics-snapshot
          'ok
          'buffer
          \"main.scm\"
          \"src/main.scm\"
          '()
          '())))
      (define unavailable
        (make-diagnostics-outcome
         'unavailable
         \"No diagnostic backend is active.\"))
      (list
       (diagnostics-read-only-operation? 'buffer-diagnostics)
       (diagnostics-read-only-operation? 'apply-code-action)
       (diagnostics-capability-request? request)
       (diagnostics-field-value request 'operation #f)
       (diagnostics-field-value request 'required-authority #f)
       (diagnostics-field-value result 'status #f)
       (diagnostics-snapshot-status
        (diagnostics-field-value result 'value #f))
       (diagnostics-outcome-status unavailable))")
    "(#t #f #t buffer-diagnostics read-only-observation ok ok unavailable)")))

(ert-deftest consent-diagnostics-test-emacs-diagnostics-imports-bindings ()
  "The `(emacs diagnostics)' adapter exposes read-only observation bindings."
  (dolist (binding '("buffer-diagnostics"
                     "project-diagnostics"
                     "diagnostic-at"))
    (let ((spec (consent-diagnostics-test--manifest-spec
                 "(emacs diagnostics)" binding)))
      (should spec)
      (should (eq (plist-get spec :source) 'host-capability))
      (should (eq (plist-get spec :effect) 'host-observation))
      (should (eq (plist-get spec :required-capability) 'emacs-diagnostics))
      (should (eq (plist-get spec :backend-effect-path)
                  'shared-capability-request))
      (should (eq (plist-get spec :policy-category) 'emacs-read-only))
      (should (eq (plist-get spec :policy) 'allow))))
  (should
   (equal
    (consent-diagnostics-test--external
     "(import (scheme base) (emacs diagnostics))
      (list (procedure? buffer-diagnostics)
            (procedure? project-diagnostics)
            (procedure? diagnostic-at))")
    "(#t #t #t)")))

(ert-deftest consent-diagnostics-test-buffer-diagnostics-normalizes-backend-data ()
  "Buffer diagnostics normalize mocked backend observations into datums."
  (let ((consent-diagnostics-buffer-function
         (lambda (buffer _context)
           (list
            (list :severity 'error
                  :message "Unbound identifier"
                  :source "mock-lsp"
                  :beg 3
                  :end 9
                  :file "/tmp/project/src/main.scm"
                  :buffer (buffer-name buffer)
                  :metadata '((code "E1")))))))
    (with-temp-buffer
      (rename-buffer "consent-diagnostics-buffer" t)
      (insert "(x y)\n")
      (let ((external
             (consent-diagnostics-test--external
              "(import (emacs buffer) (emacs diagnostics))
               (buffer-diagnostics (emacs-current-buffer))")))
        (should
         (consent-diagnostics-test--contains-p
          external
          "(diagnostics-snapshot (status ok) (scope buffer)"))
        (should
         (consent-diagnostics-test--contains-p
          external
          "(buffer \"consent-diagnostics-buffer\")"))
        (should
         (consent-diagnostics-test--contains-p
          external
          "(diagnostic (severity error) (message \"Unbound identifier\")"))
        (should
         (consent-diagnostics-test--contains-p
          external
          "(source \"mock-lsp\")"))
        (should
         (consent-diagnostics-test--contains-p
          external
          "(range (diagnostic-range (start 3) (end 9)"))
        (should
         (consent-diagnostics-test--contains-p
          external
          "(metadata ((code \"E1\")))"))))))

(ert-deftest consent-diagnostics-test-diagnostic-at-selects-position ()
  "Return the diagnostic containing a buffer position, or #f."
  (let ((consent-diagnostics-buffer-function
         (lambda (buffer _context)
           (list
            (list :severity 'warning
                  :message "First warning"
                  :source "mock-lsp"
                  :beg 1
                  :end 4
                  :file nil
                  :buffer (buffer-name buffer)
                  :metadata '())
            (list :severity 'note
                  :message "Selected note"
                  :source "mock-lsp"
                  :beg 5
                  :end 9
                  :file nil
                  :buffer (buffer-name buffer)
                  :metadata '())))))
    (with-temp-buffer
      (rename-buffer "consent-diagnostics-at" t)
      (insert "abcdefghi")
      (should
       (equal
        (consent-diagnostics-test--external
         "(import (scheme base)
                  (agent diagnostics)
                  (emacs buffer)
                  (emacs diagnostics))
          (let ((diagnostic (diagnostic-at (emacs-current-buffer) 6)))
            (list
             (diagnostic-severity diagnostic)
             (diagnostic-message diagnostic)
             (diagnostic-at (emacs-current-buffer) 10)))")
        "(note \"Selected note\" #f)")))))

(ert-deftest consent-diagnostics-test-project-diagnostics-unavailable ()
  "Return a clear unavailable snapshot when project diagnostics cannot run."
  (let ((consent-diagnostics-project-function nil))
    (cl-letf (((symbol-function 'project-current)
               (lambda (&optional _maybe-prompt _directory) nil)))
      (let ((external
             (consent-diagnostics-test--external
              "(import (emacs diagnostics))
               (project-diagnostics '())")))
        (should
         (consent-diagnostics-test--contains-p
          external
          "(diagnostics-snapshot (status unavailable) (scope project)"))
        (should
         (consent-diagnostics-test--contains-p
          external
          "(reason \"project diagnostics require a current project\")"))))))

(ert-deftest consent-diagnostics-test-diagnostics-yield-audits-events ()
  "Yield adapter diagnostic snapshots through the event channel."
  (consent-audit-clear)
  (let ((consent-diagnostics-buffer-function
         (lambda (buffer _context)
           (list
            (list :severity 'error
                  :message "Yielded diagnostic"
                  :source "mock-lsp"
                  :beg 1
                  :end 2
                  :file nil
                  :buffer (buffer-name buffer)
                  :metadata '())))))
    (with-temp-buffer
      (rename-buffer "consent-diagnostics-yield" t)
      (insert "x\n")
      (let ((result
             (consent-result->external
              (consent-eval-source-result
               "(import (scheme base)
                        (agent diagnostics)
                        (emacs buffer)
                        (emacs diagnostics))
                (diagnostics-yield
                 (buffer-diagnostics (emacs-current-buffer)))
                'ok"))))
        (should (consent-diagnostics-test--contains-p result "(status ok)"))
        (should
         (consent-diagnostics-test--contains-p
          result
          "(events ((yield (diagnostics-snapshot"))
        (should
         (consent-diagnostics-test--contains-p
          result
          "(message \"Yielded diagnostic\")")))))
  (should
   (consent-diagnostics-test--audit-entry-matching
    "(event agent-event)"
    "(category agent-io)"
    "(operation \"agent-yield\")"
    "(decision recorded)")))

;;; consent-diagnostics-test.el ends here
