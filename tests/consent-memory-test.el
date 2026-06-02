;;; consent-memory-test.el --- Scoped memory library tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for inspectable `(agent memory)' records, scoped stores,
;; yield integration, editable buffers, and private-local persistence defaults.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-audit)
(require 'consent-eval)
(require 'consent-memory)
(require 'consent-result)
(require 'consent-session)

(defun consent-memory-test--external (datum)
  "Return DATUM as stable Scheme-readable text."
  (consent-result->external datum))

(defun consent-memory-test--value-external (value)
  "Return VALUE as stable Consent Scheme value text."
  (consent-value->external value))

(defun consent-memory-test--reset ()
  "Reset memory, session, and audit state for a focused test."
  (consent-memory-clear!)
  (consent-session-clear!)
  (consent-audit-clear))

(defun consent-memory-test--buffer-string (buffer)
  "Return BUFFER contents without text properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest consent-memory-test-crud-search-tags-and-scope-isolation ()
  "Read and write canonical records while keeping scopes isolated."
  (consent-memory-test--reset)
  (let ((value
         (consent-memory-test--value-external
          (consent-eval-source
           "(import (scheme base) (agent memory))
            (memory-put! 'instance
                         'alpha
                         '((tags (shared fact))
                           (value \"instance alpha\")
                           (source (test instance))
                           (confidence high)))
            (memory-put! 'project
                         'alpha
                         '((tags (project fact))
                           (value \"project alpha\")
                           (source (test project))
                           (confidence high)))
            (list (memory-ref 'instance 'alpha)
                  (memory-ref 'project 'alpha)
                  (memory-by-tag 'instance 'shared)
                  (memory-find 'project \"project alpha\")
                  (memory-delete! 'instance 'alpha)
                  (memory-ref 'instance 'alpha))"))))
    (should (string-match-p "(scope instance)" value))
    (should (string-match-p "(value \"instance alpha\")" value))
    (should (string-match-p "(scope project)" value))
    (should (string-match-p "(value \"project alpha\")" value))
    (should (string-match-p "(tags (shared fact))" value))
    (should (string-match-p "(tags (project fact))" value))
    (should (string-suffix-p "#f)" value))))

(ert-deftest consent-memory-test-session-scope-uses-current-session ()
  "Session memory is tied to the active durable session."
  (consent-memory-test--reset)
  (consent-session-create! 'named '(:id "mem-alpha"))
  (consent-session-create! 'named '(:id "mem-beta"))
  (should
   (string-match-p
    "(scope session)"
    (consent-memory-test--value-external
     (consent-session-eval-source
      "mem-alpha"
      "(import (scheme base) (agent memory))
       (memory-put! 'session
                    'answer
                    '((tags (session alpha))
                      (value 42)
                      (confidence high)))"))))
  (should
   (equal
    (consent-memory-test--value-external
     (consent-session-eval-source
      "mem-alpha"
      "(import (scheme base) (agent memory))
       (memory-ref 'session 'answer)"))
    "(memory (id answer) (scope session) (key answer) (kind datum) (tags (session alpha)) (value 42) (source ()) (confidence high) (created-at 1) (updated-at 1))"))
  (should
   (equal
    (consent-memory-test--value-external
     (consent-session-eval-source
      "mem-beta"
      "(import (scheme base) (agent memory))
       (memory-ref 'session 'answer)"))
    "#f"))
  (should-error
   (consent-eval-source
    "(import (scheme base) (agent memory))
     (memory-ref 'session 'answer)")
   :type 'consent-memory-error))

(ert-deftest consent-memory-test-add-recent-and-yield-integration ()
  "Add generated records, query recency, and yield matches as events."
  (consent-memory-test--reset)
  (let ((result
         (consent-memory-test--external
          (consent-eval-source-result
           "(import (scheme base) (agent memory))
            (memory-add! 'project
                         'fact
                         '((tags (architecture r7rs))
                           (value \"Emacs is an adapter\")
                           (source (issue 22))
                           (confidence high)))
            (memory-add! 'project
                         'note
                         '((tags (scratch))
                           (value \"temporary note\")))
            (list (memory-recent 'project 1)
                  (memory-yield 'project \"adapter\"))"))))
    (should (string-match-p "(status ok)" result))
    (should (string-match-p "(kind fact)" result))
    (should (string-match-p "(kind note)" result))
    (should
     (string-match-p
      (regexp-quote "(events ((yield (memory")
      result))
    (should
     (string-match-p
      (regexp-quote "(value \"Emacs is an adapter\")")
      result))))

(ert-deftest consent-memory-test-buffers-and-private-local-persistence ()
  "Expose editable memory buffers and persist private-local memory datums."
  (consent-memory-test--reset)
  (let ((consent-memory-directory
         (file-name-as-directory
          (make-temp-file "consent-memory-test" t))))
    (unwind-protect
        (progn
          (consent-memory-put!
           'instance 'persisted
           (consent-read
            "((tags (local)) (value \"private memory\"))"))
          (let ((buffer (consent-memory-open 'instance)))
            (should (equal (buffer-name buffer) "*Agent Memory: instance*"))
            (should (eq (buffer-local-value 'major-mode buffer)
                        'consent-memory-mode))
            (should-not (buffer-local-value 'buffer-read-only buffer))
            (should
             (string-match-p
              "(agent-memory (scope instance)"
              (consent-memory-test--buffer-string buffer)))
            (should
             (string-match-p
              "(value \"private memory\")"
              (consent-memory-test--buffer-string buffer))))
          (consent-session-create! 'named '(:id "memory-buffer"))
          (should
           (equal
            (buffer-name (consent-memory-open 'session "memory-buffer"))
            "*Agent Memory: session: memory-buffer*"))
          (should
           (equal
            (buffer-name (consent-memory-open 'project "consent"))
            "*Agent Memory: project: consent*"))
          (let ((rules
                 (consent-memory-test--external
                  (consent-memory-storage-rules 'project
                                                     default-directory))))
            (should (string-match-p "(mode private-local)" rules))
            (should (string-match-p "(tracked-enabled #f)" rules))
            (should (string-match-p "(public-repository-safe #t)" rules))
            (should (string-match-p "/projects/" rules)))
          (consent-memory-save! 'instance)
          (consent-memory-clear! 'instance)
          (should-not (consent-memory-ref 'instance 'persisted))
          (consent-memory-load! 'instance)
          (should
           (string-match-p
            "(value \"private memory\")"
            (consent-memory-test--external
             (consent-memory-ref 'instance 'persisted)))))
      (delete-directory consent-memory-directory t))))

;;; consent-memory-test.el ends here
