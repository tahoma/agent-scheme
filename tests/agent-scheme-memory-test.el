;;; agent-scheme-memory-test.el --- Scoped memory library tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for inspectable `(agent memory)' records, scoped stores,
;; yield integration, editable buffers, and private-local persistence defaults.

;;; Code:

(require 'ert)
(require 'seq)
(require 'agent-scheme-audit)
(require 'agent-scheme-eval)
(require 'agent-scheme-memory)
(require 'agent-scheme-result)
(require 'agent-scheme-session)

(defun agent-scheme-memory-test--external (datum)
  "Return DATUM as stable Scheme-readable text."
  (agent-scheme-result->external datum))

(defun agent-scheme-memory-test--value-external (value)
  "Return VALUE as stable Agent Scheme value text."
  (agent-scheme-value->external value))

(defun agent-scheme-memory-test--reset ()
  "Reset memory, session, and audit state for a focused test."
  (agent-scheme-memory-clear!)
  (agent-scheme-session-clear!)
  (agent-scheme-audit-clear))

(defun agent-scheme-memory-test--buffer-string (buffer)
  "Return BUFFER contents without text properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest agent-scheme-memory-test-crud-search-tags-and-scope-isolation ()
  "Read and write canonical records while keeping scopes isolated."
  (agent-scheme-memory-test--reset)
  (let ((value
         (agent-scheme-memory-test--value-external
          (agent-scheme-eval-source
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

(ert-deftest agent-scheme-memory-test-session-scope-uses-current-session ()
  "Session memory is tied to the active durable session."
  (agent-scheme-memory-test--reset)
  (agent-scheme-session-create! 'named '(:id "mem-alpha"))
  (agent-scheme-session-create! 'named '(:id "mem-beta"))
  (should
   (string-match-p
    "(scope session)"
    (agent-scheme-memory-test--value-external
     (agent-scheme-session-eval-source
      "mem-alpha"
      "(import (scheme base) (agent memory))
       (memory-put! 'session
                    'answer
                    '((tags (session alpha))
                      (value 42)
                      (confidence high)))"))))
  (should
   (equal
    (agent-scheme-memory-test--value-external
     (agent-scheme-session-eval-source
      "mem-alpha"
      "(import (scheme base) (agent memory))
       (memory-ref 'session 'answer)"))
    "(memory (id answer) (scope session) (key answer) (kind datum) (tags (session alpha)) (value 42) (source ()) (confidence high) (created-at 1) (updated-at 1))"))
  (should
   (equal
    (agent-scheme-memory-test--value-external
     (agent-scheme-session-eval-source
      "mem-beta"
      "(import (scheme base) (agent memory))
       (memory-ref 'session 'answer)"))
    "#f"))
  (should-error
   (agent-scheme-eval-source
    "(import (scheme base) (agent memory))
     (memory-ref 'session 'answer)")
   :type 'agent-scheme-memory-error))

(ert-deftest agent-scheme-memory-test-add-recent-and-yield-integration ()
  "Add generated records, query recency, and yield matches as events."
  (agent-scheme-memory-test--reset)
  (let ((result
         (agent-scheme-memory-test--external
          (agent-scheme-eval-source-result
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

(ert-deftest agent-scheme-memory-test-buffers-and-private-local-persistence ()
  "Expose editable memory buffers and persist private-local memory datums."
  (agent-scheme-memory-test--reset)
  (let ((agent-scheme-memory-directory
         (file-name-as-directory
          (make-temp-file "agent-scheme-memory-test" t))))
    (unwind-protect
        (progn
          (agent-scheme-memory-put!
           'instance 'persisted
           (agent-scheme-read
            "((tags (local)) (value \"private memory\"))"))
          (let ((buffer (agent-scheme-memory-open 'instance)))
            (should (equal (buffer-name buffer) "*Agent Memory: instance*"))
            (should (eq (buffer-local-value 'major-mode buffer)
                        'agent-scheme-memory-mode))
            (should-not (buffer-local-value 'buffer-read-only buffer))
            (should
             (string-match-p
              "(agent-memory (scope instance)"
              (agent-scheme-memory-test--buffer-string buffer)))
            (should
             (string-match-p
              "(value \"private memory\")"
              (agent-scheme-memory-test--buffer-string buffer))))
          (agent-scheme-session-create! 'named '(:id "memory-buffer"))
          (should
           (equal
            (buffer-name (agent-scheme-memory-open 'session "memory-buffer"))
            "*Agent Memory: session: memory-buffer*"))
          (should
           (equal
            (buffer-name (agent-scheme-memory-open 'project "agent-scheme"))
            "*Agent Memory: project: agent-scheme*"))
          (let ((rules
                 (agent-scheme-memory-test--external
                  (agent-scheme-memory-storage-rules 'project
                                                     default-directory))))
            (should (string-match-p "(mode private-local)" rules))
            (should (string-match-p "(tracked-enabled #f)" rules))
            (should (string-match-p "(public-repository-safe #t)" rules))
            (should (string-match-p "/projects/" rules)))
          (agent-scheme-memory-save! 'instance)
          (agent-scheme-memory-clear! 'instance)
          (should-not (agent-scheme-memory-ref 'instance 'persisted))
          (agent-scheme-memory-load! 'instance)
          (should
           (string-match-p
            "(value \"private memory\")"
            (agent-scheme-memory-test--external
             (agent-scheme-memory-ref 'instance 'persisted)))))
      (delete-directory agent-scheme-memory-directory t))))

;;; agent-scheme-memory-test.el ends here
