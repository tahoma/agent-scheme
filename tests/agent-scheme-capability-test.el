;;; agent-scheme-capability-test.el --- Emacs capability library tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for opaque Emacs handles and read-only capability
;; libraries imported by Agent Scheme programs.

;;; Code:

(require 'ert)
(require 'seq)
(require 'agent-scheme-eval)

(defvar agent-scheme-capability-test--secret "secret-value"
  "Private test value whose contents must not be exposed through variable-info.")

(defun agent-scheme-capability-test--external
    (source &optional environment options)
  "Evaluate SOURCE and return its stable external value representation."
  (agent-scheme-value->external
   (agent-scheme-eval-source source environment options)))

(defun agent-scheme-capability-test--manifest-spec (library name)
  "Return Emacs capability metadata for binding NAME in LIBRARY."
  (seq-find
   (lambda (spec)
     (and (equal (plist-get spec :library) library)
          (equal (plist-get spec :name) name)))
   (agent-scheme-emacs-capability-binding-specs)))

(ert-deftest agent-scheme-capability-test-buffer-capabilities-use-handles ()
  "Inspect the current buffer through an opaque handle."
  (let ((buffer (generate-new-buffer "agent-scheme-capability-buffer")))
    (unwind-protect
        (with-current-buffer buffer
          (erase-buffer)
          (insert "hello world")
          (goto-char 7)
          (should
           (equal
            (agent-scheme-capability-test--external
             "(import (scheme base) (emacs buffer))
              (let ((handle (emacs-current-buffer)))
                (list (buffer-name handle)
                      (buffer-file-name handle)
                      (buffer-major-mode handle)
                      (buffer-point handle)
                      (buffer-text handle 1 6)))")
            (format "(\"%s\" #f fundamental-mode 7 \"hello\")"
                    (buffer-name buffer))))
          (should
           (string-match-p
            "\\`(handle buffer h-[0-9]+)\\'"
            (agent-scheme-capability-test--external
             "(import (emacs buffer))
              (emacs-current-buffer)"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-scheme-capability-test-buffer-list-returns-usable-handles ()
  "Return buffer-list handles that can be passed back to buffer capabilities."
  (let ((buffer (generate-new-buffer "agent-scheme-capability-listed")))
    (unwind-protect
        (with-current-buffer buffer
          (should
           (equal
            (agent-scheme-capability-test--external
             "(import (scheme base) (emacs buffer))
              (define current-name (buffer-name (emacs-current-buffer)))
              (define (contains-current? handles)
                (cond
                 ((null? handles) #f)
                 ((string=? (buffer-name (car handles)) current-name) #t)
                 (else (contains-current? (cdr handles)))))
              (contains-current? (emacs-buffer-list))")
            "#t")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-scheme-capability-test-stale-buffer-handles-fail-clearly ()
  "Reject buffer handles after the live Emacs buffer disappears."
  (let ((environment (agent-scheme-make-base-environment))
        (buffer (generate-new-buffer "agent-scheme-capability-stale"))
        handle)
    (with-current-buffer buffer
      (setq handle
            (agent-scheme-eval-source
             "(import (emacs buffer))
              (emacs-current-buffer)"
             environment)))
    (kill-buffer buffer)
    (agent-scheme--environment-define environment "stale" handle)
    (let ((condition
           (should-error
            (agent-scheme-eval-source "(buffer-name stale)" environment)
            :type 'agent-scheme-eval-error)))
      (should
       (string-match-p "stale buffer handle" (cadr condition))))))

(ert-deftest agent-scheme-capability-test-window-and-project-queries ()
  "Expose current window handles and project root through capability libraries."
  (let ((default-directory agent-scheme--test-root))
    (should
     (equal
      (agent-scheme-capability-test--external
       "(import (scheme base) (emacs window))
        (pair? (emacs-window-list))")
      "#t"))
    (should
     (equal
      (agent-scheme-capability-test--external
       "(import (emacs project))
        (project-root)")
      (format "\"%s\""
              (file-name-as-directory
               (expand-file-name agent-scheme--test-root)))))))

(ert-deftest agent-scheme-capability-test-frame-handles ()
  "Inspect frames through opaque handles."
  (should
   (string-match-p
    "\\`(handle frame h-[0-9]+)\\'"
    (agent-scheme-capability-test--external
     "(import (emacs frame))
      (emacs-current-frame)")))
  (should
   (equal
    (agent-scheme-capability-test--external
     "(import (scheme base) (emacs frame) (emacs window))
      (list (string? (frame-name (emacs-current-frame)))
            (pair? (emacs-frame-list))
            (string? (frame-name
                      (window-frame (car (emacs-window-list))))))")
    "(#t #t #t)")))

(ert-deftest agent-scheme-capability-test-project-handles ()
  "Inspect the current project through an opaque project handle."
  (let ((default-directory agent-scheme--test-root)
        (expected-root
         (file-name-as-directory (expand-file-name agent-scheme--test-root))))
    (should
     (string-match-p
      "\\`(handle project h-[0-9]+)\\'"
      (agent-scheme-capability-test--external
       "(import (emacs project))
        (emacs-current-project)")))
    (should
     (equal
      (agent-scheme-capability-test--external
       "(import (scheme base) (emacs project))
        (let ((project (emacs-current-project)))
          (list (not (eq? project #f))
                (project-root project)
                (project-root)))")
      (format "(#t \"%s\" \"%s\")" expected-root expected-root)))))

(ert-deftest agent-scheme-capability-test-process-handles ()
  "Inspect live processes through opaque handles and reject stale handles."
  (let ((environment (agent-scheme-make-base-environment))
        (buffer (generate-new-buffer "agent-scheme-capability-process-buffer"))
        process handle)
    (unwind-protect
        (progn
          (setq process
                (start-process
                 "agent-scheme-capability-process" buffer "cat"))
          (set-process-query-on-exit-flag process nil)
          (accept-process-output process 0.1)
          (should
           (equal
            (agent-scheme-capability-test--external
             "(import (scheme base) (emacs buffer) (emacs process))
              (define (find-process handles)
                (cond
                 ((null? handles) #f)
                 ((string=? (process-name (car handles))
                            \"agent-scheme-capability-process\")
                  (car handles))
                 (else (find-process (cdr handles)))))
              (let ((handle (find-process (emacs-process-list))))
                (list (process-name handle)
                      (process-status handle)
                      (buffer-name (process-buffer handle))))")
            (format "(\"agent-scheme-capability-process\" run \"%s\")"
                    (buffer-name buffer))))
          (setq handle
                (agent-scheme-eval-source
                 "(import (scheme base) (emacs process))
                  (define (find-process handles)
                    (cond
                     ((null? handles) #f)
                     ((string=? (process-name (car handles))
                                \"agent-scheme-capability-process\")
                      (car handles))
                     (else (find-process (cdr handles)))))
                  (find-process (emacs-process-list))"
                 environment))
          (delete-process process)
          (setq process nil)
          (agent-scheme--environment-define environment "stale-process" handle)
          (let ((condition
                 (should-error
                  (agent-scheme-eval-source
                   "(process-name stale-process)" environment)
                  :type 'agent-scheme-eval-error)))
            (should
             (string-match-p "stale process handle" (cadr condition)))))
      (when (process-live-p process)
        (delete-process process))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-scheme-capability-test-documentation-capabilities ()
  "Expose documentation metadata without exposing variable values."
  (should
   (equal
    (agent-scheme-capability-test--external
     "(import (scheme base) (emacs command))
      (list (string? (command-doc 'find-file))
            (string? (function-doc 'car)))")
    "(#t #t)"))
  (let ((external
         (agent-scheme-capability-test--external
          "(import (emacs command))
           (variable-info 'agent-scheme-capability-test--secret)")))
    (should
     (string-match-p "agent-scheme-capability-test--secret" external))
    (should
     (string-match-p "documentation" external))
    (should-not
     (string-match-p "secret-value" external))))

(ert-deftest agent-scheme-capability-test-manifest-describes-emacs-bindings ()
  "Expose metadata for read-only Emacs capability bindings."
  (let ((current-buffer (agent-scheme-capability-test--manifest-spec
                         "(emacs buffer)" "emacs-current-buffer"))
        (buffer-text (agent-scheme-capability-test--manifest-spec
                      "(emacs buffer)" "buffer-text"))
        (current-frame (agent-scheme-capability-test--manifest-spec
                        "(emacs frame)" "emacs-current-frame"))
        (current-project (agent-scheme-capability-test--manifest-spec
                          "(emacs project)" "emacs-current-project"))
        (process-status (agent-scheme-capability-test--manifest-spec
                         "(emacs process)" "process-status"))
        (command-doc (agent-scheme-capability-test--manifest-spec
                      "(emacs command)" "command-doc")))
    (should current-buffer)
    (should (eq (plist-get current-buffer :source) 'host-capability))
    (should (eq (plist-get current-buffer :effect) 'host-observation))
    (should (eq (plist-get current-buffer :required-capability)
                'emacs-buffer))
    (should (eq (plist-get current-buffer :policy) 'allow))
    (should (equal (plist-get buffer-text :minimum-arity) 3))
    (should (eq (plist-get buffer-text :required-capability) 'emacs-buffer))
    (should (eq (plist-get current-frame :required-capability) 'emacs-frame))
    (should (eq (plist-get current-project :required-capability)
                'emacs-project))
    (should (eq (plist-get process-status :required-capability)
                'emacs-process))
    (should (eq (plist-get command-doc :required-capability)
                'emacs-documentation))))

;;; agent-scheme-capability-test.el ends here
